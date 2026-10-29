#!/bin/sh

LOG="/userdata/system/Quiver/exit_quiver.log"
PROFILES_DIR="/userdata/system/Quiver/systemprofils"
APPS_DIR="/userdata/system/Quiver/emulator/Apps"
ROM_DIR="/userdata/roms/Quiver"

# Rediriger les logs vers le fichier et la console
exec >> "$LOG" 2>&1

echo "=========================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Démarrage exit_quiver.sh"
echo "PROFILES_DIR=$PROFILES_DIR"
echo "APPS_DIR=$APPS_DIR"
echo "ROM_DIR=$ROM_DIR"

batocera-mouse hide
echo "[INFO] Souris masquée"

mkdir -p "$ROM_DIR" || {
    echo "[ERREUR] Impossible de créer $ROM_DIR"
    exit 1
}

if [ ! -d "$PROFILES_DIR" ]; then
    echo "[ERREUR] Dossier des profils introuvable : $PROFILES_DIR"
    exit 1
fi

if [ ! -d "$APPS_DIR" ]; then
    echo "[ERREUR] Dossier des applications introuvable : $APPS_DIR"
    exit 1
fi

# Parcourir les profils
for profile in "$PROFILES_DIR"/*; do
    [ -f "$profile" ] || continue

    echo
    echo "[PROFIL] Analyse : $profile"

    # Seuls les fichiers .quiver sont copiés
    case "$profile" in
        *.quiver|*.QUIVER) ;;
        *)
            echo "[IGNORÉ] Extension différente de .quiver"
            continue
            ;;
    esac

    # Lire Folder sans tenir compte des majuscules/minuscules
    folder=$(sed -n \
        's/^[[:space:]]*[Ff][Oo][Ll][Dd][Ee][Rr][[:space:]]*=[[:space:]]*//p' \
        "$profile" | head -n 1)

    # Retirer les espaces en début et fin
    folder=$(printf '%s' "$folder" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "[INFO] Folder lu : '$folder'"

    if [ -z "$folder" ]; then
        echo "[IGNORÉ] Clé Folder absente ou vide"
        continue
    fi

    app_path="$APPS_DIR/$folder"
    echo "[INFO] Vérification du dossier : $app_path"

    if [ -d "$app_path" ]; then
        echo "[OK] Dossier application trouvé"

        if cp -fv "$profile" "$ROM_DIR/"; then
            echo "[OK] Profil copié vers $ROM_DIR/"
        else
            echo "[ERREUR] Échec de la copie de $profile"
        fi
    else
        echo "[IGNORÉ] Dossier application introuvable"
        echo "[DEBUG] Contenu correspondant éventuel dans Apps :"
        ls -ld "$APPS_DIR"/*PT* 2>&1
    fi
done

echo "[INFO] Arrêt des processus run.py de Quiver"

for pid in $(pgrep -f 'python /userdata/system/Quiver/configgen/run.py'); do
    echo "[INFO] Arrêt du PID $pid"
    kill -9 "$pid" 2>/dev/null
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fin du script"