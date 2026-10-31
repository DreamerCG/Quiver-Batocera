#!/bin/sh

LOG="/userdata/system/Quiver/exit_quiver.log"
LOG_DIR="/userdata/system/Quiver"
PROFILES_DIR="/userdata/system/Quiver/systemprofils"
APPS_DIR="/userdata/system/Quiver/emulator/Apps"
ROM_DIR="/userdata/roms/quiver"

# Vérifier que le dossier des logs existe
if ! mkdir -p "$LOG_DIR"; then
    echo "[ERREUR] Impossible de créer le dossier $LOG_DIR" >&2
    exit 1
fi

# Vérifier que le fichier de log est accessible en écriture
if ! touch "$LOG"; then
    echo "[ERREUR] Impossible d'écrire dans $LOG" >&2
    exit 1
fi

# Rediriger stdout et stderr vers le fichier de log
exec >> "$LOG" 2>&1

echo
echo "=========================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Démarrage exit_quiver.sh"
echo "PID=$$"
echo "PROFILES_DIR=$PROFILES_DIR"
echo "APPS_DIR=$APPS_DIR"
echo "ROM_DIR=$ROM_DIR"
echo "[INFO] Redirection des logs opérationnelle"

batocera-mouse hide
echo "[INFO] Souris masquée"

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

# Lecture d'une clé dans une section précise d'un fichier INI.
# Insensible à la casse pour les sections et les clés.
get_ini_value() {
    file="$1"
    requested_section="$2"
    requested_key="$3"

    awk -v section="$requested_section" -v key="$requested_key" '
    BEGIN {
        section = tolower(section)
        key = tolower(key)
        inside = 0
    }

    {
        line = $0
        sub(/\r$/, "", line)

        # Ignorer les lignes vides et les commentaires
        if (line ~ /^[[:space:]]*[#;]/ || line ~ /^[[:space:]]*$/)
            next

        # Détection des sections
        if (line ~ /^[[:space:]]*\[/) {
            current = line
            sub(/^[[:space:]]*\[/, "", current)
            sub(/\][[:space:]]*$/, "", current)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)

            inside = (tolower(current) == section)
            next
        }

        if (inside) {
            pos = index(line, "=")

            if (pos > 0) {
                current_key = substr(line, 1, pos - 1)
                value = substr(line, pos + 1)

                gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_key)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

                if (tolower(current_key) == key) {
                    print value
                    exit
                }
            }
        }
    }
    ' "$file"
}

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

    # Lecture de Folder dans [Game]
    folder=$(get_ini_value "$profile" "Game" "Folder")

    echo "[INFO] Folder lu : '$folder'"

    if [ -z "$folder" ]; then
        echo "[IGNORÉ] Clé [Game] Folder absente ou vide"
        continue
    fi

    app_path="$APPS_DIR/$folder"
    echo "[INFO] Vérification du dossier : $app_path"

    if [ ! -d "$app_path" ]; then
        echo "[IGNORÉ] Dossier application introuvable"
        echo "[DEBUG] Contenu correspondant éventuel dans Apps :"
        ls -ld "$APPS_DIR"/*PT* 2>&1
        continue
    fi

    echo "[OK] Dossier application trouvé"

    # Lecture des trois répertoires dans [Roms]
    game_directory=$(get_ini_value "$profile" "Roms" "game_directory")
    dlc_directory=$(get_ini_value "$profile" "Roms" "dlc_directory")
    mods_directory=$(get_ini_value "$profile" "Roms" "mods_directory")

    # Création des répertoires si nécessaire
    create_rom_directory() {
        directory="$1"
        description="$2"

        if [ -z "$directory" ]; then
            echo "[INFO] $description : chemin absent, ignoré"
            return 0
        fi

        echo "[INFO] Vérification $description : $directory"

        if mkdir -p "$directory"; then
            echo "[OK] Répertoire disponible : $directory"
        else
            echo "[ERREUR] Impossible de créer : $directory"
            return 1
        fi
    }

    # Les trois chemins sont indépendants.
    directories_ok=1

    create_rom_directory "$game_directory" "GAME" || directories_ok=0
    create_rom_directory "$dlc_directory" "DLC" || directories_ok=0
    create_rom_directory "$mods_directory" "MODS" || directories_ok=0

    if [ "$directories_ok" -ne 1 ]; then
        echo "[ERREUR] Création des répertoires incomplète : profil non copié"
        continue
    fi

    # Copie du profil uniquement si toutes les vérifications sont bonnes.
    if cp -fv "$profile" "$ROM_DIR/"; then
        echo "[OK] Profil copié vers $ROM_DIR/"
    else
        echo "[ERREUR] Échec de la copie de $profile"
    fi
done

# Vérifier les profils déjà présents dans ROM_DIR.
# Supprimer ceux dont le dossier d'application n'existe plus dans APPS_DIR.
echo
echo "[INFO] Vérification des profils .quiver déjà installés dans $ROM_DIR"

for rom_profile in "$ROM_DIR"/*; do
    [ -f "$rom_profile" ] || continue

    # Extension .quiver insensible à la casse.
    case "$rom_profile" in
        *.[Qq][Uu][Ii][Vv][Ee][Rr]) ;;
        *) continue ;;
    esac

    profile_name=${rom_profile##*/}

    # Ne jamais supprimer le profil du launcher Quiver.
    if [ "$profile_name" = "Quiver Launcher.quiver" ]; then
        echo "[IGNORÉ] Profil réservé : $profile_name"
        continue
    fi

    echo "[PROFIL] Vérification : $rom_profile"

    folder=$(get_ini_value "$rom_profile" "Game" "Folder")
    if [ -z "$folder" ]; then
        echo "[IGNORÉ] Clé [Game] Folder absente ou vide : $profile_name"
        continue
    fi

    app_path="$APPS_DIR/$folder"
    if [ ! -d "$app_path" ]; then
        echo "[SUPPRESSION] Application introuvable : $app_path"
        if rm -f "$rom_profile"; then
            echo "[OK] Profil obsolète supprimé : $profile_name"
        else
            echo "[ERREUR] Impossible de supprimer : $rom_profile"
        fi
    else
        echo "[OK] Application présente : $folder"
    fi
done

echo
echo "[INFO] Arrêt des processus run.py de Quiver"

for pid in $(pgrep -f 'python /userdata/system/Quiver/configgen/run.py'); do
    echo "[INFO] Arrêt du PID $pid"
    kill -9 "$pid" 2>/dev/null
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fin du script"
echo "=========================================="
