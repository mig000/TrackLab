"""Envelope de mínimos e máximos por janela: é o que a linha do tempo do app desenha."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import soundfile

from tracklab.errors import MediaError

WINDOWS_PER_BLOCK = 2000   # 10 s a 200/s: memória constante em arquivos de 30 min


def peaks(path: Path, per_second: int = 200) -> dict:
    """Mínimo e máximo do áudio misturado em mono, `per_second` janelas por segundo, arredondados a 4 casas."""
    path = Path(path)
    try:
        sound = soundfile.SoundFile(str(path))
    except RuntimeError as exc:
        raise MediaError(f"Não consegui ler {path.name} para desenhar a forma de onda.") from exc
    with sound:
        rate, frames = sound.samplerate, sound.frames
        if type(per_second) is not int or not 1 <= per_second <= rate:
            raise MediaError(f"Resolução de forma de onda inválida: {per_second} por segundo.")
        # Janela k cobre [k·rate/per_second, (k+1)·rate/per_second): 44 100/200 não é inteiro.
        count = -(-frames * per_second // rate)
        lows: list[np.ndarray] = []
        highs: list[np.ndarray] = []
        for first in range(0, count, WINDOWS_PER_BLOCK):
            last = min(first + WINDOWS_PER_BLOCK, count)
            bounds = np.minimum(np.arange(first, last + 1, dtype=np.int64) * rate // per_second, frames)
            wanted = int(bounds[-1] - bounds[0])
            block = sound.read(wanted, dtype="float32", always_2d=True)
            if len(block) < wanted:
                raise MediaError(f"{path.name} terminou antes do tamanho que o cabeçalho anuncia.")
            mono = block.mean(axis=1)
            starts = bounds[:-1] - bounds[0]
            lows.append(np.minimum.reduceat(mono, starts))
            highs.append(np.maximum.reduceat(mono, starts))
    return {"perSecond": per_second, "channels": 1, "min": _rounded(lows), "max": _rounded(highs)}


def _rounded(parts: list[np.ndarray]) -> list[float]:
    if not parts:
        return []
    # Somar 0.0 troca -0.0 por 0.0, que fica mais limpo no JSON.
    return (np.round(np.concatenate(parts).astype(np.float64), 4) + 0.0).tolist()
