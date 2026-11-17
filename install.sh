#!/bin/bash
set -Eeuo pipefail

# curl -L https://raw.githubusercontent.com/DreamerCG/Quiver-Batocera/main/install.sh | bash

REPO="DreamerCG/Quiver-Batocera"
BRANCH="main"
BASE_DIR="/userdata"
INSTALL_DIR="${BASE_DIR}/system/Quiver"
SERVICE_FILE="${BASE_DIR}/system/services/dcg_quiver_update"
LEGACY_SERVICE_FILE="${BASE_DIR}/system/services/quiver_update"
TMP_DIR="$(mktemp -d /tmp/quiver-install.XXXXXX)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
    printf '[Quiver] %s\n' "$*"
}

die() {
    printf '[Quiver] ERREUR : %s\n' "$*" >&2
    exit 1
}

# Vérifications initiales
[[ "$(id -u)" -eq 0 ]] || die "Lance ce script en root."
[[ -d "${BASE_DIR}/system" ]] || die "/userdata/system introuvable."
[[ -d "${BASE_DIR}/roms" ]] || die "/userdata/roms introuvable."

FIRST_SERVICE_INSTALL=0
if [[ ! -e "$SERVICE_FILE" || -e "$LEGACY_SERVICE_FILE" || ! -f "${INSTALL_DIR}/VERSION" ]]; then
    command -v batocera-services >/dev/null 2>&1 \
        || die "batocera-services est nécessaire pour activer le service de mise à jour."
    FIRST_SERVICE_INSTALL=1
fi

# Configuration Batocera : ajout des paramètres Quiver manquants (sans doublon)
BATOCERA_CONF="${BASE_DIR}/system/batocera.conf"
touch "$BATOCERA_CONF" || die "Impossible de créer ${BATOCERA_CONF}."

# Sauvegarde (une seule, écrasée à chaque installation)
cp -p "$BATOCERA_CONF" "${BATOCERA_CONF}.quiver.bak" \
    || die "Impossible de sauvegarder batocera.conf."

# Saut de ligne final si absent
if [[ -n "$(tail -c1 "$BATOCERA_CONF")" ]]; then
    echo >> "$BATOCERA_CONF" || die "Impossible d'écrire dans ${BATOCERA_CONF}."
fi

grep -q '^quiver\.bezel=' "$BATOCERA_CONF" \
    || { echo 'quiver.bezel=none' >> "$BATOCERA_CONF" \
         && log "Paramètre quiver.bezel=none ajouté."; } \
    || die "Impossible d'ajouter quiver.bezel."

grep -q '^quiver\.LAUNCHER_QUIVER=' "$BATOCERA_CONF" \
    || { echo 'quiver.LAUNCHER_QUIVER=off' >> "$BATOCERA_CONF" \
         && log "Paramètre quiver.LAUNCHER_QUIVER=off ajouté."; } \
    || die "Impossible d'ajouter quiver.LAUNCHER_QUIVER."

if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_CMD="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_CMD="wget"
else
    die "curl ou wget est nécessaire."
fi

command -v rsync >/dev/null 2>&1 || die "rsync est nécessaire."

ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
ARCHIVE="${TMP_DIR}/quiver.tar.gz"

# Téléchargement
log "Téléchargement du dépôt GitHub..."
if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
    curl -fLsS --retry 2 --connect-timeout 15 \
        "$ARCHIVE_URL" -o "$ARCHIVE" \
        || die "Échec du téléchargement GitHub."
else
    wget -q "$ARCHIVE_URL" -O "$ARCHIVE" \
        || die "Échec du téléchargement GitHub."
fi

# Extraction
mkdir -p "${TMP_DIR}/extract"
tar -xzf "$ARCHIVE" -C "${TMP_DIR}/extract" \
    || die "Archive GitHub invalide."

SOURCE_DIR="$(find "${TMP_DIR}/extract" \
    -mindepth 1 -maxdepth 1 -type d -print -quit)"

[[ -n "$SOURCE_DIR" ]] || die "Dossier source introuvable."
[[ -d "${SOURCE_DIR}/system" ]] || die "Dossier system/ absent."
[[ -d "${SOURCE_DIR}/roms" ]] || die "Dossier roms/ absent."
[[ -s "${SOURCE_DIR}/VERSION" ]] || die "Fichier VERSION absent."

VERSION="$(head -n 1 "${SOURCE_DIR}/VERSION" | tr -d '\r\n[:space:]')"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Format VERSION invalide : ${VERSION}"

# Copie du système.
# Les données personnelles de Quiver sont exclues pour éviter de les écraser.
log "Installation des fichiers système..."


rsync -a \
    --exclude='/Quiver/emulator/QuiverLauncher-linux-x64.AppImage' \
    --exclude='/Quiver/emulator/apps.json' \
    --exclude='/Quiver/emulator/settings.json' \
    --exclude='/Quiver/emulator/apps.json.lock' \
    --exclude='/Quiver/emulator/Apps/' \
    --exclude='/Quiver/emulator/Backups/' \
    --exclude='/Quiver/emulator/Cache/' \
    "${SOURCE_DIR}/system/" "${BASE_DIR}/system/" \
    || die "Échec de la copie de system/."

# settings.json / apps.json : ne jamais écraser les données utilisateur
SRC_EMU="${SOURCE_DIR}/system/Quiver/emulator"
DST_EMU="${INSTALL_DIR}/emulator"
mkdir -p "$DST_EMU"

