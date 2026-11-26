#!/usr/bin/python3
"""Run a Quiver game in its own process group and publish its PID for exit_quiver.sh."""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

PID_FILE = Path("/userdata/system/configs/Quiver/active-game.pid")


def _proc_start_time(pid: int) -> str:
    # The command name in /proc/PID/stat may contain spaces and parentheses.
    stat = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    fields_after_comm = stat[stat.rfind(")") + 2 :].split()
    return fields_after_comm[19]  # field 22 (starttime); first is field 3.


def _proc_info(pid: int) -> tuple[int, int, str, str] | None:
    """Return (ppid, pgid, starttime, command line) for a live process."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
        fields = stat[stat.rfind(")") + 2 :].split()
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(
            "utf-8", errors="replace"
        ).strip()
        return int(fields[1]), int(fields[2]), fields[19], cmdline
    except (FileNotFoundError, ProcessLookupError, PermissionError, ValueError, OSError):
        return None


def _publish_pid(pid: int, start_time: str) -> None:
    temporary = PID_FILE.with_name(f"{PID_FILE.name}.{os.getpid()}.tmp")
    temporary.write_text(f"{pid} {start_time}\n", encoding="ascii")
    os.replace(temporary, PID_FILE)


def _find_game_process(root_pid: int, command: list[str]) -> tuple[int, int, str] | None:
    """Find a recognizable descendant when an AppImage launcher forks away."""
    executable = Path(command[0]).name
    game_args = command[1:]
    processes: dict[int, tuple[int, int, str, str]] = {}
    for entry in Path("/proc").iterdir():
        if entry.name.isdecimal():
            info = _proc_info(int(entry.name))
            if info:
                processes[int(entry.name)] = info

    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _pgid, _start, _cmdline) in processes.items():
            if ppid in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True

    root_info = processes.get(root_pid)
    root_pgid = root_info[1] if root_info else root_pid
    candidates = []
    for pid in descendants:
        info = processes.get(pid)
        if not info:
            continue
        _ppid, pgid, start, cmdline = info
        argv = shlex.split(cmdline) if cmdline else []
        executable_match = any(Path(arg).name == executable for arg in argv)
        if not executable_match:
            continue
        # Prefer the actual application (which retains game arguments) to an
        # AppRun or mount helper, and only publish PIDs in the launch group.
        args_match = all(arg in argv for arg in game_args if not arg.startswith("-"))
        score = (int(args_match), int(pgid == root_pgid), len(argv))
        candidates.append((score, pid, pgid, start))
    if not candidates:
        return None
    _score, pid, pgid, start = max(candidates)
    return pid, pgid, start


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
        tracked_pid, tracked_pgid = process.pid, process.pid
        _publish_pid(tracked_pid, start_time)
        print(
            f"[Quiver PID] enregistre pid_jeu={process.pid} pgid={process.pid} "
            f"starttime={start_time} fichier={PID_FILE}",
            file=sys.stderr,
            flush=True,
        )
        while process.poll() is None:
            candidate = _find_game_process(process.pid, command)
            if candidate:
                candidate_pid, candidate_pgid, candidate_start = candidate
                if candidate_pid != tracked_pid:
                    tracked_pid, tracked_pgid, start_time = (
                        candidate_pid,
                        candidate_pgid,
                        candidate_start,
                    )
                    _publish_pid(tracked_pid, start_time)
                    print(
                        f"[Quiver PID] cible mise a jour pid_jeu={tracked_pid} "
                        f"pgid={tracked_pgid} starttime={start_time}",
                        file=sys.stderr,
                        flush=True,
                    )
            time.sleep(0.25)
        return_code = process.wait()
        print(
            f"[Quiver PID] fin pid_lanceur={process.pid} pid_jeu={tracked_pid} "
            f"code={return_code}",
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
            os.killpg(tracked_pgid if "tracked_pgid" in locals() else process.pid, 15)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    finally:
        try:
            if PID_FILE.read_text(encoding="ascii").strip().split() == [
                str(tracked_pid),
                start_time,
            ]:
                PID_FILE.unlink()
                print(
                    f"[Quiver PID] fichier PID retire pour pid_jeu={tracked_pid}",
                    file=sys.stderr,
                    flush=True,
                )
            else:
                print(
                    f"[Quiver PID] fichier PID conserve: il ne correspond plus "
                    f"a pid_jeu={tracked_pid}",
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
