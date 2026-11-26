#!/bin/sh

LOG="/userdata/system/Quiver/exit_quiver.log"
LOG_DIR="/userdata/system/Quiver"
PROFILES_DIR="/userdata/system/Quiver/systemprofils"
APPS_DIR="/userdata/system/Quiver/emulator/Apps"
INSTALLS_JSON="/userdata/system/configs/Quiver/data/com.quiverlauncher.app/installs.json"
PROFILE_INDEX_JSON="/userdata/system/configs/Quiver/data/com.quiverlauncher.app/profile-index.json"
ROM_DIR="/userdata/roms/quiver"
EXIT_STATE_FILE="/userdata/system/configs/Quiver/exit-state"

# Racines autorisées pour la suppression (une par clé de la section [Roms])
GAME_ROOT="$ROM_DIR/GAME"
DLC_ROOT="$ROM_DIR/DLC"
MODS_ROOT="$ROM_DIR/MODS"
SAVES_ROOT="/userdata/saves/quiver"

# DRY_RUN=1 : journalise ce qui serait supprimé sans rien toucher.
# Passer à 0 (ici ou via l'environnement) pour activer les suppressions réelles.
DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
    0|1) ;;
    *)
        echo "[ERREUR] DRY_RUN doit valoir 0 ou 1 : $DRY_RUN" >&2
        exit 1
        ;;
esac

# Nombre maximal de profils orphelins acceptés par exécution.
# Au-delà, tout le nettoyage est annulé (symptôme probable d'un problème sur Apps).
MAX_DELETIONS="${MAX_DELETIONS:-10}"
case "$MAX_DELETIONS" in
    ""|*[!0-9]*)
        echo "[ERREUR] MAX_DELETIONS doit être un entier positif : $MAX_DELETIONS" >&2
        exit 1
        ;;
esac
if [ "$MAX_DELETIONS" -lt 1 ] || [ "$MAX_DELETIONS" -gt 10 ]; then
    echo "[ERREUR] MAX_DELETIONS doit être compris entre 1 et 10 : $MAX_DELETIONS" >&2
    exit 1
fi

LOCK_DIR="/tmp/exit_quiver.lock"

# Vérifier que le dossier des logs existe
if ! mkdir -p "$LOG_DIR"; then
    echo "[ERREUR] Impossible de créer le dossier $LOG_DIR" >&2
    exit 1
fi

# Éviter de suivre un lien symbolique inattendu pour le fichier de log.
if [ -L "$LOG" ]; then
    echo "[ERREUR] Le fichier de log est un lien symbolique : $LOG" >&2
    exit 1
fi

# Vérifier que le fichier de log est accessible en écriture
# Réinitialiser le log au début de chaque exécution.
if ! log_error=$( ( : > "$LOG" ) 2>&1 ); then
    echo "[ERREUR] Impossible d'écrire dans $LOG${log_error:+ : $log_error}" >&2
    exit 1
fi

# Horodater les messages du script tout en gardant la redirection POSIX.
exec >> "$LOG" 2>&1
echo() {
    [ "$#" -gt 0 ] || return 0
    command printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

echo "[DÉBUT] exit_quiver.sh (PID=$$, DRY_RUN=$DRY_RUN, maximum suppressions=$MAX_DELETIONS)"
copied_profiles=0
new_profiles=0
updated_profiles=0
ignored_profiles=0
orphan_profiles=0
ORPHAN_COUNT=0

# Verrou : éviter deux exécutions simultanées
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ]; then
        echo "[ERREUR] Verrou invalide ou symbolique : $LOCK_DIR"
        exit 1
    fi
    old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "[IGNORÉ] Une autre exécution est en cours (PID $old_pid)"
        exit 0
    fi
    echo "[INFO] Verrou périmé supprimé"
    rm -f "$LOCK_DIR/pid"
    if ! rmdir "$LOCK_DIR" 2>/dev/null; then
        echo "[ERREUR] Impossible de retirer le verrou périmé $LOCK_DIR"
        exit 1
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[ERREUR] Impossible de créer le verrou $LOCK_DIR"
        exit 1
    fi
fi
if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null
    echo "[ERREUR] Impossible d'écrire le verrou $LOCK_DIR"
    exit 1
fi
release_lock() {
    [ -L "$LOCK_DIR" ] && return
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] || return
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null
}
trap release_lock EXIT
trap 'exit 1' INT TERM

EXIT_STATE=""

# Identify the active Quiver Launcher AppImage before its process group is stopped.
ACTIVE_GAME_PID_FILE="/userdata/system/configs/Quiver/active-game.pid"
if [ -f "$ACTIVE_GAME_PID_FILE" ] && [ ! -L "$ACTIVE_GAME_PID_FILE" ]; then
    read -r active_game_pid active_game_start extra < "$ACTIVE_GAME_PID_FILE"
    case "$active_game_pid" in
        ""|*[!0-9]*) ;;
        *)
            active_game_cmdline=$(tr '\000' ' ' < "/proc/$active_game_pid/cmdline" 2>/dev/null)
            case "$active_game_cmdline" in
                *QuiverLauncher-linux-x64.AppImage*) EXIT_STATE="launcher" ;;
            esac
            ;;
    esac
fi

if rm -f -- "$EXIT_STATE_FILE"; then
    echo "[INFO] État de session consommé : ${EXIT_STATE:-inconnu}"
else
    echo "[ERREUR] Impossible de consommer l'état de session : $EXIT_STATE_FILE"
fi

