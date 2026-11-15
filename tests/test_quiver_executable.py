import ast
import asyncio
import configparser
import logging
import os
import shlex
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
CONFIGGEN = ROOT / "system" / "Quiver" / "configgen"
sys.path.insert(0, str(CONFIGGEN))
from quiver_cache import clear_game_cache

SOURCES = (
    ROOT / "system" / "Quiver" / "configgen" / "dcg_launch" / "quiver.py",
    ROOT / "system" / "Quiver" / "configgen" / "generators" / "quiver" / "quiver.py",
)


def load_resolver(source):
    # Batocera's launcher dependencies are unavailable on development machines.
    module = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
    function = next(
        node for node in module.body
        if isinstance(node, ast.FunctionDef) and node.name == "_resolve_executable"
    )
    namespace = {"Path": Path, "_logger": logging.getLogger(__name__)}
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"), namespace)
    return namespace["_resolve_executable"]


def load_generator(source, config_root):
    module = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
    nodes = [
        node for node in module.body
        if isinstance(node, (ast.FunctionDef, ast.ClassDef))
    ]

    class FakeCommand:
        def __init__(self, **kwargs):
            self.__dict__.update(kwargs)

    new_api = source.parent.name == "dcg_launch"
    namespace = {
        "Path": Path, "configparser": configparser, "logging": logging,
        "os": os, "shlex": shlex, "shutil": shutil, "sys": sys,
        "_logger": logging.getLogger(__name__),
        "QUIVER_CONFIG_ROOT": config_root,
        "QUIVER_PRELOAD_ROOT": config_root / "preload",
        "QUIVER_LIB_ROOT": config_root / "lib",
        "QUIVER_WINE": config_root / "wine-launcher",
        "Generator": object, "Emulator": object,
        "cached_dataclass": lambda cls: cls, "cached_property": property,
        "generate_sdl_game_controller_config": lambda controllers: "",
        "clear_game_cache": clear_game_cache,
        "Command": FakeCommand if new_api else SimpleNamespace(Command=FakeCommand),
    }
    nodes.insert(0, ast.parse("from __future__ import annotations").body[0])
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), namespace)
    return namespace["Quiver" if new_api else "QuiverGenerator"], new_api


class CacheTests(unittest.TestCase):
    def test_both_launchers_only_clear_opted_in_game_path(self):
        for source in SOURCES:
            for value in (None, "false", "true"):
                with self.subTest(source=source, value=value), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    game = root / "game"
                    workdir = root / "working directory"
                    game.mkdir()
                    workdir.mkdir()
                    (game / "cache").mkdir()
                    (game / "cache" / "shader").write_text("cache")
                    (workdir / "cache").mkdir()
                    (workdir / "game.bin").touch()
                    (game / "settings.ini").touch()
                    rom = root / "game.quiver"
                    option = f"clearcache={value}\n" if value is not None else ""
                    rom.write_text(
                        f"[Game]\nname=Test\n[Launcher]\npath={game}\n"
                        f"working_directory={workdir}\nexecutable=game.bin\n{option}"
                        f"[Config]\nsetting_file={game / 'settings.ini'}\n",
                        encoding="utf-8",
                    )
                    generator, new_api = load_generator(source, root / "config")
                    instance = generator()
                    with patch("os.chdir"):
                        if new_api:
                            instance.rom = rom
                            instance.config = {"LAUNCHER_QUIVER": "off"}
                            instance.controllers = []
                            command = asyncio.run(instance.configure())
                            self.assertEqual(command.args[0], str(workdir / "game.bin"))
                        else:
                            system = SimpleNamespace(config={"LAUNCHER_QUIVER": "off"})
                            command = instance.generate(system, rom, [], None, None, None, None)
                            self.assertEqual(command.array[0], str(workdir / "game.bin"))
                    self.assertEqual((game / "cache").exists(), value != "true")
                    self.assertTrue((workdir / "cache").is_dir())
                    self.assertTrue((game / "settings.ini").is_file())

    def test_missing_cache_is_allowed_and_invalid_configuration_fails(self):
        parser = configparser.ConfigParser()
        parser.read_string("[Launcher]\nclearcache=true\n")
        with tempfile.TemporaryDirectory() as temp:
            clear_game_cache(parser, temp)
            with self.assertRaises(RuntimeError):
                clear_game_cache(parser, "")
            (Path(temp) / "cache").touch()
            with self.assertRaises(RuntimeError):
                clear_game_cache(parser, temp)
        parser.set("Launcher", "clearcache", "perhaps")
        with self.assertRaises(RuntimeError):
            clear_game_cache(parser, "")

    def test_removal_failure_stops_launch(self):
        parser = configparser.ConfigParser()
        parser.read_string("[Launcher]\nclearcache=true\n")
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp) / "cache"
            cache.mkdir()
            with patch("quiver_cache.shutil.rmtree", side_effect=PermissionError("denied")):
                with self.assertRaisesRegex(RuntimeError, "impossible de supprimer"):
                    clear_game_cache(parser, temp)
            self.assertTrue(cache.is_dir())

    def test_symbolic_cache_is_not_followed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            game = root / "game"
            target = root / "target"
            game.mkdir()
            target.mkdir()
            try:
                (game / "cache").symlink_to(target, target_is_directory=True)
            except OSError as error:
                self.skipTest(f"Symbolic links unavailable: {error}")
            parser = configparser.ConfigParser()
            parser.read_string("[Launcher]\nclearcache=true\n")
            with self.assertRaises(RuntimeError):
                clear_game_cache(parser, str(game))
            self.assertTrue(target.is_dir())


class ExecutableResolutionTests(unittest.TestCase):
    def test_pattern_uses_modification_date_not_version_number(self):
        for source in SOURCES:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                workdir = Path(directory)
                older = workdir / "SacredFire-v0.8.5-x86_64.AppImage"
                newer = workdir / "SacredFire-v0.8.3-x86_64.AppImage"
                other = workdir / "Other-v1-x86_64.AppImage"
                for path, timestamp in ((older, 1000), (newer, 2000), (other, 3000)):
                    path.touch()
                    os.utime(path, (timestamp, timestamp))
                result = load_resolver(source)("SacredFire-v*-x86_64.AppImage", workdir)
                self.assertEqual(result, newer.resolve())

    def test_unmatched_pattern_does_not_select_unrelated_appimage(self):
        for source in SOURCES:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                workdir = Path(directory)
                (workdir / "Other.AppImage").touch()
                pattern = "SacredFire-v*-x86_64.AppImage"
                result = load_resolver(source)(pattern, workdir)
                self.assertEqual(result, (workdir / pattern).resolve())

    def test_equal_modification_dates_have_stable_selection(self):
        for source in SOURCES:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                workdir = Path(directory)
                for name in ("Game-2.exe", "Game-1.exe"):
                    path = workdir / name
                    path.touch()
                    os.utime(path, (1000, 1000))
                result = load_resolver(source)("Game-*.exe", workdir)
                self.assertEqual(result, (workdir / "Game-1.exe").resolve())


if __name__ == "__main__":
    unittest.main()
