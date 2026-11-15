import configparser
import logging
import shutil
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

    cache = directory / "cache"
    if cache.is_symlink():
        raise RuntimeError(f"Quiver : cache est un lien symbolique : {cache}")
    if not cache.exists():
        return
    if not cache.is_dir():
        raise RuntimeError(f"Quiver : cache n'est pas un dossier : {cache}")

    try:
        shutil.rmtree(cache)
    except OSError as error:
        raise RuntimeError(f"Quiver : impossible de supprimer {cache} : {error}") from error
    _logger.info("Quiver : cache supprimé : %s", cache)