stop_active_quiver_game() {
    pid_file="/userdata/system/configs/Quiver/active-game.pid"
    [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || {
        echo "[INFO] Aucun PID de jeu Quiver enregistre"
        return
    }

    read -r game_pid expected_start_time game_pgid extra < "$pid_file"
    echo "[PID DEBUG] active-game.pid: pid=${game_pid:-vide} starttime=${expected_start_time:-vide} pgid=${game_pgid:-vide} extra=${extra:-vide}"
    case "$game_pid" in
        ""|*[!0-9]*)
            echo "[ANOMALIE] PID Quiver invalide : $pid_file"
            rm -f -- "$pid_file"
            return
            ;;
    esac
    case "$expected_start_time" in
        ""|*[!0-9]*)
            echo "[ANOMALIE] Heure de demarrage Quiver invalide : $pid_file"
            rm -f -- "$pid_file"
            return
            ;;
    esac
    if [ -n "$extra" ]; then
        echo "[ANOMALIE] Contenu PID Quiver invalide : $pid_file"
        rm -f -- "$pid_file"
        return
    fi
    # Backward compatibility with the previous two-field format.
    if [ -z "$game_pgid" ]; then
        game_pgid=$game_pid
        echo "[PID DEBUG] ancien format PID, PGID suppose egal au PID: $game_pgid"
    fi
    case "$game_pgid" in
        ""|*[!0-9]*)
            echo "[ANOMALIE] PGID Quiver invalide : $pid_file"
            rm -f -- "$pid_file"
            return
            ;;
    esac

    proc_stat="/proc/$game_pid/stat"
    if [ ! -r "$proc_stat" ]; then
        echo "[INFO] Le processus Quiver $game_pid est deja arrete"
        rm -f -- "$pid_file"
        return
    fi

    stat_rest=$(sed 's/^.*) //' "$proc_stat")
    set -- $stat_rest
    actual_start_time=${20}
    process_group=$(ps -o pgid= -p "$game_pid" 2>/dev/null | tr -d ' ')
    echo "[PID DEBUG] processus cible avant arret: pid=$game_pid pgid=${process_group:-absent} starttime=$actual_start_time"
    echo "[PID DEBUG] membres du groupe $game_pgid avant arret:"
    ps -eo pid=,ppid=,pgid=,sid=,stat=,args= | awk -v group="$game_pgid" '$3 == group { print "[PID DEBUG] " $0 }'
    if [ "$actual_start_time" != "$expected_start_time" ] \
        || [ "$process_group" != "$game_pgid" ]; then
        echo "[ANOMALIE] PID Quiver reutilise ou groupe inattendu : pid=$game_pid pgid=${process_group:-absent} attendu=$game_pgid"
        rm -f -- "$pid_file"
        return
    fi

    echo "[INFO] Arret du groupe de processus Quiver $game_pgid (PID cible $game_pid)"
    kill -TERM -- "-$game_pgid" 2>/dev/null || true
    attempts=0
    while kill -0 -- "-$game_pgid" 2>/dev/null && [ "$attempts" -lt 5 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done
    if kill -0 -- "-$game_pgid" 2>/dev/null; then
        echo "[PID DEBUG] membres du groupe $game_pgid apres TERM:"
        ps -eo pid=,ppid=,pgid=,sid=,stat=,args= | awk -v group="$game_pgid" '$3 == group { print "[PID DEBUG] " $0 }'
        echo "[INFO] Arret force du groupe Quiver $game_pgid"
        kill -KILL -- "-$game_pgid" 2>/dev/null || true
    fi
    echo "[PID DEBUG] membres du groupe $game_pgid apres arret:"
    ps -eo pid=,ppid=,pgid=,sid=,stat=,args= | awk -v group="$game_pgid" '$3 == group { print "[PID DEBUG] " $0 }'
    rm -f -- "$pid_file"
}

stop_active_quiver_game

batocera-mouse hide
echo "[INFO] Souris masquée"

mkdir -p "$ROM_DIR" || {
    echo "[ERREUR] Impossible de créer $ROM_DIR"
    exit 1
}

ROM_DIR_REAL=$(realpath "$ROM_DIR" 2>/dev/null)
ROM_DIR_SAFE=1
if [ -z "$ROM_DIR_REAL" ] || [ ! -d "$ROM_DIR_REAL" ]; then
    echo "[ANOMALIE] Racine ROM absente ou non résolue : $ROM_DIR"
    ROM_DIR_SAFE=0
elif [ -L "$ROM_DIR" ]; then
    echo "[INFO] Racine ROM symbolique autorisée : $ROM_DIR -> $ROM_DIR_REAL"
elif [ "$ROM_DIR_REAL" != "/userdata/roms/quiver" ]; then
    echo "[ANOMALIE] Racine ROM inattendue : $ROM_DIR -> $ROM_DIR_REAL"
    ROM_DIR_SAFE=0
fi

if [ ! -d "$PROFILES_DIR" ]; then
    echo "[ERREUR] Dossier des profils introuvable : $PROFILES_DIR"
    exit 1
fi

if [ ! -d "$APPS_DIR" ]; then
    echo "[ERREUR] Dossier des applications introuvable : $APPS_DIR"
    exit 1
fi

# Generate profiles for newly installed launchers before copying them to ROM_DIR.
# The generator never overwrites existing profiles.
if [ "$EXIT_STATE" = "launcher" ]; then
    PROFILE_GENERATOR="/userdata/system/Quiver/bin/quiver-generate-profiles"
    if [ -f "$PROFILE_GENERATOR" ] && command -v python3 >/dev/null 2>&1; then
        echo "[INFO] Generating profiles for newly installed launchers"
        if python3 "$PROFILE_GENERATOR"; then
            echo "[INFO] Automatic profile generation completed"
        else
            generator_status=$?
            echo "[ERROR] Profile generator failed (code $generator_status); continuing exit"
        fi
    else
        echo "[WARNING] Profile generator or python3 missing; skipping generation"
    fi

# Resolve installed launcher folders through a persistent Folder -> profile index.
# The index is rebuilt only when an installed folder is not yet represented.
PROFILES_TO_COPY=$(mktemp "/tmp/exit_quiver_profiles.XXXXXX") || PROFILES_TO_COPY=""
if [ -n "$PROFILES_TO_COPY" ] && [ -f "$INSTALLS_JSON" ] && command -v python3 >/dev/null 2>&1; then
    REBUILD_PROFILE_INDEX=0
    if [ ! -f "$PROFILE_INDEX_JSON" ] || [ "$INSTALLS_JSON" -nt "$PROFILE_INDEX_JSON" ]; then
        REBUILD_PROFILE_INDEX=1
    fi
    if ! python3 - "$INSTALLS_JSON" "$PROFILE_INDEX_JSON" "$PROFILES_DIR" "$REBUILD_PROFILE_INDEX" > "$PROFILES_TO_COPY" <<'PY'
import configparser
import json
import os
import sys
import tempfile

installs_path, index_path, profiles_dir, force_rebuild = sys.argv[1:]
try:
    with open(installs_path, encoding="utf-8") as source:
        installs = json.load(source)
    if not isinstance(installs, dict):
        raise ValueError("installs.json root is not an object")
    installed = {
        item.get("folder", "").strip()
        for item in installs.values()
        if isinstance(item, dict) and isinstance(item.get("folder"), str)
    }
    installed = {folder for folder in installed if folder and folder not in (".", "..") and "/" not in folder and "\\" not in folder}
except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
    print(f"[WARNING] installs.json invalide : {error}", file=sys.stderr)
    raise SystemExit(1)

index = {}
indexed_folders = set()
try:
    with open(index_path, encoding="utf-8") as source:
        cached = json.load(source)
    if isinstance(cached, dict) and isinstance(cached.get("profiles"), dict):
        index = cached["profiles"]
        if isinstance(cached.get("indexedFolders"), list):
            indexed_folders = {value for value in cached["indexedFolders"] if isinstance(value, str)}
