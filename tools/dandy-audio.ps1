<#
  DandyRecords — pipeline audio pour le kiosk

  Parcourt ta bibliothèque musicale (rangée  Artiste\Année - Album\morceaux), et pour chaque album
  qui correspond à un disque de ton stock (Google Sheets) :
    1. convertit les morceaux (flac, wav, aiff, m4a, mp3…) en MP3 256 kbps
    2. les renomme {discogs_id}_1.mp3, {discogs_id}_2.mp3… dans l'ordre des noms de fichiers
    3. envoie les nouveaux fichiers sur Cloudflare R2 (rclone)
  Les albums qui ne sont pas dans le stock sont simplement ignorés.

  Les réglages (dossier de musique, bucket) sont dans dandy-config.json, créé par Installer.bat.
  Relançable autant de fois que voulu : ce qui est déjà converti et déjà en ligne est sauté.
  Les fichiers d'origine ne sont jamais modifiés ni supprimés.

  Options :
    -SansUpload   convertit seulement, n'envoie rien sur R2
    -Simulation   affiche ce qui serait fait, sans rien convertir ni envoyer
    -Forcer       reconvertit tout, même ce qui est déjà à jour
#>
param(
  [switch]$SansUpload,
  [switch]$Simulation,
  [switch]$Forcer,
  [string]$CsvLocal = ''   # chemin d'un CSV local à utiliser à la place du Google Sheets (hors ligne)
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ── CONFIG ─────────────────────────────────────────────────────────────
$Bitrate = '256k'
$SheetId = '1adNI1aCJb2-Ym2kYYHg0tol56sGIa78-gImVY7dkKqU'
$Extensions = @('.flac','.wav','.aif','.aiff','.m4a','.alac','.mp3','.ogg','.opus','.wma','.ape','.wv')
$ConfigPath = Join-Path $PSScriptRoot 'dandy-config.json'
# ───────────────────────────────────────────────────────────────────────

function Titre($t) { Write-Host ''; Write-Host "── $t " -ForegroundColor Magenta }
function Ok($t)    { Write-Host "  ✓ $t" -ForegroundColor Green }
function Info($t)  { Write-Host "  · $t" -ForegroundColor Gray }
function Alerte($t){ Write-Host "  ! $t" -ForegroundColor Yellow }
function Erreur($t){ Write-Host "  ✗ $t" -ForegroundColor Red }

if (-not (Test-Path -LiteralPath $ConfigPath)) { Erreur "Réglages introuvables : lance d'abord Installer.bat"; exit 1 }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Source = $cfg.source; $Sortie = $cfg.sortie; $R2 = "r2:$($cfg.bucket)"
if ($env:DANDY_SOURCE) { $Source = $env:DANDY_SOURCE }
if ($env:DANDY_SORTIE) { $Sortie = $env:DANDY_SORTIE }

# minuscules, sans accents ni ponctuation : "Ëmi – Timely!" → "emi timely"
function Normaliser([string]$s) {
  if (-not $s) { return '' }
  $d = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $d.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
  }
  $r = $sb.ToString().ToLowerInvariant() -replace '[^\p{L}\p{N}]+', ' '
  return $r.Trim()
}

# tri "naturel" : "2 - x" avant "10 - x"
function CleNaturelle([string]$s) { return [regex]::Replace($s.ToLowerInvariant(), '\d+', { param($m) $m.Value.PadLeft(10,'0') }) }

# même règle que le kiosk pour compter les morceaux d'une tracklist
function CompterPistes([string]$tl) {
  $n = 0
  foreach ($t in ($tl -split ';')) {
    $parts = $t.Trim() -split ' - '
    if ($parts.Count -ge 2) {
      $pos = $parts[0].Trim(); $tit = $parts[1].Trim()
      if ($tit -and $tit -ne 'null' -and $pos -and -not $pos.StartsWith('-')) { $n++ }
    }
  }
  return $n
}

