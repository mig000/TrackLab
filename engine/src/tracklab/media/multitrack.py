"""As faixas da gravação no lugar da separação: os arquivos da multitrack alinhados ao áudio do vídeo.

O mapa de tempo e a Fita são do áudio do vídeo, então as faixas precisam cair sobre ele amostra a amostra: a soma da
multitrack é alinhada ao vídeo (`align`), cada arquivo é lido na taxa do vídeo, deslocado (e com a velocidade
corrigida, se for o caso) e somado no instrumento dele. Se os trechos da música não concordam num deslocamento só, a
multitrack é outra gravação e nada é importado.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile

from ..errors import MediaError
from ..util import atomic_json, now_iso, sha256_file
from . import align
from .separate import _write_stem

Progress = Callable[[str, str, float | None], None]

STAGE = "multitrack"
PROCEDURE = "multitrack.v2"   # v2: consenso dos trechos (RANSAC), velocidade até 2 %, ganho pela energia


def assemble(source: Path, tracks: list[tuple[Path, str]], output: Path, *, progress: Progress | None = None,
             cancel=None, details: dict | None = None) -> dict:
    """Grava `output/<faixa>.flac` (na taxa e no tamanho da fonte) a partir de `tracks` (arquivo, faixa); arquivos da
    mesma faixa se somam. `details` vai para o recibo (de onde veio a multitrack)."""
    source, output = Path(source), Path(output)
    if not tracks:
        raise MediaError("Esta multitrack não tem faixas de áudio que o TrackLab saiba usar.")
    started = time.monotonic()
    info = soundfile.info(str(source))
    rate, frames = int(info.samplerate), int(info.frames)
    _emit(progress, "Lendo o áudio do vídeo…", 0.02)
    reference = align.decode(source, align.ANALYSIS_RATE, channels=1)[:, 0]
    mixdown = None
    for index, (path, _) in enumerate(tracks):
        _check(cancel)
        _emit(progress, f"Lendo a multitrack ({index + 1} de {len(tracks)})…", 0.05 + 0.25 * index / len(tracks))
        mono = align.decode(path, align.ANALYSIS_RATE, channels=1)[:, 0]
        mixdown = mono if mixdown is None else _add(mixdown, mono)
    _check(cancel)
    _emit(progress, "Procurando onde a multitrack cai no vídeo…", 0.32)
    found = align.align(reference, mixdown)
    if not found["confident"]:
        raise MediaError(
            f"A multitrack não bate com o áudio do vídeo: só {found['agreed']} de {found['windows']} trechos "
            "concordaram num mesmo deslocamento"
            + (f" e a velocidade difere {abs(found['speed'] - 1) * 100:.1f} %" if abs(found["speed"] - 1) > 0.02
               else "")
            + ". Deve ser outra gravação (um cover, uma versão ao vivo).")
    lag = round(found["offset"] * rate)
    gain = found["gain"]
    buckets: dict[str, np.ndarray] = {}
    for index, (path, key) in enumerate(tracks):
        _check(cancel)
        _emit(progress, f"Alinhando as faixas ({index + 1} de {len(tracks)})…", 0.4 + 0.45 * index / len(tracks))
        placed = align.place(align.decode(path, rate, channels=2, speed=found["speed"]), lag, frames)
        if key in buckets:
            buckets[key] += placed
        else:
            buckets[key] = placed
    output.mkdir(parents=True, exist_ok=True)
    files = {}
    for key, data in buckets.items():
        _check(cancel)
        files[key] = _write_stem(output / f"{key}.flac", (data * gain).T, rate)   # (canais, quadros)
    receipt = {"model": "multitrack", "version": PROCEDURE, "audioSHA256": sha256_file(source), "sampleRate": rate,
               "frames": frames, "duration": frames / rate, "device": None,
               "alignment": {key: found[key] for key in ("offset", "speed", "agreed", "windows", "strength", "gain")},
               "seconds": round(time.monotonic() - started, 3), "created": now_iso(), "stems": files,
               **(details or {})}
    atomic_json(output / "receipt.json", receipt)
    _emit(progress, "Faixas da multitrack prontas.", 1.0)
    return receipt


def _add(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Soma de dois sinais de tamanhos diferentes (as faixas de uma multitrack às vezes diferem no fim)."""
    if len(a) < len(b):
        a, b = b, a
    out = a.copy()
    out[:len(b)] += b
    return out


def _check(cancel) -> None:
    if cancel is not None:
        cancel.check()


def _emit(progress: Progress | None, message: str, fraction: float | None) -> None:
    if progress is not None:
        progress(STAGE, message, fraction)


__all__ = ["PROCEDURE", "assemble"]
