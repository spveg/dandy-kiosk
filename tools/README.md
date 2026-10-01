# Pipeline audio DandyRecords

Convertit les fichiers audio des disques (flac, wav, aiff, m4a, mp3…) en **MP3 256 kbps**,
les renomme au format du kiosk (`{discogs_id}_1.mp3`, `{discogs_id}_2.mp3`…) et les envoie sur Cloudflare R2.

Les fichiers d'origine ne sont jamais modifiés. Le script est relançable à volonté : ce qui est déjà fait est sauté.

---

## Installation (une seule fois)

### 1. Copier le dossier `tools` sur le PC

Récupère le dossier `tools` du repo (bouton **Code → Download ZIP** sur GitHub) et mets-le où tu veux, par exemple dans `Documents\dandy-tools`.

### 2. Installer ffmpeg et rclone

Ouvre PowerShell et lance :

```powershell
winget install Gyan.FFmpeg
winget install Rclone.Rclone
```

Ferme puis rouvre PowerShell pour qu'ils soient reconnus.

### 3. Connexion à R2

1. Dashboard Cloudflare → **R2** → **Manage R2 API Tokens** (ou « API » en haut à droite de la page R2) → **Create API token**.
2. Permissions : **Object Read & Write**, limité au bucket du kiosk.
3. Note les trois infos affichées (elles ne sont montrées qu'une fois) :
   - Access Key ID
   - Secret Access Key
   - l'endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`
4. Dans PowerShell, remplace les trois valeurs puis lance :

```powershell
rclone config create r2 s3 provider=Cloudflare access_key_id=TON_ACCESS_KEY secret_access_key=TON_SECRET endpoint=https://TON_ACCOUNT_ID.r2.cloudflarestorage.com acl=private no_check_bucket=true
```

5. Vérifie que ça marche (doit lister le nom de ton bucket) :

```powershell
rclone lsd r2:
```

Les identifiants restent sur ton PC, dans la config rclone. Ils ne sont jamais dans le repo.

### 4. Vérifier la config du script

En haut de `dandy-audio.ps1`, bloc `CONFIG` :

| Réglage | Rôle |
|---|---|
| `$Source` | dossier qui contient un sous-dossier par disque |
| `$Sortie` | où sont rangés les MP3 convertis (hors kDrive, pour ne pas les synchroniser) |
| `$R2` | `r2:` + **nom exact de ton bucket** (visible avec `rclone lsd r2:`) |

---

## Utilisation

1. Dans le dossier source, crée **un sous-dossier par disque** et mets-y ses fichiers audio, dans n'importe quel format.
2. Double-clic sur **`Convertir-et-envoyer.bat`**.
3. Lis le bilan en fin de fenêtre, en particulier la section **« À revoir »**.

### Nommer les dossiers

Le script doit savoir à quel disque correspond chaque dossier. Deux façons :

- **Le plus sûr** : faire commencer le nom par le Discogs ID → `22429213 - Anri - Timely`
- **Automatique** : laisser le nom « Artiste - Titre » de ton rip → `Anri - Timely!!`. Le script cherche le disque dans le Google Sheets. S'il ne trouve pas ou hésite entre plusieurs, il le signale dans « À revoir » : ajoute alors l'ID devant le nom du dossier.

Les dossiers dont le nom commence par `_` sont ignorés.

### Ordre des morceaux

Les fichiers sont numérotés dans l'ordre de leur nom, en ordre « naturel » : `2` avant `10`. Des noms de rip classiques (`01 - …`, `02 - …`) marchent tels quels. Les sous-dossiers `CD1`, `CD2` sont pris dans l'ordre.

Si le nombre de fichiers ne correspond pas au nombre de morceaux de la tracklist du Sheets, le script prévient. Les numéros risquent alors d'être décalés par rapport aux titres affichés dans le kiosk : vérifie qu'il ne manque pas une piste, ou qu'il n'y a pas un bonus en trop.

### Options

| Lanceur / commande | Effet |
|---|---|
| `Simulation.bat` | montre ce qui serait fait, sans rien convertir ni envoyer |
| `dandy-audio.ps1 -SansUpload` | convertit seulement |
| `dandy-audio.ps1 -Forcer` | reconvertit tout, même ce qui est déjà à jour |

---

## Derniers pas

- Dans le Google Sheets, la colonne `item_asset_link` des disques qui ont de l'audio doit contenir l'URL publique du bucket (`https://pub-….r2.dev/`). La liste des Discogs ID qui ont de l'audio est écrite dans `_disques-avec-audio.txt`, dans le dossier de sortie.
- Ouvre ensuite le kiosk avec `?check` à la fin de l'URL pour vérifier que tous les morceaux se chargent.
