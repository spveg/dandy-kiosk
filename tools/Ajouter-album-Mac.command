#!/bin/bash
# DandyRecords — ajouter des albums depuis un Mac
#
# Double-clic dans le Finder (la 1re fois : clic droit → Ouvrir).
# Pour chaque album glissé dans la fenêtre :
#   1. trouve le Discogs ID (début du nom du dossier, sinon il le demande)
#   2. convertit les morceaux (flac, wav, aiff, m4a…) en MP3 256 kbps : {id}_1.mp3, {id}_2.mp3…
#   3. les envoie sur Cloudflare R2 et ajoute le disque à audio-index.js (bouton ▶ dans le kiosk)
# Compatible avec le bash de macOS (3.2). Les fichiers d'origine ne sont jamais modifiés.

BITRATE=256k
SORTIE="${DANDY_SORTIE:-$HOME/Music/dandy-mp3}"
CONF_DIR="${DANDY_CONF_DIR:-$HOME/.config/dandy-kiosk}"
PUBLIC_URL="${DANDY_PUBLIC_URL:-https://pub-f14efcab169e4fa4bf7784d6d3d5f958.r2.dev}"
EXTS='flac|wav|aif|aiff|m4a|alac|mp3|ogg|opus|wv|ape'

# Homebrew n'est pas dans le PATH quand on lance depuis le Finder
for d in /opt/homebrew/bin /usr/local/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
export PATH

V=$'\033[35m'; G=$'\033[32m'; J=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
titre()  { printf '\n%s── %s%s\n' "$V" "$1" "$N"; }
ok()     { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
info()   { printf '  · %s\n' "$1"; }
alerte() { printf '  %s!%s %s\n' "$J" "$N" "$1"; }
erreur() { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
oui()    { local r; read -r -p "  $1 (o/n) " r; case "$r" in [oOyY]*) return 0;; *) return 1;; esac; }
fin()    { printf '\n'; read -r -p "  Appuie sur Entrée pour fermer." _; exit "${1:-0}"; }

# chemin glissé dans le Terminal : "Mon\ Dossier/" ou '…' → chemin normal
nettoyer_chemin() {
  printf '%s' "$1" | sed -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/' -e 's/\\\(.\)/\1/g'
}

# tri "naturel" : 2 avant 10 (perl est fourni avec macOS)
tri_naturel() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'my @l=<STDIN>; print sort { my ($x,$y)=(lc $a, lc $b); s/(\d+)/sprintf("%010d",$1)/ge for $x,$y; $x cmp $y } @l'
  else LC_ALL=C sort; fi
}

printf '\n  %sDandyRecords — ajout d'"'"'albums depuis le Mac%s\n' "$B" "$N"

# ── 1. ffmpeg ─────────────────────────────────────────────────────────
titre 'Vérifications'
if ! command -v ffmpeg >/dev/null 2>&1; then
  alerte "ffmpeg (le convertisseur) n'est pas installé."
  if command -v brew >/dev/null 2>&1; then
    if oui "L'installer maintenant avec Homebrew ? (quelques minutes)"; then
      brew install ffmpeg || { erreur "Installation échouée."; fin 1; }
    else fin 1; fi
  else
    erreur "Homebrew n'est pas installé non plus. Colle cette ligne dans le Terminal, puis relance ce script :"
    printf '\n    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n'
    fin 1
  fi
fi
ok 'ffmpeg'
mkdir -p "$SORTIE" || { erreur "Impossible de créer $SORTIE"; fin 1; }
ok "Sortie : $SORTIE"

