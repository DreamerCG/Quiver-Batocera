#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""Point d'entrée du pack DCG QUIVER Launcher appelé par EmulationStation.

Avec Configgen (Batocera V42/V43 et V44 avant sa suppression), DCG QUIVERlauncher
utilise l'ancienne intégration. Sans Configgen, on lance directement
batocera-launch.
"""
import importlib.util
import runpy
import sys
from pathlib import Path

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
CONFIGGEN_DIR = HERE.parent / "configgen"

def _has_configgen() -> bool:
    try:
        return importlib.util.find_spec("configgen") is not None
    except (ImportError, ValueError):
        return False


def run_batocera_launch() -> None:
    sys.path.insert(0, str(HERE))

    emulator = _argument_value("-emulator")
    core = _argument_value("-core")

    from batocera_launch.config import config as config_mod, defaults

    original = defaults.load_system_defaults

    def complete_defaults(system_name: str, result: dict) -> dict:
        if not result.get("emulator") and emulator:
            result["emulator"] = emulator
        if not result.get("core") and core:
            result["core"] = core
        return result

    def load_system_defaults(system_name: str, /):
        return complete_defaults(system_name, original(system_name) or {})

    defaults.load_system_defaults = load_system_defaults
    config_mod.load_system_defaults = load_system_defaults

    from batocera_launch.cli.main import main
    main()


def _argument_value(name: str) -> str | None:
    try:
        return sys.argv[sys.argv.index(name) + 1]
    except (ValueError, IndexError):
        return None


def run_configgen() -> None:
    sys.path.insert(0, str(CONFIGGEN_DIR))
    sys.argv[0] = str(CONFIGGEN_DIR / "dcglauncher")
    runpy.run_path(sys.argv[0], run_name="__main__")


if __name__ == "__main__":
    system = _argument_value("-system") or "inconnu"
    emulator = _argument_value("-emulator") or "inconnu"

    if _has_configgen():
        print(
            f"[DCG QUIVER LAUNCHER] run=Configgen system={system} "
            f"emulator={emulator}",
            file=sys.stderr,
        )
        run_configgen()
    else:
        print(
            f"[DCG QUIVER LAUNCHER] run=batocera-launch system={system} "
            f"emulator={emulator}",
            file=sys.stderr,
        )
        run_batocera_launch()
