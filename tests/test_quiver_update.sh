#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export TEST_ROOT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/userdata/system" "$TEST_ROOT/userdata/roms"
export PATH="$TEST_ROOT/bin:$PATH"

cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/bash
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output="$2"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
case "$url" in
    */VERSION)
        [ "${FAKE_NETWORK_FAIL:-0}" = 0 ] || exit 1
        printf '%s\n' "$FAKE_VERSION"
        ;;
    */install.sh)
        cp "$FAKE_INSTALLER" "$output"
        ;;
    *api.github.com/repos/tgeorgiadis/quiver-launcher/releases*)
        [ "${FAKE_API_FAIL:-0}" = 0 ] || exit 1
        cp "$FAKE_RELEASES" "$output"
        ;;
    *github.com/tgeorgiadis/quiver-launcher/releases/download/*)
        echo "$url" >> "$TEST_ROOT/launcher-downloads"
        [ "${FAKE_ASSET_FAIL:-0}" = 0 ] || exit 1
        cp "$FAKE_APPIMAGE" "$output"
        ;;
    *)
        : > "$output"
        ;;
esac
EOF
cat > "$TEST_ROOT/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TEST_ROOT/bin/id" <<'EOF'
#!/bin/bash
echo 0
EOF
cat > "$TEST_ROOT/bin/batocera-services" <<'EOF'
#!/bin/bash
echo "$*" >> "$TEST_ROOT/enabled"
EOF
cat > "$TEST_ROOT/bin/tar" <<'EOF'
#!/bin/bash
mkdir -p "$4/source"
cp -R "$FAKE_SOURCE/." "$4/source/"
EOF
cat > "$TEST_ROOT/bin/rsync" <<'EOF'
#!/bin/bash
[ "${FAKE_RSYNC_FAIL:-0}" = 0 ] || exit 1
for arg in "$@"; do previous="${last:-}"; last="$arg"; done
mkdir -p "$last"
cp -R "$previous/." "$last/"
EOF
chmod +x "$TEST_ROOT/bin/"*

sed \
    -e "s|^VERSION_FILE=.*|VERSION_FILE=\"$TEST_ROOT/userdata/system/Quiver/VERSION\"|" \
    -e "s|^LAUNCHER_UPDATER=.*|LAUNCHER_UPDATER=\"$TEST_ROOT/launcher-updater\"|" \
    -e "s|^LOG=.*|LOG=\"$TEST_ROOT/update.log\"|" \
    "$ROOT/system/services/quiver_update" > "$TEST_ROOT/service"
sed "s|^BASE_DIR=.*|BASE_DIR=\"$TEST_ROOT/userdata\"|" \
    "$ROOT/install.sh" > "$TEST_ROOT/installer"

mkdir -p "$TEST_ROOT/userdata/system/Quiver"
VERSION_FILE="$TEST_ROOT/userdata/system/Quiver/VERSION"
export FAKE_INSTALLER="$TEST_ROOT/fake-installer" FAKE_VERSION=1.2.0
cat > "$FAKE_INSTALLER" <<'EOF'
#!/bin/bash
echo called >> "$TEST_ROOT/installer-calls"
echo "[Quiver] Installation du launcher..."
exit "${FAKE_INSTALL_FAILURE:-0}"
EOF
cat > "$TEST_ROOT/launcher-updater" <<'EOF'
#!/bin/bash
echo called >> "$TEST_ROOT/launcher-checks"
exit "${FAKE_LAUNCHER_FAILURE:-0}"
EOF

echo 1.1.0 > "$VERSION_FILE"
bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"
[ "$(wc -l < "$TEST_ROOT/installer-calls")" -eq 1 ]
grep -q 'mise à jour terminée' "$TEST_ROOT/update.log"
grep -q 'Installation du launcher' "$TEST_ROOT/output"
grep -q 'Installation du launcher' "$TEST_ROOT/update.log"

rm "$VERSION_FILE"
bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"
[ "$(wc -l < "$TEST_ROOT/installer-calls")" -eq 2 ]

echo 1.2.0 > "$VERSION_FILE"
bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"
[ "$(wc -l < "$TEST_ROOT/installer-calls")" -eq 2 ]
[ "$(wc -l < "$TEST_ROOT/launcher-checks")" -eq 1 ]
echo 1.3.0 > "$VERSION_FILE"
bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"
[ "$(wc -l < "$TEST_ROOT/installer-calls")" -eq 2 ]
[ "$(wc -l < "$TEST_ROOT/launcher-checks")" -eq 2 ]
export FAKE_LAUNCHER_FAILURE=1
if bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"; then
    echo "Launcher update failure was not reported" >&2
    exit 1
fi
unset FAKE_LAUNCHER_FAILURE

echo invalid > "$VERSION_FILE"
if bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"; then
    echo "Invalid local version was accepted" >&2
    exit 1
fi

echo 1.1.0 > "$VERSION_FILE"
export FAKE_INSTALL_FAILURE=1
if bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"; then
    echo "Installer failure was not reported" >&2
    exit 1
fi
[ "$(cat "$VERSION_FILE")" = 1.1.0 ]
unset FAKE_INSTALL_FAILURE

export FAKE_VERSION=invalid
if bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"; then
    echo "Invalid remote version was accepted" >&2
    exit 1
fi
export FAKE_VERSION=1.2.0 FAKE_NETWORK_FAIL=1
if bash "$TEST_ROOT/service" update > "$TEST_ROOT/output"; then
    echo "Network failure was not reported" >&2
    exit 1
fi
unset FAKE_NETWORK_FAIL

bash "$TEST_ROOT/service" start
for ((attempt=1; attempt<=50; attempt++)); do
    [ "$(grep -c 'mise à jour terminée' "$TEST_ROOT/update.log")" -ge 3 ] && break
    /usr/bin/sleep 0.1
done
[ "$(wc -l < "$TEST_ROOT/installer-calls")" -eq 4 ]
[ "$(grep -c 'mise à jour terminée' "$TEST_ROOT/update.log")" -ge 3 ]

export FAKE_SOURCE="$TEST_ROOT/source"
export FAKE_RELEASES="$TEST_ROOT/releases.json" FAKE_APPIMAGE="$TEST_ROOT/appimage"
printf 'new launcher\n' > "$FAKE_APPIMAGE"
digest="$(sha256sum "$FAKE_APPIMAGE" | cut -d ' ' -f 1)"
cat > "$FAKE_RELEASES" <<EOF
[
  {"tag_name":"v4.0.0-beta.2","draft":false,"published_at":"2026-11-01T00:00:00Z","assets":[]},
  {"tag_name":"v4.0.0-beta.5","draft":false,"published_at":"2026-11-15T00:00:00Z","assets":[
    {"name":"QuiverLauncher_4.0.0-beta.5_amd64.AppImage","digest":"sha256:$digest",
     "browser_download_url":"https://github.com/tgeorgiadis/quiver-launcher/releases/download/v4.0.0-beta.5/QuiverLauncher_4.0.0-beta.5_amd64.AppImage"}]},
  {"tag_name":"v4.0.0-beta.6","draft":true,"published_at":"2026-11-16T00:00:00Z","assets":[]}
]
EOF
mkdir -p "$FAKE_SOURCE/system/Quiver/emulator" \
    "$FAKE_SOURCE/system/Quiver/bin" "$FAKE_SOURCE/system/services" "$FAKE_SOURCE/roms"
echo 1.2.0 > "$FAKE_SOURCE/VERSION"
touch "$FAKE_SOURCE/system/Quiver/emulator/exit_quiver.sh" "$FAKE_SOURCE/system/Quiver/bin/quiver-wine"
cp "$ROOT/system/services/quiver_update" "$FAKE_SOURCE/system/services/quiver_update"
sed "s|^INSTALL_DIR=.*|INSTALL_DIR=\"$TEST_ROOT/userdata/system/Quiver\"|" \
    "$ROOT/system/Quiver/bin/quiver-update-launcher" > "$FAKE_SOURCE/system/Quiver/bin/quiver-update-launcher"
rm "$VERSION_FILE"
bash "$TEST_ROOT/installer" > "$TEST_ROOT/output"
[ "$(cat "$VERSION_FILE")" = 1.2.0 ]
[ "$(cat "$TEST_ROOT/userdata/system/Quiver/LAUNCHER_VERSION")" = v4.0.0-beta.5 ]
cmp "$FAKE_APPIMAGE" "$TEST_ROOT/userdata/system/Quiver/emulator/QuiverLauncher-linux-x64.AppImage"
[ "$(wc -l < "$TEST_ROOT/launcher-downloads")" -eq 1 ]
[ "$(cat "$TEST_ROOT/enabled")" = "enable quiver_update" ]
[ -x "$TEST_ROOT/userdata/system/services/quiver_update" ]

bash "$TEST_ROOT/installer" > "$TEST_ROOT/output"
[ "$(wc -l < "$TEST_ROOT/enabled")" -eq 1 ]
[ "$(wc -l < "$TEST_ROOT/launcher-downloads")" -eq 1 ]

sed \
    -e "s|^VERSION_FILE=.*|VERSION_FILE=\"$VERSION_FILE\"|" \
    -e "s|^LAUNCHER_UPDATER=.*|LAUNCHER_UPDATER=\"$FAKE_SOURCE/system/Quiver/bin/quiver-update-launcher\"|" \
    -e "s|^LOG=.*|LOG=\"$TEST_ROOT/update.log\"|" \
    "$ROOT/system/services/quiver_update" > "$TEST_ROOT/service-with-launcher"
printf 'next launcher\n' > "$FAKE_APPIMAGE"
next_digest="$(sha256sum "$FAKE_APPIMAGE" | cut -d ' ' -f 1)"
sed -e "s/beta\\.5/beta.6/g" -e "s/$digest/$next_digest/g" \
    -e '/"tag_name":"v4.0.0-beta.6","draft":true/d' \
    "$FAKE_RELEASES" | sed 's/}]},/}]}/' > "$TEST_ROOT/next-releases.json"
cp "$TEST_ROOT/next-releases.json" "$FAKE_RELEASES"
bash "$TEST_ROOT/service-with-launcher" update > "$TEST_ROOT/output"
[ "$(cat "$VERSION_FILE")" = 1.2.0 ]
[ "$(cat "$TEST_ROOT/userdata/system/Quiver/LAUNCHER_VERSION")" = v4.0.0-beta.6 ]
cmp "$FAKE_APPIMAGE" "$TEST_ROOT/userdata/system/Quiver/emulator/QuiverLauncher-linux-x64.AppImage"
grep -q 'Téléchargement de Quiver v4.0.0-beta.6' "$TEST_ROOT/output"
grep -q 'Quiver v4.0.0-beta.6 installé' "$TEST_ROOT/update.log" || {
    tail -n 20 "$TEST_ROOT/update.log" >&2
    exit 1
}

printf 'corrupt download\n' > "$FAKE_APPIMAGE"
printf 'existing launcher\n' > "$TEST_ROOT/userdata/system/Quiver/emulator/QuiverLauncher-linux-x64.AppImage"
if bash "$FAKE_SOURCE/system/Quiver/bin/quiver-update-launcher" > "$TEST_ROOT/output" 2>&1; then
    echo "Invalid AppImage checksum was accepted" >&2
    exit 1
fi
[ "$(cat "$TEST_ROOT/userdata/system/Quiver/emulator/QuiverLauncher-linux-x64.AppImage")" = "existing launcher" ]
[ "$(cat "$TEST_ROOT/userdata/system/Quiver/LAUNCHER_VERSION")" = v4.0.0-beta.6 ]
export FAKE_ASSET_FAIL=1
if bash "$FAKE_SOURCE/system/Quiver/bin/quiver-update-launcher" > "$TEST_ROOT/output" 2>&1; then
    echo "AppImage download failure was not reported" >&2
    exit 1
fi
unset FAKE_ASSET_FAIL
[ "$(cat "$TEST_ROOT/userdata/system/Quiver/emulator/QuiverLauncher-linux-x64.AppImage")" = "existing launcher" ]
export FAKE_API_FAIL=1
if bash "$FAKE_SOURCE/system/Quiver/bin/quiver-update-launcher" > "$TEST_ROOT/output" 2>&1; then
    echo "Release API failure was not reported" >&2
    exit 1
fi
unset FAKE_API_FAIL

echo 1.3.0 > "$FAKE_SOURCE/VERSION"
export FAKE_RSYNC_FAIL=1
if bash "$TEST_ROOT/installer" > "$TEST_ROOT/output" 2>&1; then
    echo "Installation failure was not reported" >&2
    exit 1
fi
[ "$(cat "$VERSION_FILE")" = 1.2.0 ]
echo "Quiver update tests passed"
