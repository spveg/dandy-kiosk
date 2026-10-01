<#
  DandyRecords — pipeline audio pour le kiosk

  Pour chaque dossier de disque dans $Source :
    1. retrouve le Discogs ID (début du nom de dossier, ou sinon artiste + titre via le Google Sheets)
    2. convertit tous les fichiers audio (flac, wav, aiff, m4a, mp3…) en MP3 256 kbps
    3. les renomme {discogs_id}_1.mp3, {discogs_id}_2.mp3… dans l'ordre des noms de fichiers
    4. envoie les nouveaux fichiers sur Cloudflare R2 (rclone)

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

# ── CONFIG ─────────────────────────────────────────────────────────────
$Source  = 'C:\Users\anton\kDrive\DANDY RECORDS\Audio Sippets'   # un sous-dossier par disque
$Sortie  = "$env:USERPROFILE\Music\dandy-mp3"              # MP3 prêts à envoyer (hors kDrive)
$Bitrate = '256k'
$SheetId = '1adNI1aCJb2-Ym2kYYHg0tol56sGIa78-gImVY7dkKqU'
$R2      = 'r2:dandy-audio'                                       # remote rclone : nom-du-remote:nom-du-bucket
$Extensions = @('.flac','.wav','.aif','.aiff','.m4a','.alac','.mp3','.ogg','.opus','.wma','.ape','.wv')
# ───────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
if ($env:DANDY_SOURCE) { $Source = $env:DANDY_SOURCE }
if ($env:DANDY_SORTIE) { $Sortie = $env:DANDY_SORTIE }

function Titre($t) { Write-Host ''; Write-Host "── $t " -ForegroundColor Magenta }
function Ok($t)    { Write-Host "  ✓ $t" -ForegroundColor Green }
function Info($t)  { Write-Host "  · $t" -ForegroundColor Gray }
function Alerte($t){ Write-Host "  ! $t" -ForegroundColor Yellow }
function Erreur($t){ Write-Host "  ✗ $t" -ForegroundColor Red }

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
  Erreur "ffmpeg introuvable. Installe-le avec :  winget install Gyan.FFmpeg   puis rouvre la fenêtre."; exit 1
}
Ok 'ffmpeg'
$uploader = -not $SansUpload -and -not $Simulation
if ($uploader) {
  if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Erreur "rclone introuvable. Installe-le avec :  winget install Rclone.Rclone   (ou relance avec -SansUpload)"; exit 1
  }
  $remoteName = ($R2 -split ':')[0] + ':'
  if (-not ((& rclone listremotes) -contains $remoteName)) {
    Erreur "Le remote rclone '$remoteName' n'est pas configuré. Voir tools/README.md, étape « Connexion à R2 »."; exit 1
  }
  Ok "rclone ($R2)"
}
if (-not (Test-Path -LiteralPath $Source)) { Erreur "Dossier source introuvable : $Source"; exit 1 }
Ok "Source : $Source"
New-Item -ItemType Directory -Force -Path $Sortie | Out-Null
Ok "Sortie : $Sortie"

# ── 1. Catalogue (pour retrouver les IDs et compter les morceaux) ──────
Titre 'Catalogue'
$catalogue = @()
try {
  if ($CsvLocal) {
    $csvText = [IO.File]::ReadAllText($CsvLocal, [Text.Encoding]::UTF8)
  } else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
    $csvText = $wc.DownloadString("https://docs.google.com/spreadsheets/d/$SheetId/export?format=csv")
  }
  $vus = @{}
  foreach ($row in ($csvText | ConvertFrom-Csv)) {
    $id = "$($row.release_discogs_id)".Trim()
    if (-not $id -or $vus.ContainsKey($id)) { continue }
    $vus[$id] = $true
    $catalogue += [pscustomobject]@{
      Id = $id; Artiste = $row.release_artists_formatted; Titre = $row.item_title
      NArt = Normaliser $row.release_artists_formatted; NTit = Normaliser $row.item_title
      Pistes = CompterPistes $row.release_tracklist
    }
  }
  Ok "$($catalogue.Count) références chargées"
} catch {
  Alerte "Catalogue non chargé ($($_.Exception.Message)). Seuls les dossiers nommés avec leur Discogs ID seront traités."
}
$parId = @{}; foreach ($c in $catalogue) { $parId[$c.Id] = $c }

