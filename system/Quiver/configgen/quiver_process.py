#!/usr/bin/python3
"""Run a Quiver game in its own process group and publish its PID for exit_quiver.sh."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

PID_FILE = Path("/userdata/system/configs/Quiver/active-game.pid")


def _proc_start_time(pid: int) -> str:
    # The command name in /proc/PID/stat may contain spaces and parentheses.
    stat = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    fields_after_comm = stat[stat.rfind(")") + 2 :].split()
    return fields_after_comm[19]  # field 22 (starttime); first is field 3.


def main() -> int:
    if "--" not in sys.argv[1:]:
        print("usage: quiver_process.py -- COMMAND [ARG ...]", file=sys.stderr)
        return 2
    separator = sys.argv.index("--")
    command = sys.argv[separator + 1 :]
    if not command:
        print("quiver_process.py: empty command", file=sys.stderr)
        return 2

    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        PID_FILE.unlink()
    except FileNotFoundError:
        pass
    print(
        f"[Quiver PID] demarrage superviseur_pid={os.getpid()} "
        f"commande_jeu={command!r}",
        file=sys.stderr,
        flush=True,
    )
    process = subprocess.Popen(command, start_new_session=True)
    start_time = ""
    try:
        start_time = _proc_start_time(process.pid)
        temporary = PID_FILE.with_name(f"{PID_FILE.name}.{os.getpid()}.tmp")
        temporary.write_text(f"{process.pid} {start_time}\n", encoding="ascii")
        os.replace(temporary, PID_FILE)
        print(
            f"[Quiver PID] enregistre pid_jeu={process.pid} pgid={process.pid} "
            f"starttime={start_time} fichier={PID_FILE}",
            file=sys.stderr,
            flush=True,
        )
        return_code = process.wait()
        print(
            f"[Quiver PID] fin pid_jeu={process.pid} code={return_code}",
            file=sys.stderr,
            flush=True,
        )
        return return_code
    except BaseException as error:
        print(
            f"[Quiver PID] erreur pid_jeu={process.pid}: {error!r}; "
            "arret du groupe",
            file=sys.stderr,
            flush=True,
        )
        try:
            os.killpg(process.pid, 15)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    finally:
        try:
            if PID_FILE.read_text(encoding="ascii").strip().split() == [
                str(process.pid),
                start_time,
            ]:
                PID_FILE.unlink()
                print(
                    f"[Quiver PID] fichier PID retire pour pid_jeu={process.pid}",
                    file=sys.stderr,
                    flush=True,
                )
            else:
                print(
                    f"[Quiver PID] fichier PID conserve: il ne correspond plus "
                    f"a pid_jeu={process.pid}",
                    file=sys.stderr,
                    flush=True,
                )
        except OSError as error:
            print(
                f"[Quiver PID] nettoyage du fichier PID impossible: {error!r}",
                file=sys.stderr,
                flush=True,
            )


if __name__ == "__main__":
    raise SystemExit(main())
