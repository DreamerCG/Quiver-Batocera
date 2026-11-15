#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^stop_dragons_crown_pro() {/,/^}/p' "$ROOT/system/Quiver/emulator/exit_quiver.sh")"

pkill() {
    signal=$1
    pattern=$3
    [ "$2" = "-f" ] || return 9
    printf '%s\n' "/tmp/.mount_DragonmfHCOb/usr/bin/dragons_crown_pro --user /userdata/saves/quiver/CUSA10454 - Dragons Crown Pro" | grep -Eq "$pattern" || return 9
    printf '%s\n' "/tmp/.mount_DragonOther/usr/bin/dragons_crown_pro --user /other/save" | grep -Eq "$pattern" && return 9
    printf '%s\n' "/tmp/.mount_DragonOther/usr/bin/dragons_crown_pro_other --user /userdata/saves/quiver/CUSA10454 - Dragons Crown Pro" | grep -Eq "$pattern" && return 9
    case "$signal:$scenario" in
        -TERM:running|-KILL:running) return 0 ;;
    esac
    return 9
}

sleep() { :; }

scenario=running
output=$(stop_dragons_crown_pro)
printf '%s\n' "$output" | grep -q 'Arrêt forcé'
# The TERM succeeded, but the game exited before the KILL.
pkill() {
    case "$1" in
        -TERM) return 0 ;;
        -KILL) return 1 ;;
    esac
}
output=$(stop_dragons_crown_pro)
printf '%s\n' "$output" | grep -q 'Dragons Crown Pro arrêté'
pkill() { return 1; }
output=$(stop_dragons_crown_pro)
printf '%s\n' "$output" | grep -q "n'est pas en cours"
pkill() { return 2; }
output=$(stop_dragons_crown_pro)
printf '%s\n' "$output" | grep -q '\[ERREUR\]'
pkill() {
    case "$1" in
        -TERM) return 0 ;;
        -KILL) return 2 ;;
    esac
}
output=$(stop_dragons_crown_pro)
printf '%s\n' "$output" | grep -q '\[ERREUR\].*arrêt forcé'
