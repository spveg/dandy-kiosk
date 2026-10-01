<#
  DandyRecords — installation du pipeline audio (à lancer une fois via Installer.bat)

  1. installe ffmpeg et rclone (via winget)
  2. te fait choisir le dossier où est ta musique
  3. configure la connexion à Cloudflare R2 et la teste
  4. enregistre les réglages dans dandy-config.json

  Relançable sans risque : il garde ce qui est déjà en place et propose de le changer.
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$ConfigPath = Join-Path $PSScriptRoot 'dandy-config.json'

function Titre($t) { Write-Host ''; Write-Host "══ $t " -ForegroundColor Magenta }
function Ok($t)    { Write-Host "  ✓ $t" -ForegroundColor Green }
function Info($t)  { Write-Host "  $t" -ForegroundColor Gray }
function Erreur($t){ Write-Host "  ✗ $t" -ForegroundColor Red }
function Demander($question, $defaut) {
  $suffixe = if ($defaut) { " [$defaut]" } else { '' }
  $r = Read-Host "  $question$suffixe"
  if (-not $r) { return $defaut }
  return $r.Trim()
}
function OuiNon($question) { return (Read-Host "  $question (o/n)") -match '^[oOyY]' }
function RechargerPath { $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') }

$cfg = [ordered]@{ source = ''; sortie = "$env:USERPROFILE\Music\dandy-mp3"; bucket = '' }
if (Test-Path -LiteralPath $ConfigPath) {
  $old = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($k in @('source','sortie','bucket')) { if ($old.$k) { $cfg[$k] = $old.$k } }
}

Write-Host ''
Write-Host '  DandyRecords — installation du pipeline audio' -ForegroundColor White
Info 'Compte 5 à 10 minutes. Garde un onglet ouvert sur dash.cloudflare.com pour l''étape 3.'

# ── 1. Logiciels ───────────────────────────────────────────────────────
Titre '1/3  Logiciels (ffmpeg pour convertir, rclone pour envoyer)'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Erreur 'winget est absent. Installe « App Installer » depuis le Microsoft Store, puis relance Installer.bat.'
  exit 1
}
foreach ($outil in @(@{ cmd = 'ffmpeg'; pkg = 'Gyan.FFmpeg' }, @{ cmd = 'rclone'; pkg = 'Rclone.Rclone' })) {
  if (Get-Command $outil.cmd -ErrorAction SilentlyContinue) { Ok "$($outil.cmd) déjà installé"; continue }
  Info "Installation de $($outil.cmd)… (une fenêtre Windows peut demander une autorisation : accepte)"
  & winget install --id $outil.pkg -e --accept-package-agreements --accept-source-agreements
  RechargerPath
  if (Get-Command $outil.cmd -ErrorAction SilentlyContinue) { Ok "$($outil.cmd) installé" }
  else { Erreur "$($outil.cmd) ne répond pas encore. Ferme cette fenêtre et relance Installer.bat : ça suffit en général."; exit 1 }
}

# ── 2. Dossier de musique ──────────────────────────────────────────────
Titre '2/3  Où est ta musique ?'
Info 'Choisis le dossier qui contient tes dossiers d''artistes (ex. le dossier qui contient « Mariya Takeuchi »).'
Info 'Le script ne prendra que les albums qui sont dans ton stock ; le reste est ignoré.'
$changer = $true
if ($cfg.source -and (Test-Path -LiteralPath $cfg.source)) {
  Ok "Actuel : $($cfg.source)"
  $changer = OuiNon 'Changer de dossier ?'
}
if ($changer) {
  $choisi = $null
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Dossier qui contient ta musique (un sous-dossier par artiste)'
    $dlg.ShowNewFolderButton = $false
    Info '→ Une fenêtre de sélection de dossier vient de s''ouvrir (elle est peut-être derrière celle-ci).'
    if ($dlg.ShowDialog() -eq 'OK') { $choisi = $dlg.SelectedPath }
  } catch { }
  if (-not $choisi) { $choisi = Demander 'Colle le chemin du dossier (clic droit sur le dossier → Copier en tant que chemin d''accès)' $cfg.source }
  $choisi = "$choisi".Trim('"', ' ')
  if (-not (Test-Path -LiteralPath $choisi)) { Erreur "Dossier introuvable : $choisi"; exit 1 }
  $cfg.source = $choisi
  Ok "Musique : $choisi"
}
Info "Les MP3 convertis seront rangés dans : $($cfg.sortie)"