except (OSError, UnicodeError, json.JSONDecodeError):
    pass

needs_rebuild = force_rebuild == "1" or not installed.issubset(indexed_folders)

# Detect profile renames, removals, and Folder edits even when installs.json
# itself has not changed. The index is keyed by the stable Game.Folder value,
# but its values are profile filenames, which can be renamed independently.
if not needs_rebuild:
    for name in os.listdir(profiles_dir):
        if not name.lower().endswith(".quiver"):
            continue
        path = os.path.join(profiles_dir, name)
        if not os.path.isfile(path):
            continue
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str.lower
        try:
            parser.read(path, encoding="utf-8")
            folder = parser.get("Game", "Folder", fallback="").strip()
        except (configparser.Error, UnicodeError, OSError):
            continue
        if folder in installed and name not in index.get(folder, []):
            needs_rebuild = True
            break
    if not needs_rebuild:
        for index_folder, names in index.items():
            if not isinstance(names, list):
                needs_rebuild = True
                break
            if any(
                not isinstance(name, str)
                or os.path.basename(name) != name
                or not os.path.isfile(os.path.join(profiles_dir, name))
                for name in names
            ):
                needs_rebuild = True
                break
            for name in names:
                parser = configparser.ConfigParser(interpolation=None)
                parser.optionxform = str.lower
                try:
                    parser.read(os.path.join(profiles_dir, name), encoding="utf-8")
                    folder = parser.get("Game", "Folder", fallback="").strip()
                except (configparser.Error, UnicodeError, OSError):
                    needs_rebuild = True
                    break
                if folder != index_folder:
                    needs_rebuild = True
                    break
            if needs_rebuild:
                break