# ── 2. Albums ─────────────────────────────────────────────────────────
IDS_FAITS=()
while true; do
  titre 'Album'
  printf '  Glisse le dossier d'"'"'un album dans cette fenêtre puis appuie sur Entrée\n'
  printf '  (ou appuie juste sur Entrée quand tu as fini) :\n  '
  read -r brut
  chemin=$(nettoyer_chemin "$brut")
  [ -z "$chemin" ] && break
  chemin="${chemin%/}"
  if [ ! -d "$chemin" ]; then erreur "Dossier introuvable : $chemin"; continue; fi
  nom=$(basename "$chemin")

  id=''
  if [[ "$nom" =~ ^[[:space:]]*\[?r?([0-9]{5,}) ]]; then id="${BASH_REMATCH[1]}"; fi
  if [ -n "$id" ]; then
    ok "Discogs ID lu dans le nom du dossier : $id"
  else
    info "Pas d'ID au début du nom « $nom »."
    info "Tu le trouves dans le Google Sheets, colonne release_discogs_id."
    read -r -p "  Discogs ID : " id
    id=$(printf '%s' "$id" | tr -cd '0-9')
    if [ -z "$id" ]; then erreur "ID vide, album ignoré."; continue; fi
  fi

  # morceaux, dans l'ordre naturel des noms (sous-dossiers CD1/CD2 compris, dossiers en _ ignorés)
  fichiers=()
  while IFS= read -r f; do [ -n "$f" ] && fichiers+=("$f"); done < <(
    cd "$chemin" && find . -type f 2>/dev/null | grep -iE "\.($EXTS)\$" | grep -v '/_' | grep -v '/\._' | tri_naturel
  )
  n=${#fichiers[@]}
  if [ "$n" -eq 0 ]; then erreur "Aucun fichier audio dans ce dossier."; continue; fi

  printf '\n'
  i=1; for f in "${fichiers[@]}"; do printf '    %-16s ← %s\n' "${id}_${i}.mp3" "${f#./}"; i=$((i+1)); done
  printf '\n'
  info "Vérifie que l'ordre correspond à la tracklist du disque."
  oui "Convertir ces $n morceaux ?" || { info 'Album ignoré.'; continue; }

  erreurs=0; i=1
  for f in "${fichiers[@]}"; do
    dst="$SORTIE/${id}_${i}.mp3"; tmp="$dst.part.mp3"
    printf '  %s (%d/%d)…\r' "${id}_${i}.mp3" "$i" "$n"
    if ffmpeg -nostdin -hide_banner -loglevel error -y -i "$chemin/${f#./}" -map 0:a:0 -vn -c:a libmp3lame -b:a "$BITRATE" -ar 44100 -map_metadata 0 -id3v2_version 3 "$tmp" && [ -s "$tmp" ]; then
      mv -f "$tmp" "$dst"
    else
      rm -f "$tmp"; erreur "échec : ${f#./}"; erreurs=$((erreurs+1))
    fi
    i=$((i+1))
  done
  # anciens MP3 en trop pour ce disque (morceau retiré)
  for old in "$SORTIE/${id}_"*.mp3; do
    [ -e "$old" ] || continue
    k=$(basename "$old" .mp3); k=${k#${id}_}
    case "$k" in *[!0-9]*|'') continue;; esac
    [ "$k" -gt "$n" ] && rm -f "$old"
  done
  if [ "$erreurs" -eq 0 ]; then ok "$n morceaux convertis"; IDS_FAITS+=("$id")
  else alerte "$((n-erreurs))/$n morceaux convertis, $erreurs en échec"; IDS_FAITS+=("$id"); fi
done

if [ ${#IDS_FAITS[@]} -eq 0 ]; then info 'Aucun album converti.'; fin 0; fi

# ── 3. Connexion R2 (une seule fois) ──────────────────────────────────
titre 'Envoi sur Cloudflare R2'
BUCKET=''; [ -f "$CONF_DIR/bucket" ] && BUCKET=$(cat "$CONF_DIR/bucket")
r2_pret() { command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -qx 'r2:' && [ -n "$BUCKET" ]; }

if ! r2_pret; then
  info "L'envoi automatique n'est pas encore configuré sur ce Mac."
  if oui "Le configurer maintenant ? (5 min, une seule fois)"; then
    if ! command -v rclone >/dev/null 2>&1; then
      if command -v brew >/dev/null 2>&1; then brew install rclone; fi
    fi
    if command -v rclone >/dev/null 2>&1; then
      printf '\n'
      info 'Sur dash.cloudflare.com :'
      info '  a. R2 Object Storage → note le NOM de ton bucket'
      info '  b. Manage API tokens → Create API token'
      info '     Permissions : Object Read & Write, sur ton bucket → Create'
      info '  c. Copie ici les valeurs affichées (montrées une seule fois)'
      printf '\n'
      read -r -p "  Nom du bucket : " BUCKET
      read -r -p "  Access Key ID : " KEY
      read -r -p "  Secret Access Key : " SECRET
      read -r -p "  Endpoint (https://….r2.cloudflarestorage.com) : " ENDPOINT
      case "$ENDPOINT" in http*) ;; *) ENDPOINT="https://$ENDPOINT.r2.cloudflarestorage.com";; esac
      ENDPOINT=$(printf '%s' "$ENDPOINT" | sed -E 's#(r2\.cloudflarestorage\.com).*#\1#')
      rclone config delete r2 >/dev/null 2>&1
      rclone config create r2 s3 provider Cloudflare access_key_id "$KEY" secret_access_key "$SECRET" \
        endpoint "$ENDPOINT" acl private no_check_bucket true >/dev/null
      test_f="$SORTIE/_test-connexion.txt"; echo test > "$test_f"
      if rclone copyto "$test_f" "r2:$BUCKET/_test-connexion.txt" --s3-no-check-bucket >/dev/null 2>&1; then
        rclone deletefile "r2:$BUCKET/_test-connexion.txt" >/dev/null 2>&1
        mkdir -p "$CONF_DIR" && printf '%s' "$BUCKET" > "$CONF_DIR/bucket"
        ok "Connexion à R2 OK (bucket : $BUCKET)"
      else
        erreur 'Connexion refusée : vérifie le nom du bucket et les clés, puis relance le script.'
        BUCKET=''
      fi
      rm -f "$test_f"
    else
      erreur "rclone n'a pas pu être installé (Homebrew manquant ?)."
    fi
  fi
fi

if r2_pret; then
  includes=(); for id in "${IDS_FAITS[@]}"; do includes+=(--include "${id}_*.mp3"); done
  if rclone copy "$SORTIE" "r2:$BUCKET" "${includes[@]}" --transfers 6 --s3-no-check-bucket --stats-one-line --progress; then
    ok 'Morceaux envoyés'
  else
    erreur 'Envoi incomplet : relance le script (les albums déjà convertis ne sont pas refaits).'; fin 1
  fi

  # audio-index.js : on part de la version en ligne et on ajoute les nouveaux disques
  code=$(curl -s -o "$SORTIE/_audio-index-en-ligne.js" -w '%{http_code}' "$PUBLIC_URL/audio-index.js?t=$(date +%s)")
  if [ "$code" = 200 ] || [ "$code" = 404 ]; then
    [ "$code" = 404 ] && : > "$SORTIE/_audio-index-en-ligne.js"
    ids=$( { grep -oE '"[0-9]+"' "$SORTIE/_audio-index-en-ligne.js" | tr -d '"'; printf '%s\n' "${IDS_FAITS[@]}"; } | sort -u | sed 's/.*/"&"/' | paste -s -d, -)
    printf 'window.DANDY_AUDIO={"ids":[%s],"at":"%s"};' "$ids" "$(date +%Y-%m-%dT%H:%M:%S)" > "$SORTIE/audio-index.js"
    if rclone copyto "$SORTIE/audio-index.js" "r2:$BUCKET/audio-index.js" --s3-no-check-bucket; then
      ok 'Liste des disques avec audio mise à jour'
      printf '\n  %sSur l'"'"'iPad : garde le doigt 1,5 s sur le logo pour voir les nouveaux boutons ▶.%s\n' "$B" "$N"
    else
      alerte "Liste non mise à jour : dans le Google Sheets, colle $PUBLIC_URL/ dans item_asset_link pour : ${IDS_FAITS[*]}"
    fi
  else
    alerte "Impossible de lire la liste en ligne (réseau ?). Elle n'a pas été modifiée pour ne rien perdre."
    alerte "Dans le Google Sheets, colle $PUBLIC_URL/ dans item_asset_link pour : ${IDS_FAITS[*]}"
  fi
  rm -f "$SORTIE/_audio-index-en-ligne.js"
else
  printf '\n'
  info 'Envoi manuel :'
  info "  1. dash.cloudflare.com → R2 → ton bucket → Upload : glisse les fichiers ${IDS_FAITS[*]/%/_*.mp3}"
  info "  2. Google Sheets : colle $PUBLIC_URL/ dans item_asset_link de ces disques"
  info "  3. iPad : appui long sur le logo"
  open "$SORTIE" 2>/dev/null
fi

fin 0
