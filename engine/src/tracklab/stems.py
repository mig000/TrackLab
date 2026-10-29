"""Faixas separadas de uma música do repertório: a chave junta provedor, modelo, versão e o hash do áudio.

A mesma música com o mesmo modelo nunca separa duas vezes (no MVSEP, isso é uma conversão do dia que não se gasta de
novo); cada provedor é outra pasta em `stems/`, e o A/B do app escolhe qual fica ativa. A escada da Fase 4:

    demucs6s-…     Demucs 6s local, na GPU: sempre, a primeira e a reserva
    multitrack-…   as faixas da gravação, da biblioteca de multitracks, alinhadas ao áudio do vídeo
    mvsep31-…      a guitarra do MVSEP (e o resto da banda pelo Demucs local)
    mvsep101-…     guitarra solo e base do MVSEP
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable

from . import multitracks
from .errors import PackageError
from .media import multitrack as multitrack_media
from .media import mvsep
from .media import separate as demucs
from .package import SongPackage
from .util import sha256_text

Progress = Callable[[str, str, float | None], None]

# A faixa do TrackLab de cada instrumento da multitrack; `rhythm` é decidido pelo song.ini.
MULTITRACK_STEMS = {"guitar": "guitar", "bass": "bass", "drums": "drums", "vocals": "vocals", "keys": "piano",
                    "backing": "other", "other": "other"}
SKIPPED = re.compile(r"crowd|preview|click|count.?in", re.IGNORECASE)


def demucs_key(audio_sha: str, version: str) -> str:
    return f"demucs6s-{sha256_text(audio_sha + '|' + version)[:8]}"


def multitrack_key(audio_sha: str, library_path: str) -> str:
    return f"multitrack-{sha256_text(audio_sha + '|' + library_path + '|' + multitrack_media.PROCEDURE)[:8]}"


def mvsep_key(audio_sha: str, model: int) -> str:
    options = sorted(mvsep.MODELS[model]["options"].items())
    return f"mvsep{model}-{sha256_text(f'{audio_sha}|{model}|{options}|{mvsep.PROCEDURE}')[:8]}"


def separate_song(package: SongPackage, *, progress: Progress | None = None, cancel=None, device: str | None = None,
                  run=None) -> dict:
    """Separa o áudio do pacote com o Demucs 6s (GPU quando houver) e publica as seis faixas; devolve o registro."""
    audio = _audio(package)
    version = demucs.separator_version()
    key = demucs_key(audio["sha256"], version)

    def build(folder):
        receipt = (run or demucs.separate)(package.file(audio["file"]), folder, progress=progress, cancel=cancel,
                                           device=device)
        receipt["provider"] = "demucs"
        return receipt

    return _publish(package, key, build, progress, demucs.STAGE, activate=True)


def import_multitrack(package: SongPackage, entry: dict, *, folder: Path | None = None,
                      progress: Progress | None = None, cancel=None) -> dict:
    """As faixas da multitrack `entry` (uma linha do índice) alinhadas ao áudio do vídeo do pacote."""
    audio = _audio(package)
    if entry.get("format") == "mogg":
        raise multitracks.MultitrackError("Arquivos .mogg (Rock Band) ainda não entram: as faixas estão misturadas "
                                          "num arquivo só, sem o mapa dos canais.")
    base = Path(folder or multitracks.root()) / entry["path"]
    if not base.is_dir():
        raise multitracks.MultitrackError(f"Não achei {entry['path']} na biblioteca (o HD externo está ligado?).")
    tracks = multitrack_tracks(entry, base)
    key = multitrack_key(audio["sha256"], entry["path"])

    def build(output):
        receipt = multitrack_media.assemble(
            package.file(audio["file"]), tracks, output, progress=progress, cancel=cancel,
            details={"library": entry["path"], "format": entry.get("format"),
                     "name": " — ".join(part for part in (entry.get("artist"), entry.get("title")) if part)})
        receipt["provider"] = "multitrack"
        return receipt

    return _publish(package, key, build, progress, multitrack_media.STAGE, activate=False)


def multitrack_tracks(entry: dict, base: Path) -> list[tuple[Path, str]]:
    """Os arquivos da multitrack e a faixa do TrackLab de cada um. No Clone Hero, `rhythm` é a guitarra base quando
    o song.ini tem a parte de base (`diff_rhythm`); senão é o baixo, como no Rock Band."""
    ini = multitracks._read_ini(base / "song.ini") if entry.get("format") == "clonehero" else {}
    rhythm = "rhythm" if entry.get("format") != "clonehero" or _number(ini.get("diff_rhythm")) >= 0 else "bass"
    tracks = []
    for stem in entry.get("stems", []):
        name = stem["file"]
        if SKIPPED.search(Path(name).stem):
            continue
        kind = stem.get("kind") or multitracks.kind_of(name)
        key = rhythm if kind == "rhythm" else MULTITRACK_STEMS.get(kind, "other")
        tracks.append((base / name, key))
    return tracks


def separate_mvsep(package: SongPackage, *, key: str, model: int = 31, progress: Progress | None = None,
                   cancel=None, session=None, demucs_run=None, pause=None) -> dict:
    """A guitarra do MVSEP (uma conversão do dia) com o resto da banda pelo Demucs local."""
    audio = _audio(package)
    model = mvsep.check_model(model)
    api_key = mvsep.check_key(key)
    stems_key = mvsep_key(audio["sha256"], model)

    def build(output):
        extra = {"pause": pause} if pause is not None else {}
        receipt = mvsep.separate(package.file(audio["file"]), output, key=api_key, model=model, progress=progress,
                                 cancel=cancel, session=session, demucs_run=demucs_run, **extra)
        receipt["provider"] = "mvsep"
        return receipt

    return _publish(package, stems_key, build, progress, mvsep.STAGE, activate=False)


def _publish(package: SongPackage, key: str, build, progress, stage: str, *, activate: bool) -> dict:
    done = package.manifest.get("stems", {}).get(key)
    if done and all(package.file(path).is_file() for path in done.get("files", {}).values()):
        if progress is not None:
            progress(stage, "Estas faixas já estavam prontas.", 1.0)
        return {"key": key, **done, "reused": True}
    updated = package.add_stems(key, build, activate=activate)
    return {"key": key, **updated["stems"][key], "active": updated["activeStems"] == key, "reused": False}


def _audio(package: SongPackage) -> dict:
    audio = package.manifest.get("audio")
    if not audio:
        raise PackageError("Esta música não tem áudio para separar.")
    return audio


def _number(text) -> float:
    try:
        return float(text)
    except (TypeError, ValueError):
        return -1.0