if needs_rebuild:
    rebuilt = {}
    for name in os.listdir(profiles_dir):
        if not name.lower().endswith(".quiver"):
            continue
        path = os.path.join(profiles_dir, name)
        if not os.path.isfile(path):
            continue
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str.lower
        try:
            parser.read(path, encoding="utf-8")
            folder = parser.get("Game", "Folder", fallback="").strip()
        except (configparser.Error, UnicodeError, OSError):
            continue
        if folder and folder not in (".", "..") and "/" not in folder and "\\" not in folder:
            rebuilt.setdefault(folder, []).append(name)
    index = rebuilt
    indexed_folders = installed
    os.makedirs(os.path.dirname(index_path), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".profile-index.", dir=os.path.dirname(index_path), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as destination:
            json.dump({"indexedFolders": sorted(indexed_folders), "profiles": index}, destination, ensure_ascii=False, separators=(",", ":"))
            destination.write("\n")
        os.replace(temporary, index_path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise

for folder in sorted(installed):
    for name in index.get(folder, []):
        if isinstance(name, str) and os.path.basename(name) == name and name.lower().endswith(".quiver"):
            path = os.path.join(profiles_dir, name)
            if os.path.isfile(path):
                print(path)
PY
    then
        echo "[WARNING] Index des profils indisponible : repli sur le scan complet"
        rm -f "$PROFILES_TO_COPY"
        PROFILES_TO_COPY=""
    fi
else
    echo "[WARNING] installs.json, python3 ou fichier temporaire indisponible : scan complet des profils"
    [ -n "$PROFILES_TO_COPY" ] && rm -f "$PROFILES_TO_COPY"
    PROFILES_TO_COPY=""
fi
fi

# ------------------------------------------------------------------
# Fonctions
# ------------------------------------------------------------------

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

# Une valeur Folder valide est un simple nom de dossier.
valid_folder() {
    case "$1" in
        ""|.|..|*/*) return 1 ;;
    esac
    return 0
}

# Retourne 0 si deux chemins sont identiques ou imbriqués (dans un sens ou l'autre).
paths_overlap() {
    po_a="${1%/}"
    po_b="${2%/}"
    [ -n "$po_a" ] && [ -n "$po_b" ] || return 1
    [ "$po_a" = "$po_b" ] && return 0
    case "$po_a/" in "$po_b"/*) return 0 ;; esac
    case "$po_b/" in "$po_a"/*) return 0 ;; esac
    return 1
}

is_mountpoint() {
    mount_path="$1"
    if [ ! -r /proc/self/mountinfo ]; then
        echo "[ANOMALIE] Liste des montages indisponible : suppression refusée"
        return 0
    fi

    awk -v path="$mount_path" '
        function decode_mountpoint(value) {
            gsub(/\\040/, " ", value)
            gsub(/\\011/, "\t", value)
            gsub(/\\012/, "\n", value)
            return value
        }
        {
            mounted = decode_mountpoint($5)
            if (mounted == path || index(mounted, path "/") == 1)
                found = 1
        }
        END { exit !found }
    ' /proc/self/mountinfo
    mount_status=$?
    case "$mount_status" in
        0) return 0 ;;
        1) return 1 ;;
        *)
            echo "[ANOMALIE] Impossible de vérifier les points de montage"
            return 0
            ;;
    esac
}

# Création des répertoires ROM si nécessaire
create_rom_directory() {
    directory="$1"
    description="$2"

    if [ -z "$directory" ]; then
        return 0
    fi

    case "$description" in
        GAME) root_path="$GAME_ROOT" ;;
        DLC) root_path="$DLC_ROOT" ;;
        MODS) root_path="$MODS_ROOT" ;;
        *)
            echo "[ERREUR] Racine inconnue pour $description"
            return 1
            ;;
    esac

    case "$directory" in
        "$root_path"/*) ;;
        *)
            echo "[ANOMALIE] $description : chemin hors de sa racine : $directory"
            return 1
            ;;
    esac
    case "$directory/" in
        */../*|*/./*|*//*)
            echo "[ANOMALIE] $description : chemin non normalisé : $directory"
            return 1
            ;;
    esac
    if [ "$ROM_DIR_SAFE" -ne 1 ] || [ -L "$root_path" ]; then
        echo "[ANOMALIE] $description : racine non sûre : $root_path"
        return 1
    fi
    if ! mkdir -p "$root_path"; then
        echo "[ERREUR] Impossible de créer la racine $description : $root_path"
        return 1
    fi

    root_real=$(realpath "$root_path" 2>/dev/null)
    if [ -z "$root_real" ] || [ "$root_real" != "$ROM_DIR_REAL/${root_path##*/}" ]; then
        echo "[ANOMALIE] $description : racine résolue hors de son emplacement"
        return 1
    fi
    target_real=$(realpath -m "$directory" 2>/dev/null)
    case "$target_real" in
        "$root_real"/*) ;;
        *)
            echo "[ANOMALIE] $description : chemin résolu hors de sa racine : $directory"
            return 1
            ;;
    esac

    if mkdir -p "$directory"; then
        actual_real=$(realpath "$directory" 2>/dev/null)
        case "$actual_real" in
            "$root_real"/*)
                ;;
            *)
                echo "[ANOMALIE] $description : chemin créé hors de sa racine"
                return 1
                ;;
        esac
    else
        echo "[ERREUR] Impossible de créer : $directory"
        return 1
    fi
}

# Crée Apps/<jeu>/game -> GAME/<jeu>, sans écraser de contenu existant.
create_app_symlink() {
    link_name="$1"
    link_root="$2"
    link_root_real="$3"
    target_path="$4"
    link_relative_path="$5"
    [ -n "$link_relative_path" ] || link_relative_path="$link_name"
    case "$link_relative_path" in
        *../*|../*|*/..|*/.|.|*./*|./*|*//*)
            echo "[ANOMALIE] $link_name : chemin de lien invalide : $link_relative_path"
            return 1
            ;;
    esac
    case "$link_relative_path" in
        /*)
            link_path="$link_relative_path"
            ;;
        *)
            link_path="$app_path/$link_relative_path"
            ;;
    esac
    while [ "${#link_path}" -gt 1 ] && [ "${link_path%/}" != "$link_path" ]; do
        link_path=${link_path%/}
    done

    case "$target_path" in
        "$link_root"/*) ;;
        *) echo "[ANOMALIE] $link_name : cible hors de sa racine : $target_path"; return 1 ;;
    esac
    case "$target_path/" in
        */../*|*/./*|*//*) echo "[ANOMALIE] $link_name : cible non normalisee : $target_path"; return 1 ;;
    esac
    if [ -L "$link_root" ]; then
        echo "[ANOMALIE] $link_name : racine non sure : $link_root"
        return 1
    fi
    root_real=$(realpath "$link_root" 2>/dev/null)
    if [ -z "$root_real" ] || { [ -n "$link_root_real" ] && [ "$root_real" != "$link_root_real" ]; }; then
        echo "[ANOMALIE] $link_name : racine resolue hors de son emplacement"
        return 1
    fi
    target_real=$(realpath "$target_path" 2>/dev/null)
    case "$target_real" in
        "$root_real"/*) ;;
        *) echo "[ANOMALIE] $link_name : cible absente ou resolue hors de sa racine : $target_path"; return 1 ;;
    esac
    if [ ! -e "$target_real" ]; then
        echo "[ERREUR] $link_name : cible absente ou invalide : $target_path"
        return 1
    fi

    app_real=$(realpath "$app_path" 2>/dev/null)
    link_parent="$link_path"
    case "$link_path" in */*) link_parent="${link_path%/*}" ;; esac
    link_parent_candidate=$(realpath -m "$link_parent" 2>/dev/null)
    if [ -z "$link_parent_candidate" ]; then
        echo "[ANOMALIE] Dossier parent du lien invalide : $link_parent"
        return 1
    fi
    if [ -z "$app_real" ]; then
        echo "[ANOMALIE] Dossier application invalide : $app_path"
        return 1
    fi
    case "$link_path" in
        "$app_real"|"$app_real"/*)
            ;;
        /*)
            # Les liens absolus sont permis hors de l'application, mais
            # leurs parents existants ne doivent pas rediriger ailleurs.
            link_check="$link_parent"
            while [ "$link_check" != "/" ]; do
                if [ -L "$link_check" ]; then
                    echo "[ANOMALIE] Parent symbolique refuse : $link_check"
                    return 1
                fi
                link_check=${link_check%/*}
                [ -n "$link_check" ] || link_check="/"
            done
            ;;
        *)
            echo "[ANOMALIE] Chemin de lien relatif hors du dossier application : $link_path"
            return 1
            ;;
    esac
    if [ ! -d "$link_parent" ]; then
        echo "[INFO] Création forcée du dossier parent du lien : $link_parent"
    fi
    if [ ! -d "$link_parent" ] && ! mkdir -p -- "$link_parent"; then
        echo "[ERREUR] Impossible de créer le dossier parent : $link_parent"
        return 1
    fi
    link_parent_real=$(realpath "$link_parent" 2>/dev/null)
    if [ -z "$link_parent_real" ] || [ "$link_parent_real" != "$link_parent_candidate" ]; then
        echo "[ANOMALIE] Dossier parent du lien invalide ou redirige : $link_parent"
        return 1
    fi
    if [ -L "$link_path" ]; then
        existing_real=$(realpath "$link_path" 2>/dev/null)
        if [ "$existing_real" = "$target_real" ]; then
            return 0
        fi
        echo "[ERREUR] Lien existant vers une autre cible : $link_path"
        return 1
    fi
    if [ -e "$link_path" ]; then
        if [ "$link_name" = "dlc" ] && [ ! -L "$link_path" ] && [ -d "$link_path" ]; then
            # Certains jeux/launchers déposent un fichier d'information par
            # défaut dans le dossier DLC. Supprimer uniquement le dossier de
            # lien DLC configuré, après les contrôles de chemin ci-dessus.
            if ! rm -rf -- "$link_path"; then
                echo "[ERREUR] Impossible de supprimer le dossier DLC existant : $link_path"
                return 1
            fi
            echo "[INFO] Dossier DLC existant supprimé avant création du lien : $link_path"
        elif [ ! -d "$link_path" ] || ! rmdir "$link_path" 2>/dev/null; then
            echo "[ERREUR] $link_path existe et n'est pas vide; lien non cree"
            return 1
        else
            echo "[INFO] Dossier vide remplace par le lien : $link_path"
        fi
    fi
    if ln -s "$target_real" "$link_path"; then
        echo "[OK] Lien cree : $link_path -> $target_real"
    else
        echo "[ERREUR] Impossible de creer le lien : $link_path"
        return 1
    fi
}

# Valide un chemin avant suppression.
#   $1 libellé  $2 racine autorisée (nominale)  $3 racine autorisée (résolue)  $4 chemin
# Codes de retour : 0 = autorisé (RESOLVED = chemin résolu), 1 = refusé, 2 = déjà absent
resolve_target() {
    rt_label="$1"
    rt_nominal="$2"
    rt_rootreal="$3"
    rt_path="$4"
    RESOLVED=""

    # Retirer les slashs finaux
    while [ ${#rt_path} -gt 1 ] && [ "${rt_path%/}" != "$rt_path" ]; do
        rt_path=${rt_path%/}
    done

    case "$rt_path" in
        /*) ;;
        *)
            echo "[ANOMALIE] $rt_label : chemin non absolu : $rt_path"
            return 1
            ;;
    esac

    case "$rt_path/" in
        */../*|*/./*|*//*)
            echo "[ANOMALIE] $rt_label : chemin avec . / .. / // : $rt_path"
            return 1
            ;;
    esac

    case "$rt_path" in
        "$rt_nominal"/*) ;;
        *)
            echo "[ANOMALIE] $rt_label : hors de la zone autorisée ($rt_nominal) : $rt_path"
            return 1
            ;;
    esac

    # Déjà absent : succès (idempotence)
    if [ ! -e "$rt_path" ] && [ ! -L "$rt_path" ]; then
        echo "[INFO] $rt_label : déjà absent : $rt_path"
        return 2
    fi

    if [ -L "$rt_path" ]; then
        echo "[ANOMALIE] $rt_label : lien symbolique refusé : $rt_path"
        return 1
    fi

    if [ ! -d "$rt_path" ]; then
        echo "[ANOMALIE] $rt_label : n'est pas un dossier : $rt_path"
        return 1
    fi

    if [ -z "$rt_rootreal" ]; then
        echo "[ANOMALIE] $rt_label : racine autorisée introuvable : $rt_nominal"
        return 1
    fi

    rt_real=$(realpath "$rt_path" 2>/dev/null)
    if [ -z "$rt_real" ]; then
        echo "[ANOMALIE] $rt_label : échec de realpath : $rt_path"
        return 1
    fi

    case "$rt_real" in
        "$rt_rootreal"/*) ;;
        *)
            echo "[ANOMALIE] $rt_label : sort de la zone autorisée après résolution : $rt_real"
            return 1
            ;;
    esac

    if is_mountpoint "$rt_real"; then
        echo "[ANOMALIE] $rt_label : point de montage présent ou non vérifiable : $rt_real"
        return 1
    fi

    for rt_prot in $PROTECTED_REAL; do
        if [ "$rt_real" = "$rt_prot" ]; then
            echo "[ANOMALIE] $rt_label : chemin protégé : $rt_real"
            return 1
        fi
        case "$rt_prot/" in
            "$rt_real"/*)
                echo "[ANOMALIE] $rt_label : contient un chemin protégé ($rt_prot) : $rt_real"
                return 1
                ;;
        esac
    done

    RESOLVED="$rt_real"
    return 0
}

# Enveloppe : CHK_REAL = chemin résolu à supprimer (vide si absent ou non renseigné).
# Retourne 1 en cas d'anomalie.
check_one() {
    CHK_REAL=""
    [ -n "$4" ] || return 0
    resolve_target "$1" "$2" "$3" "$4"
    case $? in
        0) CHK_REAL="$RESOLVED"; return 0 ;;
        2) return 0 ;;
        *) return 1 ;;
    esac
}

# Retourne 0 si un AUTRE profil encore valide référence un chemin égal, parent ou enfant.
is_shared() {
    sh_real="$1"
    sh_self_name="$2"

    for sh_other in "$ROM_DIR"/* "$PROFILES_DIR"/*; do
        [ -f "$sh_other" ] || continue
        [ ! -L "$sh_other" ] || continue
        case "$sh_other" in
            *.[Qq][Uu][Ii][Vv][Ee][Rr]) ;;
            *) continue ;;
        esac

        sh_oname=${sh_other##*/}
        [ "$sh_oname" = "$sh_self_name" ] && continue

        for sh_key in game_directory dlc_directory mods_directory; do
            sh_val=$(get_ini_value "$sh_other" "Roms" "$sh_key")
            [ -n "$sh_val" ] || continue
            sh_val=${sh_val%/}

            if paths_overlap "$sh_real" "$sh_val"; then
                echo "[PARTAGÉ] $sh_real est lié à $sh_val (profil : $sh_oname)"
                return 0
            fi

            sh_val_real=$(realpath "$sh_val" 2>/dev/null)
            if [ -n "$sh_val_real" ] && paths_overlap "$sh_real" "$sh_val_real"; then
                echo "[PARTAGÉ] $sh_real est lié à $sh_val_real (profil : $sh_oname)"
                return 0
            fi
        done
    done

    return 1
}

