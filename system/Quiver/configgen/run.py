#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""Point d'entrée du pack DCG QUIVER Launcher appelé par EmulationStation.

Avec Configgen (Batocera V42/V43 et V44 avant sa suppression), DCG QUIVERlauncher
utilise l'ancienne intégration. Sans Configgen, on lance directement
batocera-launch.
"""
import importlib.util
from importlib.metadata import entry_points
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

    system = _argument_value("-system")
    emulator = _argument_value("-emulator")
    core = _argument_value("-core")

    matching_emulators = sorted(
        f"{entry_point.name}={entry_point.value}"
        for entry_point in entry_points(group="batocera_launch.emulators")
        if entry_point.name == emulator
    )
    print(f"[DCG QUIVER LAUNCHER] batocera-launch argv: {sys.argv[1:]!r}", file=sys.stderr)
    print(
        f"[DCG QUIVER LAUNCHER] system={system!r}, emulator argument={emulator!r}",
        file=sys.stderr,
    )
    print(
        f"[DCG QUIVER LAUNCHER] matching emulator plugins: {matching_emulators!r}",
        file=sys.stderr,
    )

    from batocera_launch.config import config as config_mod, defaults

    original = defaults.load_system_defaults

    def complete_defaults(system_name: str, result: dict) -> dict:
        if not result.get("emulator") and emulator:
            result["emulator"] = emulator
        if not result.get("core") and core:
            result["core"] = core
        print(
            f"[DCG QUIVER LAUNCHER] resolved defaults for {system_name!r}: "
            f"emulator={result.get('emulator')!r}, core={result.get('core')!r}",
            file=sys.stderr,
        )
        return result

    def load_system_defaults(system_name: str, /):
        if system_name != "windows-arcade-launcher":
            return complete_defaults(system_name, original(system_name) or {})
        data = defaults.load_defaults(
            system_name,
            defaults.LAUNCH_DEFAULTS_DIR / "config.yml",
            defaults.LAUNCH_DEFAULTS_DIR / "config-arch.yml",
        ) or {}
        result = {"emulator": data.get("emulator"), "core": data.get("core")}
        result.update(data.get("options") or {})
        return complete_defaults(system_name, result)

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
    sys.argv[0] = str(CONFIGGEN_DIR / "DCG QUIVERlauncher")
    runpy.run_path(sys.argv[0], run_name="__main__")


if __name__ == "__main__":
    if _has_configgen():
        print('[DCG QUIVER LAUNCHER] Lancement avec Configgen via DCG QUIVERlauncher', file=sys.stderr)
        run_configgen()
    else:
        print('[DCG QUIVER LAUNCHER] Lancement direct via Batocera Launch', file=sys.stderr)
        run_batocera_launch()
