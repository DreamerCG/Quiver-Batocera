from __future__ import annotations

import configparser
import logging
import os
import shlex
import subprocess
import sys
from pathlib import Path

from batocera_common.dataclasses import cached_dataclass, cached_property
from batocera_launch.command import Command
from batocera_launch.emulator import Emulator
from batocera_launch.types import HotkeysContext

_logger = logging.getLogger(__name__)

QUIVER_CONFIG_ROOT = Path("/userdata/system/configs/Quiver")
WINE_PREFIX = "/userdata/system/.wine"


def _read_quiver_file(rom: Path) -> configparser.ConfigParser:
    """Read one .quiver launch definition."""
    parser = configparser.ConfigParser(interpolation=None)

    try:
        with rom.open("r", encoding="utf-8") as file:
            parser.read_file(file)
    except (OSError, configparser.Error) as error:
        raise RuntimeError(
            f"Impossible de lire le fichier Quiver {rom}: {error}"
        ) from error

    return parser


@cached_dataclass
class Quiver(Emulator):

    @cached_property
    def hotkeygen_context(self) -> HotkeysContext:
        return {
            "name": "quiver",
            "keys": {"exit": "KEY_ESC", "coin": "KEY_5"},
        }

    async def configure(self) -> Command:
        rom = Path(self.rom)

        if not rom.is_file():
            raise RuntimeError(f"Fichier .quiver introuvable : {rom}")

        parser = _read_quiver_file(rom)

        # Lecture des paramètres du jeu
        name = parser.get("Game", "name", fallback=rom.stem).strip()
        folder = parser.get("Game", "Folder", fallback=rom.stem).strip()
        game_path = parser.get("Game", "path", fallback="").strip()
        executable_name = parser.get("Game", "executable", fallback="").strip()
        working_directory = parser.get(
            "Game", "working_directory", fallback=""
        ).strip()
        arguments = parser.get("Game", "args", fallback="").strip()
        setting_file = parser.get("Game", "setting_file", fallback="").strip()

        # Le dossier de travail est path par défaut.
        # working_directory permet de le remplacer si nécessaire.
        if not working_directory:
            working_directory = game_path

        if not working_directory:
            raise RuntimeError(
                f"{name} : path absent dans le fichier {rom}"
            )

        workdir = Path(working_directory).expanduser()

        if not workdir.is_dir():
            raise RuntimeError(
                f"{name} : dossier de travail introuvable : {workdir}"
            )

        if not executable_name:
            raise RuntimeError(
                f"{name} : executable absent dans le fichier {rom}"
            )

        executable = Path(executable_name).expanduser()

        if not executable.is_absolute():
            executable = workdir / executable

        executable = executable.resolve()

        if not executable.is_file():
            raise RuntimeError(
                f"{name} : exécutable introuvable : {executable}"
            )

        try:
            app_args = shlex.split(arguments)
            launch_command = parser.get(
                "Launch", "command", fallback="dbus-run-session"
            ).strip()
            launch_parts = (
                shlex.split(launch_command)
                if launch_command
                else ["dbus-run-session"]
            )
        except ValueError as error:
            raise RuntimeError(
                f"{name} : arguments mal formés dans {rom}: {error}"
            ) from error

        if not launch_parts:
            launch_parts = ["dbus-run-session"]

        # Vérifier si le fichier de configuration du launcher existe.
        setting_path = Path(setting_file).expanduser() if setting_file else None
        settings_exists = bool(setting_path and setting_path.is_file())

        print(
            f"[QUIVER DEBUG] setting_file brut = {setting_file!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] chemin absolu testé = "
            f"{str(setting_path.resolve()) if setting_path else '(vide)'!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] fichier présent = "
            f"{setting_path.exists() if setting_path else False}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] fichier régulier = {settings_exists}",
            file=sys.stderr,
            flush=True,
        )

        # Déterminer le mode de lancement.
        launcher_quiver = self.config.get(
            "LAUNCHER_QUIVER", "on"
        ).strip().lower()

        # Sans fichier de configuration, forcer l'ouverture du launcher.
        if not settings_exists:
            launcher_quiver = "on"
            _logger.info(
                "Quiver : fichier de configuration absent (%s), "
                "ouverture du launcher forcée.",
                setting_file or "(non renseigné)",
            )

        # Retirer --play uniquement si le launcher doit s'ouvrir.
        if launcher_quiver in ("on", "1", "true", "yes"):
            app_args = [
                arg for arg in app_args if arg != "--play"
            ]
            _logger.debug("Quiver : mode launcher pour %s", name)
        else:
            _logger.debug("Quiver : lancement direct pour %s", name)

        # Afficher la souris si le launcher est actif
        # ou si le profil est Quiver Launcher.quiver.
        if (
            launcher_quiver in ("on", "1", "true", "yes")
            or rom.name.lower() == "quiver launcher.quiver"
        ):
            subprocess.run(
                ["batocera-mouse", "show"],
                check=False,
            )
            _logger.debug(
                "Quiver : souris affichée pour %s", rom.name
            )

        # Construire la commande en conservant les espaces dans les chemins.
        command = [
            "/bin/sh",
            "-c",
            'cd "$1" || exit 1; shift; exec "$@"',
            "quiver",
            str(workdir),
            *launch_parts,
            "--",
            str(executable),
            *app_args,
        ]

        # Centraliser les configurations Linux (XDG).
        xdg_config_home = QUIVER_CONFIG_ROOT / "config"
        xdg_data_home = QUIVER_CONFIG_ROOT / "data"
        runtime_dir = QUIVER_CONFIG_ROOT / "runtime"

        xdg_config_home.mkdir(parents=True, exist_ok=True)
        xdg_data_home.mkdir(parents=True, exist_ok=True)
        runtime_dir.mkdir(parents=True, exist_ok=True)
        runtime_dir.chmod(0o700)

        # Un HOME distinct pour chaque jeu, basé sur Folder.
        safe_game_name = "".join(
            char if char.isalnum() or char in "-_." else "_"
            for char in folder
        ).strip(".")

        if not safe_game_name:
            safe_game_name = rom.stem

        home_dir = QUIVER_CONFIG_ROOT / "wine" / safe_game_name
        home_dir.mkdir(parents=True, exist_ok=True)

        # Conserver l'environnement Batocera et modifier uniquement
        # les variables nécessaires à Quiver.
        env = os.environ.copy()
        env["HOME"] = str(home_dir)
        env["WINEPREFIX"] = WINE_PREFIX
        env["XDG_CONFIG_HOME"] = str(xdg_config_home)
        env["XDG_DATA_HOME"] = str(xdg_data_home)
        env["XDG_RUNTIME_DIR"] = str(runtime_dir)

        # Traces de diagnostic.
        print(
            f"[QUIVER DEBUG] Jeu={name!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] Folder={folder!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] HOME={env['HOME']!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] WINEPREFIX={env['WINEPREFIX']!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] setting_file={setting_file!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] settings_exists={settings_exists}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] LAUNCHER_QUIVER={launcher_quiver!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] Arguments={app_args!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] Commande={shlex.join(command)}",
            file=sys.stderr,
            flush=True,
        )

        return Command(args=command, env=env)