remove_dir() {
    rd_label="$1"
    rd_root="$2"
    rd_rootreal="$3"
    rd_path="$4"

    resolve_target "$rd_label" "$rd_root" "$rd_rootreal" "$rd_path"
    rd_status=$?
    case "$rd_status" in
        0) rd_path="$RESOLVED" ;;
        2)
            echo "[INFO] $rd_label : déjà absent, aucune suppression"
            return 0
            ;;
        *)
            echo "[ANOMALIE] Suppression refusée pour $rd_label : $rd_path"
            return 1
            ;;
    esac

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY-RUN] Suppression simulée : $rd_path"
        return 0
    fi

    echo "[SUPPRESSION] $rd_path"
    if ! rm -rf -- "$rd_path"; then
        echo "[ERREUR] Échec de suppression : $rd_path"
        return 1
    fi

    if [ -e "$rd_path" ] || [ -L "$rd_path" ]; then
        echo "[ERREUR] Le dossier existe encore : $rd_path"
        return 1
    fi

    echo "[OK] Dossier supprimé : $rd_path"
    return 0
}

# Nettoie GAME / DLC / MODS d'un profil orphelin, puis supprime le profil.
# Retourne 0 si tout est nettoyé, 1 si anomalie (le profil est alors conservé).
cleanup_orphan() {
    co_profile="$1"
    co_name=${co_profile##*/}

    echo "[NETTOYAGE] $co_name"

    if [ ! -r "$co_profile" ]; then
        echo "[ANOMALIE] Profil illisible, conservé : $co_name"
        return 1
    fi
    if [ -L "$co_profile" ] || [ ! -f "$co_profile" ]; then
        echo "[ANOMALIE] Profil non régulier ou lien symbolique, conservé : $co_name"
        return 1
    fi

    co_profile_real=$(realpath "$co_profile" 2>/dev/null)
    co_rom_real=$(realpath "$ROM_DIR" 2>/dev/null)
    if [ -z "$co_profile_real" ] || [ "$co_rom_real" != "${co_profile_real%/*}" ]; then
        echo "[ANOMALIE] Profil hors du dossier ROM, conservé : $co_name"
        return 1
    fi

    co_game=$(get_ini_value "$co_profile" "Roms" "game_directory")
    co_dlc=$(get_ini_value "$co_profile" "Roms" "dlc_directory")
    co_mods=$(get_ini_value "$co_profile" "Roms" "mods_directory")

    if [ -z "$co_game" ] && [ -z "$co_dlc" ] && [ -z "$co_mods" ]; then
        echo "[ANOMALIE] Aucun chemin [Roms] renseigné, profil conservé : $co_name"
        return 1
    fi

    # 1) Valider les trois chemins AVANT toute suppression
    check_one "GAME" "$GAME_ROOT" "$GAME_ROOT_REAL" "$co_game" || {
        echo "[ANOMALIE] Profil conservé : $co_name"
        return 1
    }
    co_r_game="$CHK_REAL"

    check_one "DLC" "$DLC_ROOT" "$DLC_ROOT_REAL" "$co_dlc" || {
        echo "[ANOMALIE] Profil conservé : $co_name"
        return 1
    }
    co_r_dlc="$CHK_REAL"

    check_one "MODS" "$MODS_ROOT" "$MODS_ROOT_REAL" "$co_mods" || {
        echo "[ANOMALIE] Profil conservé : $co_name"
        return 1
    }
    co_r_mods="$CHK_REAL"

    # 2) Les trois chemins ne doivent être ni identiques ni imbriqués
    if paths_overlap "$co_r_game" "$co_r_dlc" \
        || paths_overlap "$co_r_game" "$co_r_mods" \
        || paths_overlap "$co_r_dlc" "$co_r_mods"; then
        echo "[ANOMALIE] Chemins GAME/DLC/MODS identiques ou imbriqués, profil conservé : $co_name"
        return 1
    fi

    # 3) Aucun autre profil valide ne doit utiliser ces chemins
    for co_r in "$co_r_game" "$co_r_dlc" "$co_r_mods"; do
        [ -n "$co_r" ] || continue
        if is_shared "$co_r" "$co_name"; then
            echo "[ANOMALIE] Chemin partagé, profil conservé : $co_name"
            return 1
        fi
    done

    # Reconfirmer que le launcher est toujours absent avant de nettoyer les ROMs.
    co_folder=$(get_ini_value "$co_profile" "Game" "Folder")
    if ! valid_folder "$co_folder" || [ -d "$APPS_DIR/$co_folder" ]; then
        echo "[INFO] Application present or folder invalid; cleanup cancelled: $co_name"
        return 1
    fi

    # 4) Suppression des dossiers
    co_fail=0
    for co_r in "$co_r_game" "$co_r_dlc" "$co_r_mods"; do
        [ -n "$co_r" ] || continue
        case "$co_r" in
            "$GAME_ROOT_REAL"/*)
                remove_dir "GAME" "$GAME_ROOT" "$GAME_ROOT_REAL" "$co_r" || co_fail=1
                ;;
            "$DLC_ROOT_REAL"/*)
                remove_dir "DLC" "$DLC_ROOT" "$DLC_ROOT_REAL" "$co_r" || co_fail=1
                ;;
            "$MODS_ROOT_REAL"/*)
                remove_dir "MODS" "$MODS_ROOT" "$MODS_ROOT_REAL" "$co_r" || co_fail=1
                ;;
            *)
                echo "[ANOMALIE] Chemin sans racine reconnue, profil conservé : $co_name"
                return 1
                ;;
        esac
    done

    if [ "$co_fail" -ne 0 ]; then
        echo "[ERREUR] Nettoyage incomplet, profil conservé : $co_name"
        return 1
    fi

    # 5) Suppression du profil uniquement si tout a réussi
    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY-RUN] Profil qui serait supprimé : $co_name"
        return 0
    fi

    if [ -d "$APPS_DIR/$co_folder" ]; then
        echo "[INFO] Application reappeared during cleanup; keeping ROM profile: $co_name"
        return 1
    fi
    if [ -L "$co_profile" ] || [ ! -f "$co_profile" ] \
        || [ "$(realpath "$co_profile" 2>/dev/null)" != "$co_profile_real" ]; then
        echo "[ANOMALIE] Profil modifié pendant le nettoyage, conservé : $co_name"
        return 1
    fi

    if rm -f "$co_profile"; then
        echo "[OK] Profil obsolète supprimé : $co_name"
        return 0
    fi

    echo "[ERREUR] Impossible de supprimer : $co_profile"
    return 1
}

# ------------------------------------------------------------------
# Chemins résolus (calculés une fois)
# ------------------------------------------------------------------

CLEANUP_SAFE="$ROM_DIR_SAFE"

resolve_root() {
    root_label="$1"
    root_path="$2"
    ROOT_REAL=""

    if [ -L "$root_path" ] || [ ! -d "$root_path" ]; then
        echo "[ANOMALIE] Racine $root_label absente ou symbolique : $root_path"
        return 1
    fi

    ROOT_REAL=$(realpath "$root_path" 2>/dev/null)
    if [ -z "$ROOT_REAL" ] || [ "$ROOT_REAL" != "$ROM_DIR_REAL/${root_path##*/}" ]; then
        echo "[ANOMALIE] Racine $root_label résolue hors de son emplacement : $root_path"
        ROOT_REAL=""
        return 1
    fi
}

