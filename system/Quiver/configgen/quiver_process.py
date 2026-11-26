#!/usr/bin/python3
"""Run a Quiver game in its own process group and publish its PID for exit_quiver.sh."""
from __future__ import annotations

import os
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
        if fields[0] == "Z":
            return None
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(
            "utf-8", errors="replace"
        ).strip()
        return int(fields[1]), int(fields[2]), fields[19], cmdline
    except (FileNotFoundError, ProcessLookupError, PermissionError, ValueError, OSError):
        return None


def _publish_processes(processes: dict[int, tuple[str, int]]) -> None:
    temporary = PID_FILE.with_name(f"{PID_FILE.name}.{os.getpid()}.tmp")
    contents = "".join(
        f"{pid} {start_time} {pgid}\n"
        for pid, (start_time, pgid) in sorted(processes.items())
    )
    temporary.write_text(contents, encoding="ascii")
    os.replace(temporary, PID_FILE)


def _find_descendants(root_pid: int) -> dict[int, tuple[str, int, str]]:
    """Return live descendants as pid -> (starttime, pgid, command line)."""
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

    return {
        pid: (info[2], info[1], info[3])
        for pid, info in processes.items()
        if pid in descendants
    }


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
        tracked_processes = {process.pid: (start_time, tracked_pgid)}
        _publish_processes(tracked_processes)
        print(
            f"[Quiver PID] enregistre pid_jeu={process.pid} pgid={process.pid} "
            f"starttime={start_time} fichier={PID_FILE}",
            file=sys.stderr,
            flush=True,
        )
        while True:
            descendants = _find_descendants(process.pid)
            process_list_changed = False
            for pid, (child_start, child_pgid, _cmdline) in descendants.items():
                identity = (child_start, child_pgid)
                if tracked_processes.get(pid) != identity:
                    tracked_processes[pid] = identity
                    process_list_changed = True
            if process_list_changed:
                _publish_processes(tracked_processes)

            game_candidates = []
            for pid, (child_start, child_pgid, cmdline) in descendants.items():
                lowered = cmdline.lower()
                if "rpcs3" in lowered or "apprun.wrapped" in lowered:
                    game_candidates.append((int(".iso" in lowered), int("rpcs3" in lowered), pid, child_pgid, child_start))
            if game_candidates:
                _iso, _rpcs3, tracked_pid, tracked_pgid, start_time = max(game_candidates)
            root_running = process.poll() is None
            any_tracked_running = any(
                (info := _proc_info(pid)) is not None and info[2] == child_start
                for pid, (child_start, _child_pgid) in tracked_processes.items()
            )
            if not root_running and not any_tracked_running:
                break
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
            if PID_FILE.read_text(encoding="ascii").strip().splitlines() == [
                f"{pid} {child_start} {child_pgid}"
                for pid, (child_start, child_pgid) in sorted(tracked_processes.items())
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
