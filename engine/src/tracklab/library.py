"""A biblioteca: a pasta com uma pasta `.tracklab` por música, num disco que o Miguel escolhe (3/11/2026).

Fica em `~/TrackLab/config.json` → `library`; sem ela, `~/TrackLab/Repertorio`. O resto do TrackLab (os modelos, os
SoundFonts, o índice das multitracks, a cota do MVSEP) continua em `~/TrackLab`: só as músicas mudam de disco, e um
backup da biblioteca é copiar essa pasta. Mudar de pasta move as músicas (`move`, na fila): cada uma é copiada para
uma pasta oculta no destino, conferida arquivo por arquivo (tamanho e SHA-256), renomeada para o nome dela e só então
apagada na origem; a configuração muda no fim. Uma música que já existe no destino não é sobrescrita.
"""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

from . import home
from .errors import TrackLabError
from .util import atomic_json, new_id, sha256_file

SUFFIX = ".tracklab"


class LibraryError(TrackLabError):
    """A pasta escolhida para a biblioteca não serve (não existe, não se escreve nela, não cabe)."""


def _config_file() -> Path:
    return home.home() / "config.json"


def _config() -> dict:
    path = _config_file()
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def default_folder() -> Path:
    return home.home() / "Repertorio"


def folder() -> Path:
    """A pasta das músicas: a escolhida no config.json, ou `~/TrackLab/Repertorio`."""
    chosen = _config().get("library")
    path = Path(chosen).expanduser() if isinstance(chosen, str) and chosen else default_folder()
    path.mkdir(parents=True, exist_ok=True)
    return path


def info() -> dict:
    """Onde está a biblioteca, quantas músicas, quanto ocupa e quanto sobra no disco."""
    root = folder()
    songs = sorted(root.glob(f"*{SUFFIX}"))
    used = sum(file.stat().st_size for song in songs for file in song.rglob("*") if file.is_file())
    usage = shutil.disk_usage(root)
    return {"path": str(root), "default": root == default_folder(), "songs": len(songs), "bytes": used,
            "free": usage.free, "volume": _volume(root)}


def _volume(path: Path) -> str:
    """O nome do disco: o de /Volumes/<nome>, ou o disco do sistema."""
    parts = path.resolve().parts
    return parts[2] if len(parts) > 2 and parts[1] == "Volumes" else "Macintosh HD"


def check_target(target: Path) -> Path:
    target = Path(target).expanduser()
    if not target.is_absolute():
        raise LibraryError("Escolha uma pasta (o caminho inteiro).")
    if not target.is_dir():
        raise LibraryError(f"A pasta {target} não existe.")
    if not os.access(target, os.W_OK):
        raise LibraryError(f"Não consigo gravar em {target}.")
    current = folder().resolve()
    resolved = target.resolve()
    if resolved == current:
        raise LibraryError("A biblioteca já está nessa pasta.")
    if current in resolved.parents:
        raise LibraryError("A pasta nova não pode ficar dentro da biblioteca atual.")
    return target


def move(target: Path, *, progress=None, cancel=None) -> dict:
    """Leva as músicas para `target` e passa a usá-la; devolve quantas foram e quantas já estavam lá."""
    target = check_target(target)
    source = folder()
    songs = sorted(source.glob(f"*{SUFFIX}"))
    needed = sum(file.stat().st_size for song in songs for file in song.rglob("*") if file.is_file())
    if shutil.disk_usage(target).free < needed * 1.05 + 200_000_000:
        raise LibraryError(f"Não cabe: as músicas ocupam {needed / 1e9:.1f} GB e o disco tem "
                           f"{shutil.disk_usage(target).free / 1e9:.1f} GB livres.")
    moved, kept = 0, []
    for index, song in enumerate(songs):
        if cancel is not None:
            cancel.check()
        if progress is not None:
            progress("biblioteca", f"Movendo {song.name} ({index + 1} de {len(songs)})…", index / max(len(songs), 1))
        destination = target / song.name
        if destination.exists():
            kept.append(song.name)
            continue
        draft = target / f".{song.name}.{new_id()}.partial"
        try:
            shutil.copytree(song, draft)
            _verify(song, draft)
            draft.rename(destination)
        except BaseException:
            shutil.rmtree(draft, ignore_errors=True)
            raise
        shutil.rmtree(song)
        moved += 1
    config = _config()
    config["library"] = str(target)
    atomic_json(_config_file(), config)
    if progress is not None:
        progress("biblioteca", "Biblioteca movida.", 1.0)
    return {"path": str(target), "moved": moved, "kept": kept}


def _verify(original: Path, copy: Path) -> None:
    """A cópia tem os mesmos arquivos, do mesmo tamanho e com o mesmo conteúdo."""
    for file in original.rglob("*"):
        if not file.is_file():
            continue
        twin = copy / file.relative_to(original)
        if not twin.is_file() or twin.stat().st_size != file.stat().st_size or sha256_file(twin) != sha256_file(file):
            raise LibraryError(f"A cópia de {file.relative_to(original.parent)} não confere; nada foi apagado.")


def use(target: Path) -> dict:
    """Passa a usar `target` como está (outra biblioteca já pronta), sem mover nada."""
    target = Path(target).expanduser()
    if not target.is_dir():
        raise LibraryError(f"A pasta {target} não existe.")
    config = _config()
    config["library"] = str(target)
    atomic_json(_config_file(), config)
    return info()


__all__ = ["LibraryError", "check_target", "default_folder", "folder", "info", "move", "use"]
