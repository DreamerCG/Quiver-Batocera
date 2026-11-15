import configparser
import logging
import shutil
import sys
from pathlib import Path


_logger = logging.getLogger(__name__)


def clear_game_cache(parser: configparser.ConfigParser, game_path: str) -> None:
    value = parser.get("Launcher", "clearcache", fallback="false").strip()
    try:
        enabled = configparser.ConfigParser.BOOLEAN_STATES[value.lower()]
    except KeyError as error:
        raise RuntimeError(f"Quiver : valeur clearcache invalide : {value!r}") from error

    if not enabled:
        return
    if not game_path:
        raise RuntimeError("Quiver : path est obligatoire pour clearcache")

    directory = Path(game_path).expanduser().resolve()
    if directory == directory.parent or not directory.is_dir():
        raise RuntimeError(f"Quiver : path invalide pour clearcache : {directory}")

    relative_cache = Path(
        parser.get("Launcher", "path_cache", fallback="cache").strip()
    )
    if (
        relative_cache.is_absolute()
        or ".." in relative_cache.parts
        or relative_cache.name != "cache"
    ):
        raise RuntimeError(
            f"Quiver : path_cache invalide : {relative_cache}"
        )

    cache = directory
    for part in relative_cache.parts:
        cache = cache / part
        if cache.is_symlink():
            raise RuntimeError(f"Quiver : chemin cache symbolique : {cache}")
    if not cache.exists():
        print(f"[Quiver] clearcache : dossier absent : {cache}", file=sys.stderr, flush=True)
        return
    if not cache.is_dir():
        raise RuntimeError(f"Quiver : cache n'est pas un dossier : {cache}")

    try:
        shutil.rmtree(cache)
    except OSError as error:
        raise RuntimeError(f"Quiver : impossible de supprimer {cache} : {error}") from error
    _logger.info("Quiver : cache supprimé : %s", cache)
    print(f"[Quiver] clearcache : dossier supprimé : {cache}", file=sys.stderr, flush=True)
