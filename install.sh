
#!/bin/bash
set -Eeuo pipefail

# curl -L https://raw.githubusercontent.com/DreamerCG/Quiver-Batocera/main/install.sh | bash


REPO="DreamerCG/Quiver-Batocera"
BRANCH="main"
BASE_DIR="/userdata"
INSTALL_DIR="${BASE_DIR}/system/Quiver"
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

    # --exclude='/Quiver/emulator/apps.json' \
    # --exclude='/Quiver/emulator/apps.json.lock' \
    # --exclude='/Quiver/emulator/settings.json' \

rsync -a \
    --exclude='/Quiver/emulator/apps.json' \
    --exclude='/Quiver/emulator/apps.json.lock' \
    --exclude='/Quiver/emulator/Apps/' \
    --exclude='/Quiver/emulator/Backups/' \
    --exclude='/Quiver/emulator/Cache/' \
    "${SOURCE_DIR}/system/" "${BASE_DIR}/system/" \
    || die "Échec de la copie de system/."


# Copie des fichiers ROM sans écraser ceux déjà présents.
log "Installation des définitions de lancement..."

rsync -a --ignore-existing \
    "${SOURCE_DIR}/roms/" "${BASE_DIR}/roms/" \
    || die "Échec de la copie de roms/."

# Permissions d'exécution
APPIMAGE="${INSTALL_DIR}/emulator/QuiverLauncher-linux-x64.AppImage"
EXIT_SCRIPT="${INSTALL_DIR}/emulator/exit_quiver.sh"

[[ -f "$APPIMAGE" ]] || die "AppImage Quiver introuvable."
[[ -f "$EXIT_SCRIPT" ]] || die "exit_quiver.sh introuvable."

log "Application des permissions..."
chmod +x "$APPIMAGE" "$EXIT_SCRIPT" \
    || die "Impossible d'appliquer les permissions."

if [[ -d "${INSTALL_DIR}/bin" ]]; then
    find "${INSTALL_DIR}/bin" -maxdepth 1 -type f -exec chmod +x {} +
fi


# Version enregistrée uniquement après les opérations réussies
log "Enregistrement de la version ${VERSION}..."

printf '%s\n' "$VERSION" > "${INSTALL_DIR}/VERSION.tmp" \
    || die "Impossible d'écrire le fichier VERSION."

mv -f "${INSTALL_DIR}/VERSION.tmp" "${INSTALL_DIR}/VERSION"

log "Installation de Quiver ${VERSION} terminée."