# ── 3. Cloudflare R2 ───────────────────────────────────────────────────
Titre '3/3  Connexion à Cloudflare R2'
$remoteOk = ((& rclone listremotes) -contains 'r2:')
$refaire = $true
if ($remoteOk -and $cfg.bucket) {
  Ok "Déjà configuré (bucket : $($cfg.bucket))"
  $refaire = OuiNon 'Refaire la connexion (nouveau token, autre bucket) ?'
}
if ($refaire) {
  Write-Host ''
  Info 'Dans ton navigateur, sur dash.cloudflare.com :'
  Info '  a. Menu de gauche → R2 Object Storage. Note le NOM de ton bucket (colonne Name).'
  Info '  b. Sur cette même page R2, bouton « Manage API tokens » (ou « API » → Manage API tokens).'
  Info '  c. « Create API token » (choisis le token de type Account si on te demande)'
  Info '       - Permissions : Object Read & Write'
  Info '       - Specify bucket(s) : ton bucket'
  Info '       - puis « Create API Token » en bas'
  Info '  d. La page suivante affiche 3 valeurs à copier ICI (elles ne sont montrées qu''une fois) :'
  Info '       Access Key ID, Secret Access Key, et l''endpoint https://xxxx.r2.cloudflarestorage.com'
  Info '  (Astuce : pour coller dans cette fenêtre, fais un clic droit.)'
  Write-Host ''
  $bucket   = Demander 'Nom du bucket' $cfg.bucket
  $keyId    = Demander 'Access Key ID' ''
  $secret   = Demander 'Secret Access Key' ''
  $endpoint = Demander 'Endpoint (https://….r2.cloudflarestorage.com) ou Account ID' ''
  if (-not $bucket -or -not $keyId -or -not $secret -or -not $endpoint) { Erreur 'Il manque une valeur. Relance Installer.bat.'; exit 1 }
  if ($endpoint -notmatch '^https?://') { $endpoint = "https://$endpoint.r2.cloudflarestorage.com" }
  $endpoint = $endpoint -replace '(r2\.cloudflarestorage\.com).*$', '$1'     # retire un éventuel /nom-du-bucket collé à la fin

  if ($remoteOk) { & rclone config delete r2 | Out-Null }
  & rclone config create r2 s3 provider Cloudflare access_key_id $keyId secret_access_key $secret endpoint $endpoint acl private no_check_bucket true | Out-Null
  $cfg.bucket = $bucket

  Info 'Test de la connexion…'
  $test = "$PSScriptRoot\_test-connexion.txt"
  Set-Content -LiteralPath $test -Value 'test DandyRecords' -Encoding UTF8
  & rclone copyto $test "r2:$bucket/_test-connexion.txt" --s3-no-check-bucket 2>&1 | Out-Null
  $codeEnvoi = $LASTEXITCODE
  & rclone deletefile "r2:$bucket/_test-connexion.txt" 2>&1 | Out-Null
  Remove-Item -LiteralPath $test -ErrorAction SilentlyContinue
  if ($codeEnvoi -ne 0) {
    Erreur 'La connexion à R2 a échoué. Vérifie le nom du bucket, les clés copiées (sans espace) et que le token a bien « Object Read & Write ».'
    Erreur 'Puis relance Installer.bat.'
    exit 1
  }
  Ok "Connexion à R2 OK (bucket : $bucket)"
}

# ── Enregistrement ─────────────────────────────────────────────────────
($cfg | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Titre 'Terminé'
Ok "Réglages enregistrés dans $ConfigPath"
Info 'Prochaine étape : double-clic sur « Simulation.bat » pour voir quels albums seront pris,'
Info 'puis sur « Convertir-et-envoyer.bat » pour lancer pour de vrai.'
Write-Host ''