if [[ -f "${SRC_EMU}/settings.json" && ! -f "${DST_EMU}/settings.json" ]]; then
    log "Installation de settings.json (absent)."
    cp "${SRC_EMU}/settings.json" "${DST_EMU}/settings.json" \
        || die "Impossible de copier settings.json."
fi

if [[ -f "${SRC_EMU}/apps.json" ]]; then
    if [[ ! -f "${DST_EMU}/apps.json" ]]; then
        log "Installation de apps.json (absent)."
        cp "${SRC_EMU}/apps.json" "${DST_EMU}/apps.json" \
            || die "Impossible de copier apps.json."
    else
        log "Fusion de apps.json (sans doublon)..."
        command -v python3 >/dev/null 2>&1 || die "python3 est nécessaire pour fusionner apps.json."
        python3 - "${SRC_EMU}/apps.json" "${DST_EMU}/apps.json" <<'PY' \
            || die "Échec de la fusion de apps.json (fichier existant conservé)."
import json, os, shutil, sys, tempfile

src_path, dst_path = sys.argv[1], sys.argv[2]

def load(path):
    with open(path, encoding="utf-8-sig") as f:  # tolère le BOM
        data = json.load(f)
    if not isinstance(data.get("apps"), list):
        raise ValueError(f"{path} : clé 'apps' absente ou invalide")
    return data

src, dst = load(src_path), load(dst_path)  # si dst est invalide : on s'arrête sans rien écraser

seen, merged = set(), []
for app in dst["apps"] + src["apps"]:      # l'existant est prioritaire
    key = str(app.get("folderName", "")).strip().lower()
    if not key or key in seen:
        continue
    seen.add(key)
    merged.append(app)

added = len(merged) - len({str(a.get("folderName", "")).strip().lower() for a in dst["apps"]})
dst["apps"] = merged

shutil.copy2(dst_path, dst_path + ".bak")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst_path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(dst, f, indent=2, ensure_ascii=False)
os.replace(tmp, dst_path)
print(f"[Quiver] apps.json : {added} entrée(s) ajoutée(s), {len(merged)} au total.")
PY
    fi
fi


# Copie des fichiers ROM sans écraser ceux déjà présents.
log "Installation des définitions de lancement..."

rsync -a --ignore-existing \
    "${SOURCE_DIR}/roms/" "${BASE_DIR}/roms/" \
    || die "Échec de la copie de roms/."

# Permissions d'exécution
APPIMAGE="${INSTALL_DIR}/emulator/QuiverLauncher-linux-x64.AppImage"
LAUNCHER_UPDATER="${INSTALL_DIR}/bin/quiver-update-launcher"
EXIT_SCRIPT="${INSTALL_DIR}/emulator/exit_quiver.sh"
WINE_LAUNCHER="${INSTALL_DIR}/bin/quiver-wine"
LEGACY_WINE_LAUNCHER="${INSTALL_DIR}/bin/batocera-wine"

[[ -f "$LAUNCHER_UPDATER" ]] || die "Mise à jour du launcher Quiver introuvable."
if ! bash "$LAUNCHER_UPDATER"; then
    die "Échec de la mise à jour du launcher Quiver."
fi
[[ -f "$APPIMAGE" ]] || die "AppImage Quiver introuvable."
[[ -f "$EXIT_SCRIPT" ]] || die "exit_quiver.sh introuvable."
[[ -f "$WINE_LAUNCHER" ]] || die "Launcher Wine Quiver introuvable."

log "Application des permissions..."
chmod +x "$APPIMAGE" "$EXIT_SCRIPT" "$WINE_LAUNCHER" \
    || die "Impossible d'appliquer les permissions."

if [[ -d "${INSTALL_DIR}/bin" ]]; then
    find "${INSTALL_DIR}/bin" -maxdepth 1 -type f -exec chmod +x {} +
fi

if [[ -f "$LEGACY_WINE_LAUNCHER" || -L "$LEGACY_WINE_LAUNCHER" ]]; then
    rm -f -- "$LEGACY_WINE_LAUNCHER" \
        || die "Impossible de retirer l'ancien launcher Wine."
    log "Ancien launcher batocera-wine retiré."
fi

[[ -f "$SERVICE_FILE" ]] || die "Service de mise à jour Quiver introuvable."
chmod +x "$SERVICE_FILE" || die "Impossible de rendre le service de mise à jour exécutable."
if [[ -e "$LEGACY_SERVICE_FILE" ]]; then
    if command -v batocera-services >/dev/null 2>&1; then
        batocera-services disable quiver_update >/dev/null 2>&1 || true
    fi
    rm -f -- "$LEGACY_SERVICE_FILE" \
        || die "Impossible de retirer l'ancien service quiver_update."
    log "Ancien service quiver_update remplacé par dcg_quiver_update."
fi
if [[ "$FIRST_SERVICE_INSTALL" -eq 1 ]]; then
    batocera-services enable dcg_quiver_update \
        || die "Impossible d'activer le service de mise à jour Quiver."
    log "Service de mise à jour activé pour le prochain démarrage."
fi

printf '%s\n' "$VERSION" > "${INSTALL_DIR}/VERSION.tmp" \
    || die "Impossible d'écrire la version installée."
mv -f "${INSTALL_DIR}/VERSION.tmp" "${INSTALL_DIR}/VERSION" \
    || die "Impossible d'enregistrer la version installée."

log "Quiver ${VERSION} installé avec succès."