# ── 0. Outils ──────────────────────────────────────────────────────────
Titre 'Vérifications'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  Erreur "ffmpeg introuvable. Relance Installer.bat."; exit 1
}
Ok 'ffmpeg'
$uploader = -not $SansUpload -and -not $Simulation
if ($uploader) {
  if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) { Erreur "rclone introuvable. Relance Installer.bat (ou utilise -SansUpload)."; exit 1 }
  if (-not ((& rclone listremotes) -contains 'r2:')) { Erreur "Connexion R2 non configurée. Relance Installer.bat."; exit 1 }
  Ok "rclone ($R2)"
}
if (-not $Source -or -not (Test-Path -LiteralPath $Source)) { Erreur "Dossier de musique introuvable : $Source  (relance Installer.bat)"; exit 1 }
$Source = [IO.Path]::GetFullPath($Source).TrimEnd('\','/')
Ok "Musique : $Source"
New-Item -ItemType Directory -Force -Path $Sortie | Out-Null
Ok "Sortie  : $Sortie"

# ── 1. Catalogue ───────────────────────────────────────────────────────
Titre 'Stock (Google Sheets)'
$catalogue = @()
try {
  if ($CsvLocal) {
    $csvText = [IO.File]::ReadAllText($CsvLocal, [Text.Encoding]::UTF8)
  } else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
    $csvText = $wc.DownloadString("https://docs.google.com/spreadsheets/d/$SheetId/export?format=csv")
  }
  $parIdTmp = @{}
  foreach ($row in ($csvText | ConvertFrom-Csv)) {
    $id = "$($row.release_discogs_id)".Trim()
    if (-not $id) { continue }
    $qty = 0; [void][int]::TryParse("$($row.listing_stock_quantity)".Trim(), [ref]$qty)
    $enStock = ($qty -gt 0) -or ($row.listing_pre_order -eq 'TRUE')
    if ($parIdTmp.ContainsKey($id)) { if ($enStock) { $parIdTmp[$id].EnStock = $true }; continue }
    $parIdTmp[$id] = [pscustomobject]@{
      Id = $id; Artiste = $row.release_artists_formatted; Titre = $row.item_title; Annee = "$($row.release_year)".Trim()
      NArt = Normaliser $row.release_artists_formatted; NTit = Normaliser $row.item_title
      Pistes = CompterPistes $row.release_tracklist; EnStock = $enStock
    }
  }
  $catalogue = @($parIdTmp.Values)
  Ok "$($catalogue.Count) références chargées"
} catch {
  Erreur "Impossible de lire le Google Sheets ($($_.Exception.Message))."
  Erreur "Vérifie ta connexion internet. Sans le stock, le script ne peut pas reconnaître les albums."
  exit 1
}
$parId = @{}; foreach ($c in $catalogue) { $parId[$c.Id] = $c }

# Trouve le disque du stock qui correspond à un dossier d'album.
# $chemin = chemin relatif, ex. "Mariya Takeuchi\1984 - Variety"
function TrouverDisque([string]$chemin) {
  # un Discogs ID au début du dossier d'album (ou d'un dossier parent) est prioritaire
  $segs = $chemin -split '[\\/]'
  for ($k = $segs.Count - 1; $k -ge 0; $k--) { if ($segs[$k] -match '^\s*\[?r?(\d{5,})(\D|$)') { return $Matches[1] } }
  $n = ' ' + (Normaliser $chemin) + ' '
  $meilleurs = @(); $top = 0
  foreach ($c in $catalogue) {
    if (-not $c.NTit -or -not $n.Contains(" $($c.NTit) ")) { continue }
    $score = 0
    if ($c.NArt -and $n.Contains(" $($c.NArt) ")) { $score = 3 }
    elseif (@($c.NArt -split ' ' | Where-Object { $_.Length -ge 3 -and $n.Contains(" $_ ") }).Count) { $score = 2 }
    if ($score -eq 0) { continue }                         # le titre seul ne suffit pas
    if ($c.Annee -and $n.Contains(" $($c.Annee) ")) { $score++ }
    if ($score -gt $top) { $top = $score; $meilleurs = @($c) } elseif ($score -eq $top) { $meilleurs += $c }
  }
  if ($meilleurs.Count -eq 1) { return $meilleurs[0].Id }
  if ($meilleurs.Count -gt 1) { return "AMBIGU:" + (($meilleurs | ForEach-Object { "$($_.Id) ($($_.Artiste) – $($_.Titre) $($_.Annee))" }) -join ', ') }
  return $null
}

