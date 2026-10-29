
from __future__ import annotations

import configparser
import logging
import os
import shlex
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

        name = parser.get("Game", "name", fallback=rom.stem).strip()
        folder = parser.get("Game", "Folder", fallback=rom.stem).strip()
        game_path = parser.get("Game", "path", fallback="").strip()
        executable_name = parser.get(
            "Game", "executable", fallback=""
        ).strip()
        working_directory = parser.get(
            "Game", "working_directory", fallback=""
        ).strip()
        arguments = parser.get("Game", "args", fallback="").strip()
        setting_file = parser.get(
            "Game", "setting_file", fallback=""
        ).strip()

        # Mode : auto, wine ou native.
        mode = parser.get(
            "Game", "mode", fallback="auto"
        ).strip().lower()

        # Runner défini dans le profil du jeu : priorité maximale.
        runner = parser.get(
            "Game", "runner", fallback=""
        ).strip()

        # Runner choisi dans les options EmulationStation.
        feature_runner = self.config.get("wine-runner", "").strip()

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

        # Le répertoire du jeu sert de répertoire de travail par défaut.
        if not working_directory:
            working_directory = game_path

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

        try:
            app_args = shlex.split(arguments)

            launch_command = parser.get(
                "Launch", "command", fallback=""
            ).strip()

            launch_parts = shlex.split(launch_command) if launch_command else []

        except ValueError as error:
            raise RuntimeError(
                f"{name} : arguments mal formés dans {rom}: {error}"
            ) from error

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

            # Déduire le nom du runner du chemin :
            # .../wine/custom/NOM_DU_RUNNER/bin/wine
            if not runner:
                try:
                    if old_wine.parent.name == "bin":
                        runner = old_wine.parent.parent.name
                except (OSError, IndexError):
                    pass

            mode = "wine"

        elif mode == "auto":
            mode = "wine" if executable.suffix.lower() == ".exe" else "native"

        if mode not in ("wine", "native"):
            raise RuntimeError(
                f"{name} : mode inconnu {mode!r}. "
                "Valeurs possibles : auto, wine, native."
            )

        if not executable.is_file():
            raise RuntimeError(
                f"{name} : exécutable introuvable : {executable}"
            )

        if mode == "wine" and executable.suffix.lower() != ".exe":
            raise RuntimeError(
                f"{name} : en mode Wine, executable doit désigner "
                f"le fichier .exe du jeu : {executable}"
            )

        if mode == "wine" and not BATOCERA_WINE.is_file():
            raise RuntimeError(
                f"{name} : launcher Wine introuvable : {BATOCERA_WINE}"
            )


        # Gestion du launcher Quiver
        setting_path = None

        if setting_file:
            setting_relative_path = Path(setting_file).expanduser()

            if setting_relative_path.is_absolute():
                setting_path = setting_relative_path

            elif mode == "wine":
                # En Auto, le runner par défaut est wine-proton.
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

        settings_exists = bool(
            setting_path and setting_path.is_file()
        )

        print("[QUIVER DEBUG] ===== SETTINGS =====", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] Jeu       : {name!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] Mode      : {mode!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] Runner    : {runner!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] setting_file brut : {setting_file!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] setting_path     : {str(setting_path)!r}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] chemin absolu    : {setting_path.is_absolute() if setting_path else None}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] fichier existe  : {setting_path.is_file() if setting_path else False}", file=sys.stderr, flush=True)
        print(f"[QUIVER DEBUG] launcher activé  : {self.config.get('LAUNCHER_QUIVER', 'on')!r}", file=sys.stderr, flush=True)
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

        if _is_enabled(launcher_quiver):
            app_args = [arg for arg in app_args if arg != "--play"]

        if (
            _is_enabled(launcher_quiver)
            or rom.name.lower() == "quiver launcher.quiver"
        ):
            subprocess.run(["batocera-mouse", "show"], check=False)


        # Préparer la commande selon le type de jeu.
        env = os.environ.copy()

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
            payload = [
                str(BATOCERA_WINE),
                "quiver",
                "play",
                str(executable),
                "--",
                *app_args,
            ]

            # Le script batocera-wine utilisera ce runner pour ce jeu.
            if runner:
                env["QUIVER_WINE_RUNNER"] = runner
            else:
                env.pop("QUIVER_WINE_RUNNER", None)

            # Le préfixe sera géré par batocera-wine.
            env.pop("WINEPREFIX", None)

        else:
            payload = [str(executable), *app_args]
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


        # print(
        #     "[QUIVER DEBUG] ===== ENV COMPLET =====",
        #     file=sys.stderr,
        #     flush=True,
        # )

        # for key, value in sorted(env.items()):
        #     print(
        #         f"[QUIVER DEBUG] ENV {key}={value!r}",
        #         file=sys.stderr,
        #         flush=True,
        #     )

        # print(
        #     "[QUIVER DEBUG] ===== FIN ENV =====",
        #     file=sys.stderr,
        #     flush=True,
        # )

        print(
            f"[QUIVER DEBUG] QUIVER_WINE_RUNNER="
            f"{env.get('QUIVER_WINE_RUNNER', '<absent>')!r}",
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