resolve_root "GAME" "$GAME_ROOT" || true
GAME_ROOT_REAL="$ROOT_REAL"
resolve_root "DLC" "$DLC_ROOT" || true
DLC_ROOT_REAL="$ROOT_REAL"
resolve_root "MODS" "$MODS_ROOT" || true
MODS_ROOT_REAL="$ROOT_REAL"

# Chemins qu'aucune suppression ne doit égaler ni contenir (sans espaces)
PROTECTED_REAL=""
for pr_path in "$ROM_DIR" "$APPS_DIR" "$PROFILES_DIR" "$LOG_DIR" \
    /userdata /userdata/roms /userdata/system; do
    pr_real=$(realpath "$pr_path" 2>/dev/null) || pr_real="$pr_path"
    PROTECTED_REAL="$PROTECTED_REAL $pr_real"
done

# ------------------------------------------------------------------
# Copie des profils valides vers ROM_DIR
# ------------------------------------------------------------------

if [ "$EXIT_STATE" = "launcher" ]; then
if [ -z "$PROFILES_TO_COPY" ]; then
    PROFILES_TO_COPY=$(mktemp "/tmp/exit_quiver_profiles.XXXXXX") || PROFILES_TO_COPY=""
    if [ -n "$PROFILES_TO_COPY" ]; then
        for fallback_profile in "$PROFILES_DIR"/*; do
            [ -f "$fallback_profile" ] || continue
            case "$fallback_profile" in *.quiver|*.QUIVER) printf '%s\n' "$fallback_profile" >> "$PROFILES_TO_COPY" ;; esac
        done
    fi
fi

if [ -z "$PROFILES_TO_COPY" ]; then
    echo "[ERROR] Cannot create temporary profile list; profile transfer skipped"
else
while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    [ -f "$profile" ] || continue

    # Seuls les fichiers .quiver sont copiés
    case "$profile" in
        *.quiver|*.QUIVER) ;;
        *)
            ignored_profiles=$((ignored_profiles + 1))
            continue
            ;;
    esac

    # Lecture de Folder dans [Game]
    folder=$(get_ini_value "$profile" "Game" "Folder")

    if ! valid_folder "$folder"; then
        ignored_profiles=$((ignored_profiles + 1))
        continue
    fi

    app_path="$APPS_DIR/$folder"
    if [ ! -d "$app_path" ]; then
        ignored_profiles=$((ignored_profiles + 1))
        continue
    fi

    # Lecture des trois répertoires dans [Roms]
    game_directory=$(get_ini_value "$profile" "Roms" "game_directory")
    dlc_directory=$(get_ini_value "$profile" "Roms" "dlc_directory")
    mods_directory=$(get_ini_value "$profile" "Roms" "mods_directory")
    saves_directory=$(get_ini_value "$profile" "Roms" "saves_directory")
    game_symlink_target=$(get_ini_value "$profile" "Command" "game_symlink_target")
    dlc_symlink_target=$(get_ini_value "$profile" "Command" "dlc_symlink_target")
    mods_symlink_target=$(get_ini_value "$profile" "Command" "mods_symlink_target")
    saves_symlink_target=$(get_ini_value "$profile" "Command" "saves_symlink_target")
    game_symlink_name=$(get_ini_value "$profile" "Command" "game_symlink_name")
    dlc_symlink_name=$(get_ini_value "$profile" "Command" "dlc_symlink_name")
    mods_symlink_name=$(get_ini_value "$profile" "Command" "mods_symlink_name")
    saves_symlink_name=$(get_ini_value "$profile" "Command" "saves_symlink_name")

    # Les trois chemins sont indépendants.
    directories_ok=1

    if [ -n "$game_symlink_target" ]; then
        case "$game_symlink_target" in
            game_directory)
                create_rom_directory "$game_directory" "GAME" || directories_ok=0
                create_app_symlink "game" "$GAME_ROOT" "$GAME_ROOT_REAL" "$game_directory" "$game_symlink_name" || directories_ok=0
                ;;
            *)
                echo "[ANOMALIE] Cible de symlink non prise en charge : $game_symlink_target"
                directories_ok=0
                ;;
        esac
    else
        create_rom_directory "$game_directory" "GAME" || directories_ok=0
    fi
    if [ -n "$dlc_symlink_target" ]; then
        case "$dlc_symlink_target" in
            dlc_directory) create_rom_directory "$dlc_directory" "DLC" || directories_ok=0; create_app_symlink "dlc" "$DLC_ROOT" "$DLC_ROOT_REAL" "$dlc_directory" "$dlc_symlink_name" || directories_ok=0 ;;
            *) echo "[ANOMALIE] Cible de symlink DLC non prise en charge : $dlc_symlink_target"; directories_ok=0 ;;
        esac
    else
        create_rom_directory "$dlc_directory" "DLC" || directories_ok=0
    fi
    if [ -n "$mods_symlink_target" ]; then
        case "$mods_symlink_target" in
            mods_directory) create_rom_directory "$mods_directory" "MODS" || directories_ok=0; create_app_symlink "mods" "$MODS_ROOT" "$MODS_ROOT_REAL" "$mods_directory" "$mods_symlink_name" || directories_ok=0 ;;
            *) echo "[ANOMALIE] Cible de symlink MODS non prise en charge : $mods_symlink_target"; directories_ok=0 ;;
        esac
    else
        create_rom_directory "$mods_directory" "MODS" || directories_ok=0
    fi
    if [ -n "$saves_symlink_target" ]; then
        case "$saves_symlink_target" in
            saves_directory)
                case "$saves_directory" in "$SAVES_ROOT"/*) ;; *) echo "[ANOMALIE] SAVES : chemin hors de sa racine : $saves_directory"; directories_ok=0 ;; esac
                case "$saves_directory/" in */../*|*/./*|*//*) echo "[ANOMALIE] SAVES : chemin non normalise : $saves_directory"; directories_ok=0 ;; esac
                if [ "$directories_ok" -eq 1 ]; then
                    if [ -L "$SAVES_ROOT" ]; then echo "[ANOMALIE] SAVES : racine symbolique non sure"; directories_ok=0; fi
                    if [ "$directories_ok" -eq 1 ]; then mkdir -p "$SAVES_ROOT" "$saves_directory" || directories_ok=0; fi
                    saves_root_real=$(realpath "$SAVES_ROOT" 2>/dev/null)
                    saves_target_real=$(realpath "$saves_directory" 2>/dev/null)
                    case "$saves_target_real" in "$saves_root_real"/*) ;; *) echo "[ANOMALIE] SAVES : cible hors de sa racine"; directories_ok=0 ;; esac
                    if [ "$directories_ok" -eq 1 ]; then create_app_symlink "saves" "$SAVES_ROOT" "$saves_root_real" "$saves_directory" "$saves_symlink_name" || directories_ok=0; fi
                fi
                ;;
            *) echo "[ANOMALIE] Cible de symlink SAVES non prise en charge : $saves_symlink_target"; directories_ok=0 ;;
        esac
    fi

    # Liens personnalises : chaque cle linkN_source doit avoir la cle
    # linkN_destination correspondante dans [Symlink].
    custom_symlink_keys=$(mktemp "/tmp/exit_quiver_symlinks.XXXXXX") || custom_symlink_keys=""
    if [ -z "$custom_symlink_keys" ]; then
        echo "[ERREUR] Impossible de creer la liste des symlinks personnalises"
        directories_ok=0
    else
        awk '
            BEGIN { inside = 0 }
            {
                line = $0
                sub(/\r$/, "", line)
                if (line ~ /^[[:space:]]*[#;]/ || line ~ /^[[:space:]]*$/) next
                if (line ~ /^[[:space:]]*\[/) {
                    section = line
                    sub(/^[[:space:]]*\[/, "", section)
                    sub(/\][[:space:]]*$/, "", section)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
                    inside = (tolower(section) == "symlink")
                    next
                }
                if (inside && index(line, "=")) {
                    key = line
                    sub(/=.*/, "", key)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                    key = tolower(key)
                    if (key ~ /^link[[:alnum:]_]*_source$/) print key
                }
            }
        ' "$profile" > "$custom_symlink_keys"

        while IFS= read -r custom_key; do
            [ -n "$custom_key" ] || continue
            custom_id=${custom_key%_source}
            custom_source=$(get_ini_value "$profile" "Symlink" "$custom_key")
            custom_destination=$(get_ini_value "$profile" "Symlink" "${custom_id}_destination")
            custom_source=$(printf '%s' "$custom_source" | sed 's#\\#/#g')
            custom_destination=$(printf '%s' "$custom_destination" | sed 's#\\#/#g')
            while [ "$custom_source" != "/" ] && [ "${custom_source%/}" != "$custom_source" ]; do
                custom_source=${custom_source%/}
            done
            while [ "$custom_destination" != "/" ] && [ "${custom_destination%/}" != "$custom_destination" ]; do
                custom_destination=${custom_destination%/}
            done
            if [ -z "$custom_source" ] || [ -z "$custom_destination" ]; then
                echo "[ANOMALIE] [Symlink] $custom_id doit definir source et destination"
                directories_ok=0
                continue
            fi
            case "$custom_source" in
                /*) ;;
                *) echo "[ANOMALIE] [Symlink] source doit etre un chemin absolu : $custom_source"; directories_ok=0; continue ;;
            esac
            case "$custom_source/" in */../*|*/./*|*//*) echo "[ANOMALIE] [Symlink] source non normalisee : $custom_source"; directories_ok=0; continue ;; esac
            if [ -L "$custom_source" ]; then
                echo "[ANOMALIE] [Symlink] source symbolique refusee : $custom_source"
                directories_ok=0
                continue
            fi
            if [ ! -e "$custom_source" ]; then
                echo "[INFO] Creation du dossier source [Symlink] : $custom_source"
                if ! mkdir -p -- "$custom_source"; then
                    echo "[ERREUR] Impossible de creer le dossier source [Symlink] : $custom_source"
                    directories_ok=0
                    continue
                fi
            fi
            if [ ! -d "$custom_source" ]; then
                echo "[ANOMALIE] [Symlink] source non repertoire : $custom_source"
                directories_ok=0
                continue
            fi
            custom_source_parent=${custom_source%/*}
            [ -n "$custom_source_parent" ] || custom_source_parent="/"
            create_app_symlink "$custom_id" "$custom_source_parent" "" "$custom_source" "$custom_destination" || directories_ok=0
        done < "$custom_symlink_keys"
        rm -f -- "$custom_symlink_keys"
    fi

    if [ "$directories_ok" -ne 1 ]; then
        echo "[ERREUR] Création des répertoires incomplète : profil non copié"
        continue
    fi

    # Distinguer les nouveaux profils des profils déjà présents dans ROM_DIR.
    destination="$ROM_DIR/${profile##*/}"
    if [ -L "$destination" ]; then
        echo "[ANOMALIE] Profil destination symbolique, copie refusée : $destination"
        continue
    fi
    if [ -e "$destination" ]; then
        profile_was_present=1
    else
        profile_was_present=0
    fi

    # Copie du profil uniquement si toutes les vérifications sont bonnes.
    if cp -f "$profile" "$ROM_DIR/"; then
        copied_profiles=$((copied_profiles + 1))
        if [ "$profile_was_present" -eq 1 ]; then
            updated_profiles=$((updated_profiles + 1))
            echo "[PROFIL EXISTANT ACTUALISÉ] ${profile##*/}"
        else
            new_profiles=$((new_profiles + 1))
            echo "[NOUVEAU PROFIL] ${profile##*/}"
        fi
    else
        echo "[ERREUR] Échec de la copie de $profile"
    fi
