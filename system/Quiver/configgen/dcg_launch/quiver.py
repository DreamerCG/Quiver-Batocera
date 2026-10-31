
from __future__ import annotations

import configparser
import logging
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from batocera_common.dataclasses import cached_dataclass, cached_property
from batocera_launch.devices.controller import generate_sdl_game_controller_config
from batocera_launch.command import Command
from batocera_launch.emulator import Emulator
from batocera_launch.types import HotkeysContext

_logger = logging.getLogger(__name__)

QUIVER_CONFIG_ROOT = Path("/userdata/system/configs/Quiver")
QUIVER_PRELOAD_ROOT = Path("/userdata/system/Quiver/preload")
BATOCERA_WINE = Path("/userdata/system/Quiver/bin/batocera-wine")


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

    # Le fichier exact existe : comportement habituel.
    if executable.is_file():
        return executable

    # Si l'exécutable attendu est une AppImage, rechercher
    # automatiquement une version mise à jour dans le dossier du jeu.
    if executable.suffix.lower() == ".appimage":
        candidates = sorted(
            path.resolve()
            for path in executable.parent.glob("*.AppImage")
            if path.is_file()
        )

        if len(candidates) == 1:
            _logger.info(
                "AppImage introuvable (%s), utilisation de la version disponible : %s",
                executable.name,
                candidates[0].name,
            )
            return candidates[0]

        if len(candidates) > 1:
            # Privilégier les fichiers partageant le préfixe du nom attendu.
            prefix = executable.name.split("-v", 1)[0]
            matching = [
                path for path in candidates
                if path.name.startswith(prefix)
            ]

            if len(matching) == 1:
                _logger.info(
                    "AppImage introuvable (%s), utilisation de : %s",
                    executable.name,
                    matching[0].name,
                )
                return matching[0]

    return executable