# ── 2. Albums ──────────────────────────────────────────────────────────
Titre 'Recherche des albums'
$sortieAbs = [IO.Path]::GetFullPath($Sortie).TrimEnd('\','/')
$tous = Get-ChildItem -LiteralPath $Source -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
  ($Extensions -contains $_.Extension.ToLowerInvariant()) -and -not $_.FullName.StartsWith($sortieAbs) -and
  -not ($_.FullName.Substring($Source.Length) -split '[\\/]' | Where-Object { $_.StartsWith('_') })
}
# un dossier "CD1", "Disc 2"… appartient à l'album du dessus
$albums = @{}
foreach ($f in $tous) {
  $dir = $f.Directory
  if ($dir.Name -match '^(cd|dis[ck]|disque|face|side)\s*[-_ ]?\d+\b' -and $dir.Parent) { $dir = $dir.Parent }
  if (-not $albums.ContainsKey($dir.FullName)) { $albums[$dir.FullName] = New-Object Collections.ArrayList }
  [void]$albums[$dir.FullName].Add($f)
}
Ok "$($albums.Count) dossiers d'album trouvés"

Titre 'Conversion'
$stats = @{ convertis = 0; ajour = 0; disques = 0 }
$aRevoir = @(); $nonReconnus = @(); $traites = @{}

foreach ($albumDir in ($albums.Keys | Sort-Object)) {
  $rel = $albumDir.Substring($Source.Length).TrimStart('\','/')
  if (-not $rel) { $rel = Split-Path $albumDir -Leaf }
  $id = TrouverDisque $rel
  if (-not $id) { $nonReconnus += $rel; continue }
  if ($id.StartsWith('AMBIGU:')) { Alerte "$rel → plusieurs disques possibles : $($id.Substring(7)). Ajoute le bon Discogs ID devant le nom du dossier."; $aRevoir += "$rel : ambigu"; continue }
  if ($traites.ContainsKey($id)) { Alerte "$rel → même disque que « $($traites[$id]) », ignoré. Ajoute le Discogs ID devant le bon dossier pour choisir."; $aRevoir += "$rel : doublon de $($traites[$id])"; continue }
  $traites[$id] = $rel

  $fichiers = @($albums[$albumDir] | Sort-Object @{ Expression = { CleNaturelle ($_.FullName.Substring($albumDir.Length)) } })
  $info = $parId[$id]
  $label = if ($info) { "$($info.Artiste) – $($info.Titre)" } else { $rel }
  Write-Host ''
  Write-Host "  $id  $label  ($($fichiers.Count) morceaux)   ← $rel" -ForegroundColor White
  if (-not $info) { Alerte "ID $id absent du Google Sheets (vérifie la colonne release_discogs_id)"; $aRevoir += "$rel : ID $id absent du Sheets" }
  elseif ($info.Pistes -and $info.Pistes -ne $fichiers.Count) {
    Alerte "Le Sheets indique $($info.Pistes) morceaux, le dossier en contient $($fichiers.Count) : les numéros risquent d'être décalés"
    $aRevoir += "$rel : $($fichiers.Count) fichiers pour $($info.Pistes) morceaux"
  }
  $stats.disques++

  for ($i = 0; $i -lt $fichiers.Count; $i++) {
    $src = $fichiers[$i]
    $dst = Join-Path $Sortie ("{0}_{1}.mp3" -f $id, ($i + 1))
    if (-not $Forcer -and (Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst).LastWriteTime -ge $src.LastWriteTime) { $stats.ajour++; continue }
    Info ("{0,-16} ← {1}" -f (Split-Path $dst -Leaf), $src.Name)
    if ($Simulation) { continue }
    $tmp = "$dst.part.mp3"
    & ffmpeg -hide_banner -loglevel error -nostdin -y -i $src.FullName -map 0:a:0 -vn -c:a libmp3lame -b:a $Bitrate -ar 44100 -map_metadata 0 -id3v2_version 3 $tmp
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
      Erreur "échec de conversion : $($src.FullName)"; $aRevoir += "$($src.FullName) : conversion échouée"
      Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; continue
    }
    Move-Item -LiteralPath $tmp -Destination $dst -Force
    $stats.convertis++
  }
  # un morceau retiré du dossier → on supprime l'ancien MP3 en trop
  if (-not $Simulation) {
    Get-ChildItem -LiteralPath $Sortie -Filter "${id}_*.mp3" | Where-Object {
      $_.Name -match "^${id}_(\d+)\.mp3$" -and [int]$Matches[1] -gt $fichiers.Count
    } | ForEach-Object { Alerte "suppression de $($_.Name) (plus de fichier source)"; Remove-Item -LiteralPath $_.FullName }
  }
}

