# Pipeline audio DandyRecords

Ces outils prennent ta bibliothèque musicale telle qu'elle est rangée (`Artiste\Année - Album\morceaux`). Ils retrouvent les albums qui sont dans ton stock (le Google Sheets du kiosk), convertissent leurs morceaux en **MP3 256 kbps**, les renomment pour le kiosk (`{discogs_id}_1.mp3`…) et les envoient sur Cloudflare R2.

Tes fichiers d'origine ne sont jamais modifiés. Les albums qui ne sont pas en stock sont ignorés.

## Les 3 fichiers à double-cliquer

| Fichier | Quand |
|---|---|
| `Installer.bat` | une seule fois au début (ou pour changer de dossier / de token R2) |
| `Simulation.bat` | pour voir ce qui serait fait, sans rien toucher |
| `Convertir-et-envoyer.bat` | à chaque fois que tu as de nouveaux albums ou de nouveaux disques en stock |

---

## Installation (une fois, ~10 min)

1. Sur GitHub, page du repo → bouton vert **Code** → **Download ZIP**. Dézippe, et copie le dossier **`tools`** où tu veux (par ex. `Documents\dandy-tools`).
2. Ouvre un onglet sur **dash.cloudflare.com** (tu en auras besoin à l'étape 3 de l'installeur).
3. Double-clic sur **`Installer.bat`** et suis les questions :
   - **Logiciels** : installe ffmpeg et rclone. Si Windows demande une autorisation, accepte.
   - **Dossier de musique** : une fenêtre s'ouvre, choisis le dossier qui contient tes dossiers d'artistes.
   - **Cloudflare R2** : l'installeur te dit où cliquer pour créer une clé d'accès, puis te demande de coller 4 valeurs : nom du bucket, Access Key ID, Secret Access Key, endpoint. Pour coller dans la fenêtre noire, fais un **clic droit**. L'installeur teste ensuite la connexion.

Si Windows affiche « Windows a protégé votre ordinateur », clique sur **Informations complémentaires → Exécuter quand même**.

---

## Utilisation

1. Mets à jour ton stock dans le Google Sheets, comme d'habitude.
2. Double-clic sur **`Convertir-et-envoyer.bat`**.
3. Lis le **Bilan** à la fin :
   - **À revoir** : ce qui demande ton attention (voir ci-dessous).
   - **`_stock-sans-audio.txt`** : les disques en stock pour lesquels aucun album n'a été trouvé dans ta bibliothèque.
   - **`_dossiers-non-reconnus.txt`** : les albums de ta bibliothèque qui ne sont pas dans le stock (normal).

Les listes sont dans le dossier de sortie (`Musique\dandy-mp3`). Tu peux relancer autant que tu veux : ce qui est déjà fait est sauté.

### Comment un album est reconnu

Le script compare le chemin du dossier (`Mariya Takeuchi\1984 - Variety`) avec l'artiste, le titre et l'année du Google Sheets, sans tenir compte des accents ni de la ponctuation.

Si un album n'est pas reconnu, ou si plusieurs disques correspondent, **ajoute le Discogs ID au début du nom du dossier d'album** : `Mariya Takeuchi\26372551 - Variety`. L'ID est prioritaire sur tout le reste.

### Messages « À revoir » fréquents

- **« Le Sheets indique 10 morceaux, le dossier en contient 12 »** : ton rip a des bonus, ou il manque des pistes. Le kiosk numérote les morceaux dans l'ordre de la tracklist : avec un écart, le son ne correspond plus au titre affiché. Déplace les bonus dans un sous-dossier dont le nom commence par `_` (par ex. `_bonus`) : il sera ignoré.
- **« même disque que … »** : deux dossiers correspondent au même disque (par ex. l'original et un remaster). Mets le Discogs ID devant celui à utiliser.
- **« ID … absent du Google Sheets »** : l'ID devant le dossier ne correspond à aucune ligne du Sheets (faute de frappe ?).

### Règles de rangement

- Les morceaux sont pris dans l'ordre de leur nom de fichier : `01 - …`, `02 - …` (`2` passe bien avant `10`).
- Les sous-dossiers `CD1`, `CD2`, `Disc 1`… sont regroupés dans le même album.
- Tout dossier dont le nom commence par `_` est ignoré.

---

## Et dans le kiosk ?

Rien à faire. À chaque passage, le script envoie aussi sur R2 un petit fichier `audio-index.js` : la liste des disques qui ont du son. Le kiosk le lit au démarrage, ou à l'appui long sur le logo, et affiche les boutons ▶ sur ces disques. **Plus besoin de remplir la colonne `item_asset_link`** dans le Google Sheets. Si elle est remplie, elle reste prise en compte.

Pour vérifier que tous les morceaux se chargent, ouvre le kiosk avec **`?check`** à la fin de l'adresse.