@cached_dataclass
class Quiver(Emulator):

    @cached_property
    def hotkeygen_context(self) -> HotkeysContext:
        return {
            "name": "quiver",
            "keys": {
                "exit": "KEY_ESC",
                "coin": "KEY_5",
            },
        }

    async def configure(self) -> Command:
        rom = Path(self.rom)

        if not rom.is_file():
            raise RuntimeError(f"Fichier .quiver introuvable : {rom}")

        parser = _read_quiver_file(rom)

        # Identité du jeu.
        name = parser.get(
            "Game", "name", fallback=rom.stem
        ).strip()

        folder = parser.get(
            "Game", "Folder", fallback=rom.stem
        ).strip()

        # Launcher : nouveau format [Launcher],
        # ancien format [Game].
        game_path = parser.get(
            "Launcher", "path",
            fallback=parser.get("Game", "path", fallback="")
        ).strip()

        executable_name = parser.get(
            "Launcher", "executable",
            fallback=parser.get("Game", "executable", fallback="")
        ).strip()

        working_directory = parser.get(
            "Launcher", "working_directory",
            fallback=parser.get("Game", "working_directory", fallback="")
        ).strip()

        if not working_directory:
            working_directory = game_path

        arguments = parser.get(
            "Launcher", "args",
            fallback=parser.get("Game", "args", fallback="")
        ).strip()

        # Configuration : nouveau format [Config],
        # ancien format [Game].
        setting_file = parser.get(
            "Config", "setting_file",
            fallback=parser.get("Game", "setting_file", fallback="")
        ).strip()

        preload_file = parser.get(
            "Config", "preload_file",
            fallback=parser.get("Game", "preload_file", fallback="")
        ).strip()

        # Mode et runner restent dans [Game].
        mode = parser.get(
            "Game", "mode", fallback="auto"
        ).strip().lower()

        runner = parser.get(
            "Game", "runner", fallback=""
        ).strip()

        # Runner choisi dans les options EmulationStation.
        feature_runner = self.config.get("wine-runner", "").strip()

        # Lecture du runner Batocera pour diagnostic.
        try:
            result = subprocess.run(
                [
                    "/usr/bin/batocera-settings-get",
                    'quiver["Drive Club.quiver"].wine-runner',
                    "quiver.wine-runner",
                    "global.wine-runner",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            print(
                f"[QUIVER DEBUG] Runner batocera-settings-get : "
                f"stdout={result.stdout!r}, stderr={result.stderr!r}, "
                f"returncode={result.returncode}",
                file=sys.stderr,
                flush=True,
            )

        except Exception as error:
            print(
                f"[QUIVER DEBUG] Lecture du runner impossible : {error}",
                file=sys.stderr,
                flush=True,
            )

        if not runner and feature_runner:
            if feature_runner.lower() not in ("auto", "default", "none"):
                runner = feature_runner

        # Compatibilité avec l'ancien format [Launch].
        # Le nouveau format utilise [Launcher].
        try:
            launch_command = parser.get(
                "Launcher", "command",
                fallback=parser.get("Launch", "command", fallback="")
            ).strip()

            app_args = shlex.split(arguments)

            launch_parts = (
                shlex.split(launch_command) if launch_command else []
            )

        except ValueError as error:
            raise RuntimeError(
                f"{name} : arguments mal formés dans {rom}: {error}"
            ) from error

        # Vérification du répertoire de travail.
        if not working_directory:
            raise RuntimeError(
                f"{name} : le paramètre path est absent dans {rom}"
            )

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

        # Compatibilité avec l'ancien format :
        # executable=/chemin/vers/wine
        # args="/chemin/vers/jeu.exe" --play
        legacy_wine = (
            executable.name.lower() in ("wine", "wine64")
            and bool(app_args)
            and app_args[0].lower().endswith(".exe")
        )

        if legacy_wine:
            old_wine = executable
            executable = _resolve_executable(app_args.pop(0), workdir)

            # Déduire le nom du runner du chemin.
            if not runner:
                try:
                    if old_wine.parent.name == "bin":
                        runner = old_wine.parent.parent.name
                except (OSError, IndexError):
                    pass

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

        if mode == "wine" and not BATOCERA_WINE.is_file():
            raise RuntimeError(
                f"{name} : launcher Wine introuvable : {BATOCERA_WINE}"
            )

        # Gestion du launcher Quiver.
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
                setting_path = (
                    workdir / setting_relative_path
                ).resolve()

        # Installation automatique du fichier preload.
        settings_exists = bool(
            setting_path and setting_path.is_file()
        )

        if not settings_exists and setting_path and preload_file:
            preload_name = Path(preload_file).name
            preload_path = QUIVER_PRELOAD_ROOT / preload_name

            if preload_path.is_file():
                try:
                    setting_path.parent.mkdir(
                        parents=True,
                        exist_ok=True
                    )

                    # Copie uniquement si le fichier de destination
                    # n'existe pas déjà.
                    if not setting_path.exists():
                        shutil.copy2(preload_path, setting_path)

                    settings_exists = setting_path.is_file()

                    if settings_exists:
                        _logger.info(
                            "Quiver : configuration initiale copiée : %s -> %s",
                            preload_path,
                            setting_path
                        )

                        print(
                            f"[QUIVER] Configuration preload installée : "
                            f"{preload_name}",
                            file=sys.stderr,
                            flush=True,
                        )

                except OSError as error:
                    _logger.error(
                        "Quiver : impossible de copier le preload %s : %s",
                        preload_path,
                        error
                    )

            else:
                _logger.warning(
                    "Quiver : fichier preload introuvable : %s",
                    preload_path
                )

        print("[QUIVER DEBUG] ===== SETTINGS =====", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] Jeu       : {name!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] Mode      : {mode!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] Runner    : {runner!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] setting_file brut : {setting_file!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] setting_path     : {str(setting_path)!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] fichier existe  : {setting_path.is_file() if setting_path else False}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] preload_file    : {preload_file!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] settings_exists : {settings_exists}", file=sys.stderr, flush=True)
        print("[QUIVER DEBUG] =====================", file=sys.stderr, flush=True)

        launcher_quiver = self.config.get(
            "LAUNCHER_QUIVER", "on"
        ).strip().lower()

        if not settings_exists:
            launcher_quiver = "on"

            print(
                "[QUIVER DEBUG] Fichier absent : ouverture forcée du launcher.",
                file=sys.stderr,
                flush=True,
            )

        # --- DEBUG : état du launcher ---
        launcher_is_on = _is_enabled(launcher_quiver)

        print(
            f"[QUIVER DEBUG] LAUNCHER_QUIVER brut : {launcher_quiver!r}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] Launcher : {'ON' if launcher_is_on else 'OFF'}",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"[QUIVER DEBUG] Arguments avant filtre : {app_args!r}",
            file=sys.stderr,
            flush=True,
        )
        # --------------------------------

        if launcher_is_on:
            app_args = [arg for arg in app_args if arg != "--play"]

        print(
            f"[QUIVER DEBUG] Arguments après filtre : {app_args!r}",
            file=sys.stderr,
            flush=True,
        )

        if (
            _is_enabled(launcher_quiver)
            or rom.name.lower() == "quiver launcher.quiver"
        ):
            subprocess.run(["batocera-mouse", "show"], check=False)

        # Préparer la commande selon le type de jeu.
        env = os.environ.copy()

        if mode == "wine":
            env["QUIVER_GAME_NAME"] = _safe_name(name)
        else:
            env.pop("QUIVER_GAME_NAME", None)

        # Transmission de la configuration des manettes Batocera à SDL/Wine.
        try:
            controllers = list(self.controllers)

            env["SDL_GAMECONTROLLERCONFIG"] = (
                generate_sdl_game_controller_config(controllers)
            )

            env["SDL_JOYSTICK_HIDAPI"] = "0"

            print(
                f"[QUIVER DEBUG] Manettes détectées : {len(controllers)}",
                file=sys.stderr,
                flush=True,
            )

            print(
                f"[QUIVER DEBUG] SDL_GAMECONTROLLERCONFIG="
                f"{env['SDL_GAMECONTROLLERCONFIG']!r}",
                file=sys.stderr,
                flush=True,
            )

        except Exception as error:
            print(
                f"[QUIVER DEBUG] Erreur configuration manettes : {error}",
                file=sys.stderr,
                flush=True,
            )

        if mode == "wine":
            # Le script batocera-wine utilisera ce runner pour ce jeu.
            if runner:
                env["QUIVER_WINE_RUNNER"] = runner
            else:
                env.pop("QUIVER_WINE_RUNNER", None)

            # Le préfixe sera géré par batocera-wine.
            env.pop("WINEPREFIX", None)

        else:
            env.pop("QUIVER_WINE_RUNNER", None)

        # Configuration XDG isolée pour Quiver.
        xdg_config_home = QUIVER_CONFIG_ROOT / "config"
        xdg_data_home = QUIVER_CONFIG_ROOT / "data"
        runtime_dir = QUIVER_CONFIG_ROOT / "runtime"

        xdg_config_home.mkdir(parents=True, exist_ok=True)
        xdg_data_home.mkdir(parents=True, exist_ok=True)
        runtime_dir.mkdir(parents=True, exist_ok=True)
        runtime_dir.chmod(0o700)

        # HOME distinct pour chaque jeu.
        safe_game_name = _safe_name(folder)
        home_dir = QUIVER_CONFIG_ROOT / "wine" / safe_game_name
        home_dir.mkdir(parents=True, exist_ok=True)

        env["HOME"] = str(home_dir)
        env["XDG_CONFIG_HOME"] = str(xdg_config_home)
        env["XDG_DATA_HOME"] = str(xdg_data_home)
        env["XDG_RUNTIME_DIR"] = str(runtime_dir)

        # Construction de la commande de lancement.
        if mode == "wine":
            command = [
                str(BATOCERA_WINE),
                "quiver",
                "play",
                str(executable),
                "--",
                *app_args,
            ]

        else:
            command = [
                str(executable),
                *app_args,
            ]

        _logger.info("Quiver : jeu=%s", name)
        _logger.info("Quiver : mode=%s", mode)
        _logger.info("Quiver : runner=%s", runner or "(runner Batocera)")
        _logger.info("Quiver : dossier=%s", workdir)
        _logger.info("Quiver : arguments=%s", app_args)
        _logger.debug("Quiver : commande=%s", shlex.join(command))

        print(
            f"[QUIVER] Jeu={name} mode={mode} runner={runner or 'défaut'}",
            file=sys.stderr,
            flush=True,
        )

        print(
            f"[QUIVER] Commande={shlex.join(command)}",
            file=sys.stderr,
            flush=True,
        )

        print(
            f"[QUIVER DEBUG] QUIVER_WINE_RUNNER="
            f"{env.get('QUIVER_WINE_RUNNER', '<absent>')!r}",
            file=sys.stderr,
            flush=True,
        )

        print(
            f"[QUIVER DEBUG] QUIVER_GAME_NAME="
            f"{env.get('QUIVER_GAME_NAME', '<absent>')!r}",
            file=sys.stderr,
            flush=True,
        )

        print(
            f"[QUIVER DEBUG] WINEPREFIX="
            f"{env.get('WINEPREFIX', '<absent>')!r}",
            file=sys.stderr,
            flush=True,
        )

        print(
            f"[QUIVER DEBUG] HOME={env.get('HOME', '<absent>')!r}",
            file=sys.stderr,
            flush=True,
        )

        return Command(args=command, env=env)