# ── 3. Envoi sur R2 ────────────────────────────────────────────────────
if ($uploader) {
  Titre 'Envoi sur Cloudflare R2'
  & rclone copy $Sortie $R2 --include '*.mp3' --transfers 6 --s3-no-check-bucket --stats-one-line --progress
  if ($LASTEXITCODE -eq 0) { Ok 'Envoi terminé' } else { Erreur "rclone a renvoyé une erreur (code $LASTEXITCODE)"; $aRevoir += 'Envoi R2 incomplet : relance le script' }
}

# ── 4. Bilan ───────────────────────────────────────────────────────────
Titre 'Bilan'
$mode = if ($Simulation) { ' (simulation : rien n''a été écrit)' } else { '' }
Ok "$($stats.disques) disques du stock trouvés, $($stats.convertis) morceaux convertis, $($stats.ajour) déjà à jour$mode"

$avecAudio = @{}
Get-ChildItem -LiteralPath $Sortie -Filter '*_1.mp3' | ForEach-Object { $avecAudio[($_.Name -replace '_1\.mp3$', '')] = $true }
$sansAudio = @($catalogue | Where-Object { $_.EnStock -and -not $avecAudio.ContainsKey($_.Id) -and -not $traites.ContainsKey($_.Id) } | Sort-Object Artiste, Titre)
$fSans = Join-Path $Sortie '_stock-sans-audio.txt'
$fNon  = Join-Path $Sortie '_dossiers-non-reconnus.txt'
$fAvec = Join-Path $Sortie '_disques-avec-audio.txt'
$sansAudio | ForEach-Object { "$($_.Id)`t$($_.Artiste) – $($_.Titre) ($($_.Annee))" } | Set-Content -LiteralPath $fSans -Encoding UTF8
$nonReconnus | Set-Content -LiteralPath $fNon -Encoding UTF8
($avecAudio.Keys | Sort-Object) | Set-Content -LiteralPath $fAvec -Encoding UTF8

Info "$($avecAudio.Count) disques ont de l'audio"
if ($sansAudio.Count) { Alerte "$($sansAudio.Count) disques en stock n'ont pas encore d'audio → liste dans _stock-sans-audio.txt" }
if ($nonReconnus.Count) { Info "$($nonReconnus.Count) albums de ta bibliothèque ne sont pas dans le stock (ignorés) → _dossiers-non-reconnus.txt" }
if ($aRevoir.Count) {
  Write-Host ''; Write-Host '  À revoir :' -ForegroundColor Yellow
  $aRevoir | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
}
Info "Les listes sont dans $Sortie"
Write-Host ''
