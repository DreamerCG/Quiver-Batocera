import ast
import logging
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
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
