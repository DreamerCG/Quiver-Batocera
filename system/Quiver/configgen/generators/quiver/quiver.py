from __future__ import annotations

import configparser
import logging
import os
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

from configgen import Command
from configgen.controller import generate_sdl_game_controller_config
from configgen.generators.Generator import Generator

if TYPE_CHECKING:
    from configgen.types import HotkeysContext

_logger = logging.getLogger(__name__)

QUIVER_CONFIG_ROOT = Path("/userdata/system/configs/Quiver")
QUIVER_PRELOAD_ROOT = Path("/userdata/system/Quiver/preload")
QUIVER_WINE = Path("/userdata/system/Quiver/bin/quiver-wine")


def _read_quiver_file(rom: Path) -> configparser.ConfigParser:
    parser = configparser.ConfigParser(interpolation=None)

    try:
        with rom.open("r", encoding="utf-8") as file:
            parser.read_file(file)
    except (OSError, configparser.Error) as error:
        raise RuntimeError(
            f"Impossible de lire le fichier Quiver {rom}: {error}"
        ) from error

    return parser


def _is_enabled(value: str) -> bool:
    return value.strip().lower() in ("on", "1", "true", "yes")


def _safe_name(value: str) -> str:
    result = "".join(
        char if char.isalnum() or char in "-_." else "_"
        for char in value
    ).strip(".")

    return result or "game"


def _resolve_executable(value: str, workdir: Path) -> Path:
    executable = Path(value).expanduser()

    if not executable.is_absolute():
        executable = workdir / executable

    executable = executable.resolve()
    if executable.is_file():
        return executable

    if executable.suffix.lower() == ".appimage":
        candidates = sorted(
            path.resolve()
            for path in executable.parent.glob("*")
            if path.is_file() and path.suffix.lower() == ".appimage"
        )

        if len(candidates) == 1:
            _logger.info(
                "AppImage introuvable (%s), utilisation de la version disponible : %s",
                executable.name,
                candidates[0].name,
            )
            return candidates[0]

        if len(candidates) > 1:
            prefix = executable.name.split("-v", 1)[0].casefold()
            matching = [
                path for path in candidates
                if path.name.casefold().startswith(prefix)
            ]

            if len(matching) == 1:
                _logger.info(
                    "AppImage introuvable (%s), utilisation de : %s",
                    executable.name,
                    matching[0].name,
                )
                return matching[0]

    return executable


