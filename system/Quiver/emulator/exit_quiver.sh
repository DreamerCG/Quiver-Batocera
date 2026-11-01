#!/bin/sh

LOG="/userdata/system/Quiver/exit_quiver.log"
LOG_DIR="/userdata/system/Quiver"
PROFILES_DIR="/userdata/system/Quiver/systemprofils"
APPS_DIR="/userdata/system/Quiver/emulator/Apps"
ROM_DIR="/userdata/roms/quiver"

# Racines autorisées pour la suppression (une par clé de la section [Roms])
GAME_ROOT="$ROM_DIR/GAME"
DLC_ROOT="$ROM_DIR/DLC"
MODS_ROOT="$ROM_DIR/MODS"

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
echo "DRY_RUN=$DRY_RUN"
echo "MAX_DELETIONS=$MAX_DELETIONS"
echo "[INFO] Redirection des logs opérationnelle"

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

batocera-mouse hide
echo "[INFO] Souris masquée"

mkdir -p "$ROM_DIR" || {
    echo "[ERREUR] Impossible de créer $ROM_DIR"
    exit 1
}

ROM_DIR_REAL=$(realpath "$ROM_DIR" 2>/dev/null)
ROM_DIR_SAFE=1
if [ -L "$ROM_DIR" ] || [ "$ROM_DIR_REAL" != "/userdata/roms/quiver" ]; then
    echo "[ANOMALIE] Racine ROM inattendue ou symbolique : $ROM_DIR"
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
        echo "[INFO] $description : chemin absent, ignoré"
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

    echo "[INFO] Vérification $description : $directory"

    if mkdir -p "$directory"; then
        actual_real=$(realpath "$directory" 2>/dev/null)
        case "$actual_real" in
            "$root_real"/*)
                echo "[OK] Répertoire disponible : $directory"
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

    if [ -e "$PROFILES_DIR/$co_name" ] || [ -L "$PROFILES_DIR/$co_name" ]; then
        echo "[ANOMALIE] Profil système apparu pendant le nettoyage, conservé : $co_name"
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

    if ! valid_folder "$folder"; then
        echo "[IGNORÉ] Clé [Game] Folder absente, vide ou invalide"
        continue
    fi

    app_path="$APPS_DIR/$folder"
    echo "[INFO] Vérification du dossier : $app_path"

    if [ ! -d "$app_path" ]; then
        echo "[IGNORÉ] Dossier application introuvable"
        continue
    fi

    echo "[OK] Dossier application trouvé"

    # Lecture des trois répertoires dans [Roms]
    game_directory=$(get_ini_value "$profile" "Roms" "game_directory")
    dlc_directory=$(get_ini_value "$profile" "Roms" "dlc_directory")
    mods_directory=$(get_ini_value "$profile" "Roms" "mods_directory")

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

# ------------------------------------------------------------------
# Nettoyage des profils orphelins (application absente de APPS_DIR)
# ------------------------------------------------------------------

echo
echo "[INFO] Vérification des profils .quiver déjà installés dans $ROM_DIR"

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
        if [ -e "$PROFILES_DIR/$profile_name" ] \
            || [ -L "$PROFILES_DIR/$profile_name" ]; then
            echo "[IGNORÉ] Profil système conservé : $profile_name"
            continue
        fi

        if [ -L "$rom_profile" ]; then
            echo "[IGNORÉ] Profil ROM symbolique : $profile_name"
            continue
        fi

        echo "[PROFIL] Vérification : $rom_profile"

        folder=$(get_ini_value "$rom_profile" "Game" "Folder")
        if ! valid_folder "$folder"; then
            echo "[IGNORÉ] Clé [Game] Folder absente, vide ou invalide : $profile_name"
            continue
        fi

        if [ -d "$APPS_DIR/$folder" ]; then
            echo "[OK] Application présente : $folder"
        else
            echo "[ORPHELIN] Application introuvable : $APPS_DIR/$folder"
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

echo
echo "[INFO] Arrêt des processus run.py de Quiver"

for pid in $(pgrep -f 'python /userdata/system/Quiver/configgen/run.py'); do
    echo "[INFO] Arrêt du PID $pid"
    kill -9 "$pid" 2>/dev/null
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fin du script"
echo "=========================================="