function TrouverDisque([string]$nomDossier) {
  if ($nomDossier -match '^\s*\[?r?(\d{5,})') { return $Matches[1] }
  $n = ' ' + (Normaliser $nomDossier) + ' '
  $meilleurs = @(); $top = 0
  foreach ($c in $catalogue) {
    if (-not $c.NTit -or $c.NTit.Length -lt 2 -or -not $n.Contains(" $($c.NTit) ")) { continue }
    $score = 1
    if ($c.NArt -and $n.Contains(" $($c.NArt) ")) { $score = 3 }
    elseif (@($c.NArt -split ' ' | Where-Object { $_.Length -ge 3 -and $n.Contains(" $_ ") }).Count) { $score = 2 }
    if ($score -gt $top) { $top = $score; $meilleurs = @($c) } elseif ($score -eq $top) { $meilleurs += $c }
  }
  if ($meilleurs.Count -eq 1 -and $top -ge 2) { return $meilleurs[0].Id }
  if ($meilleurs.Count -gt 1) { return "AMBIGU:" + (($meilleurs | ForEach-Object { "$($_.Id) ($($_.Artiste) – $($_.Titre))" }) -join ', ') }
  return $null
}

# ── 2. Conversion ──────────────────────────────────────────────────────
Titre 'Conversion'
$stats = @{ convertis = 0; ajour = 0; disques = 0; ignores = 0 }
$aRevoir = @()
$dossiers = Get-ChildItem -LiteralPath $Source -Directory | Where-Object { -not $_.Name.StartsWith('_') } | Sort-Object Name

foreach ($d in $dossiers) {
  $id = TrouverDisque $d.Name
  if (-not $id) { Alerte "$($d.Name) → disque non reconnu, renomme le dossier en commençant par son Discogs ID"; $aRevoir += "$($d.Name) : non reconnu"; $stats.ignores++; continue }
  if ($id.StartsWith('AMBIGU:')) { Alerte "$($d.Name) → plusieurs disques possibles : $($id.Substring(7)). Préfixe le dossier par le bon ID."; $aRevoir += "$($d.Name) : ambigu"; $stats.ignores++; continue }

  $fichiers = @(Get-ChildItem -LiteralPath $d.FullName -File -Recurse |
    Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() } |
    Sort-Object @{ Expression = { CleNaturelle ($_.FullName.Substring($d.FullName.Length)) } })
  if (-not $fichiers.Count) { Alerte "$($d.Name) → aucun fichier audio"; $stats.ignores++; continue }

  $info = $parId[$id]
  $label = if ($info) { "$($info.Artiste) – $($info.Titre)" } else { $d.Name }
  Write-Host ''
  Write-Host "  $id  $label  ($($fichiers.Count) fichiers)" -ForegroundColor White
  if (-not $info -and $catalogue.Count) { Alerte "ID $id absent du Google Sheets (vérifie release_discogs_id)"; $aRevoir += "$($d.Name) : ID $id absent du Sheets" }
  elseif ($info -and $info.Pistes -and $info.Pistes -ne $fichiers.Count) {
    Alerte "La tracklist du Sheets a $($info.Pistes) morceaux mais le dossier contient $($fichiers.Count) fichiers : les numéros risquent d'être décalés"
    $aRevoir += "$($d.Name) : $($fichiers.Count) fichiers pour $($info.Pistes) morceaux"
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
Ok "$($stats.disques) disques traités, $($stats.convertis) fichiers convertis, $($stats.ajour) déjà à jour$mode"
if ($stats.ignores) { Alerte "$($stats.ignores) dossiers ignorés" }
$ids = @(Get-ChildItem -LiteralPath $Sortie -Filter '*_1.mp3' | ForEach-Object { $_.Name -replace '_1\.mp3$', '' } | Sort-Object)
$ids | Set-Content -LiteralPath (Join-Path $Sortie '_disques-avec-audio.txt') -Encoding UTF8
Info "$($ids.Count) disques ont de l'audio (liste : $(Join-Path $Sortie '_disques-avec-audio.txt'))"
if ($aRevoir.Count) {
  Write-Host ''; Write-Host '  À revoir :' -ForegroundColor Yellow
  $aRevoir | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
}
Write-Host ''