class QuiverGenerator(Generator):

    def getHotkeysContext(self) -> HotkeysContext:
        return {
            "name": "quiver",
            "keys": {
                "exit": "KEY_ESC",
                "coin": "KEY_5",
            },
        }

    def generate(
        self,
        system,
        rom,
        playersControllers,
        metadata,
        guns,
        wheels,
        gameResolution,
    ):
        rom = Path(rom)
        if not rom.is_file():
            raise RuntimeError(f"Fichier .quiver introuvable : {rom}")

        parser = _read_quiver_file(rom)
        name = parser.get("Game", "name", fallback=rom.stem).strip()
        folder = parser.get("Game", "Folder", fallback=rom.stem).strip()

        game_path = parser.get(
            "Launcher",
            "path",
            fallback=parser.get("Game", "path", fallback=""),
        ).strip()
        executable_name = parser.get(
            "Launcher",
            "executable",
            fallback=parser.get("Game", "executable", fallback=""),
        ).strip()
        working_directory = parser.get(
            "Launcher",
            "working_directory",
            fallback=parser.get("Game", "working_directory", fallback=""),
        ).strip()
        if not working_directory:
            working_directory = game_path

        arguments = parser.get(
            "Launcher",
            "args",
            fallback=parser.get("Game", "args", fallback=""),
        ).strip()
        setting_file = parser.get(
            "Config",
            "setting_file",
            fallback=parser.get("Game", "setting_file", fallback=""),
        ).strip()
        preload_file = parser.get(
            "Config",
            "preload_file",
            fallback=parser.get("Game", "preload_file", fallback=""),
        ).strip()
        mode = parser.get("Game", "mode", fallback="auto").strip().lower()
        runner = parser.get("Game", "runner", fallback="").strip()

        feature_runner = system.config.get("wine-runner", "").strip()
        if (
            not runner
            and feature_runner.lower() not in ("auto", "default", "none")
        ):
            runner = feature_runner

        launch_command = parser.get(
            "Launcher",
            "command",
            fallback=parser.get("Launch", "command", fallback=""),
        ).strip()

        try:
            app_args = shlex.split(arguments)
            launch_parts = shlex.split(launch_command) if launch_command else []
        except ValueError as error:
            raise RuntimeError(
                f"{name} : arguments mal formés dans {rom}: {error}"
            ) from error

        if not executable_name and launch_parts:
            executable_name = launch_parts.pop(0)
            app_args = [*launch_parts, *app_args]

        if not working_directory:
            working_directory = game_path or str(rom.parent)
        workdir = Path(working_directory).expanduser().resolve()
        if not workdir.is_dir():
            raise RuntimeError(
                f"{name} : dossier de travail introuvable : {workdir}"
            )

        if not executable_name:
            raise RuntimeError(
                f"{name} : le paramètre executable est absent dans {rom}"
            )

        executable = _resolve_executable(executable_name, workdir)

        legacy_wine = (
            executable.name.lower() in ("wine", "wine64")
            and bool(app_args)
            and app_args[0].lower().endswith(".exe")
        )
        if legacy_wine:
            old_wine = executable
            executable = _resolve_executable(app_args.pop(0), workdir)
            if not runner and old_wine.parent.name == "bin":
                runner = old_wine.parent.parent.name
            mode = "wine"
        elif mode == "auto":
            mode = (
                "wine"
                if executable.suffix.lower() in (".exe", ".bat")
                else "native"
            )

        if mode not in ("wine", "native"):
            raise RuntimeError(
                f"{name} : mode inconnu {mode!r}. "
                "Valeurs possibles : auto, wine, native."
            )
        if not executable.is_file():
            raise RuntimeError(
                f"{name} : exécutable introuvable : {executable}"
            )
        if mode == "wine" and executable.suffix.lower() not in (".exe", ".bat"):
            raise RuntimeError(
                f"{name} : en mode Wine, executable doit désigner "
                f"un fichier .exe ou .bat : {executable}"
            )
        if mode == "wine" and not QUIVER_WINE.is_file():
            raise RuntimeError(
                f"{name} : launcher Wine introuvable : {QUIVER_WINE}"
            )

        setting_path = None
        if setting_file:
            setting_relative_path = Path(setting_file).expanduser()
            if setting_relative_path.is_absolute():
                setting_path = setting_relative_path
            elif mode == "wine":
                effective_runner = runner or "wine-proton"
                setting_path = (
                    Path("/userdata/system/wine-bottles/quiver")
                    / effective_runner
                    / f"{_safe_name(name)}.wine"
                    / "drive_c"
                    / setting_relative_path
                )
            else:
                setting_path = (workdir / setting_relative_path).resolve()

        settings_exists = bool(setting_path and setting_path.is_file())
        if not settings_exists and setting_path and preload_file:
            preload_name = Path(preload_file).name
            preload_path = QUIVER_PRELOAD_ROOT / preload_name
            if preload_path.is_file():
                try:
                    setting_path.parent.mkdir(parents=True, exist_ok=True)
                    if not setting_path.exists():
                        shutil.copy2(preload_path, setting_path)
                    settings_exists = setting_path.is_file()
                    if settings_exists:
                        _logger.info(
                            "Quiver : configuration initiale installée : %s",
                            preload_name,
                        )
                except OSError as error:
                    _logger.error(
                        "Quiver : impossible de copier le preload %s : %s",
                        preload_path,
                        error,
                    )
            else:
                _logger.warning(
                    "Quiver : fichier preload introuvable : %s",
                    preload_path,
                )

        launcher_quiver = (
            system.config.get("LAUNCHER_QUIVER", "on").strip().lower()
        )
        if not settings_exists:
            launcher_quiver = "on"
            _logger.info(
                "Quiver : configuration absente, ouverture du launcher activée"
            )
        launcher_is_on = _is_enabled(launcher_quiver)
        if launcher_is_on:
            app_args = [arg for arg in app_args if arg != "--play"]

        if launcher_is_on or rom.name.lower() == "quiver launcher.quiver":
            try:
                subprocess.run(["batocera-mouse", "show"], check=False)
            except OSError as error:
                _logger.warning(
                    "Quiver : impossible d'afficher la souris : %s",
                    error,
                )

        env = os.environ.copy()
        if mode == "wine":
            env["QUIVER_GAME_NAME"] = _safe_name(name)
        else:
            env.pop("QUIVER_GAME_NAME", None)

        env["SDL_GAMECONTROLLERCONFIG"] = (
            generate_sdl_game_controller_config(list(playersControllers))
        )
        env["SDL_JOYSTICK_HIDAPI"] = "0"

        if mode == "wine":
            if runner:
                env["QUIVER_WINE_RUNNER"] = runner
            else:
                env.pop("QUIVER_WINE_RUNNER", None)
            env.pop("WINEPREFIX", None)
        else:
            env.pop("QUIVER_WINE_RUNNER", None)

        xdg_config_home = QUIVER_CONFIG_ROOT / "config"
        xdg_data_home = QUIVER_CONFIG_ROOT / "data"
        runtime_dir = QUIVER_CONFIG_ROOT / "runtime"
        xdg_config_home.mkdir(parents=True, exist_ok=True)
        xdg_data_home.mkdir(parents=True, exist_ok=True)
        runtime_dir.mkdir(parents=True, exist_ok=True)
        runtime_dir.chmod(0o700)

        home_dir = QUIVER_CONFIG_ROOT / "wine" / _safe_name(folder)
        home_dir.mkdir(parents=True, exist_ok=True)
        env["HOME"] = str(home_dir)
        env["XDG_CONFIG_HOME"] = str(xdg_config_home)
        env["XDG_DATA_HOME"] = str(xdg_data_home)
        env["XDG_RUNTIME_DIR"] = str(runtime_dir)

        if mode == "wine":
            command = [
                str(QUIVER_WINE),
                "quiver",
                "play",
                str(executable),
                "--",
                *app_args,
            ]
        else:
            command = [str(executable), *app_args]

        os.chdir(workdir)
        _logger.info(
            "Quiver : lancement de %s (%s, runner %s)",
            name,
            mode,
            runner or "défaut",
        )

        return Command.Command(array=command, env=env)