done < "$PROFILES_TO_COPY"
rm -f "$PROFILES_TO_COPY"
fi

# ------------------------------------------------------------------
# Nettoyage des profils orphelins (application absente de APPS_DIR)
# ------------------------------------------------------------------

echo "[INFO] Vérification des profils installés dans $ROM_DIR"

# Garde-fou : un dossier Apps sans aucune application est suspect
# (montage absent, erreur...) : on ne supprime rien.
apps_count=0
for app_dir in "$APPS_DIR"/*/; do
    [ -d "$app_dir" ] && apps_count=$((apps_count + 1))
done

if [ "$CLEANUP_SAFE" -ne 1 ]; then
    echo "[ERREUR] Racines non vérifiables : nettoyage des profils annulé"
elif [ "$apps_count" -eq 0 ]; then
    echo "[ERREUR] $APPS_DIR ne contient aucune application : nettoyage annulé"
else
    ORPHANS=""
    ORPHAN_COUNT=0

    # Première passe : repérer les orphelins
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
        if [ -L "$rom_profile" ]; then
            echo "[IGNORÉ] Profil ROM symbolique : $profile_name"
            continue
        fi

        folder=$(get_ini_value "$rom_profile" "Game" "Folder")
        if ! valid_folder "$folder"; then
            continue
        fi

        if [ ! -d "$APPS_DIR/$folder" ]; then
            ORPHANS="${ORPHANS}${rom_profile}
"
            ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
        fi
    done

    if [ "$ORPHAN_COUNT" -gt "$MAX_DELETIONS" ]; then
        echo "[ERREUR] $ORPHAN_COUNT profils orphelins (maximum $MAX_DELETIONS) : nettoyage annulé"
    elif [ "$ORPHAN_COUNT" -gt 0 ]; then
        echo "[INFO] $ORPHAN_COUNT profil(s) orphelin(s) à nettoyer"

        # Seconde passe : nettoyage (tous les chemins sont validés avant suppression)
        while IFS= read -r orphan; do
            [ -n "$orphan" ] || continue
            cleanup_orphan "$orphan"
        done <<EOF
$ORPHANS
EOF
    else
        echo "[INFO] Aucun profil orphelin"
    fi
fi

fi

echo "[INFO] Arrêt des processus run.py de Quiver"

for pid in $(pgrep -f 'python /userdata/system/Quiver/configgen/run.py'); do
echo "[INFO] Arrêt du PID $pid"
    kill -9 "$pid" 2>/dev/null
done

if [ "$EXIT_STATE" = "launcher" ]; then
    if curl -fsS --max-time 5 -X POST \
        http://127.0.0.1:1234/notify \
        -d '[Quiver] Merci de rafraichir la liste apres avoir installé un nouveau launcher'; then
        echo "[INFO] Notification de rafraîchissement envoyée"
    else
        echo "[ERREUR] Impossible d'envoyer la notification de rafraîchissement"
    fi
fi

orphan_profiles=$ORPHAN_COUNT
echo "[RÉSUMÉ] nouveaux=$new_profiles, existants actualisés=$updated_profiles, ignorés=$ignored_profiles, orphelins=$orphan_profiles"
echo "[FIN] exit_quiver.sh"
