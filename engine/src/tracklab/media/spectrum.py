"""O espectro da Fita: o áudio em linhas de altura (1/3 de semitom, do Mi 1 do baixo ao Dó 7) ao longo do tempo, a
receita da Lente do TabLab (`web/lens-core.js`, `Spectrum`) calculada aqui de uma vez e guardada no pacote.

Mono a 22 050 Hz, janela de Hann, um quadro a cada 256 amostras (11,6 ms); FFT de 4096 abaixo do Dó central (onde
as notas são próximas) e de 2048 acima (onde o ataque importa mais). Cada linha é, como na Lente, o valor no centro dela
(interpolado entre as duas raias vizinhas) ou o maior das raias que caem dentro de ±1/6 de semitom; a intensidade vai de
−90 a 0 dB num byte. A versão 1 arredondava a faixa de raias para fora: nos graves cada linha pegava a raia de baixo e a
energia de uma nota subia até um semitom na imagem. O app desenha como imagem, na escala da Fita, com as notas
da TAB por cima como barras.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from . import align

RATE = 22_050
HOP = 256
LOW = 28                # Mi 1 (a corda solta mais grave do baixo)
HIGH = 96               # Dó 7
PER_SEMITONE = 3
SPLIT = 60              # abaixo do Dó central, a FFT longa
SIZES = (4096, 2048)
FLOOR_DB = -90.0
CHUNK = 1024            # quadros por vez: memória constante numa música longa
VERSION = 2             # no nome do arquivo guardado: uma receita nova refaz o espectro


def rows() -> int:
    return (HIGH - LOW) * PER_SEMITONE + 1


def compute(path: Path) -> dict:
    """O espectro de `path`: `data` (quadros × linhas, uint8, a linha 0 é a altura LOW) e o que o app precisa para
    desenhar (quadros, linhas, segundos por quadro, a altura da linha 0 e linhas por semitom)."""
    signal = align.decode(path, RATE, channels=1)[:, 0].astype(np.float32)
    count = max(1, int(np.ceil(len(signal) / HOP)))
    pitches = LOW + np.arange(rows()) / PER_SEMITONE
    out = np.zeros((count, rows()), dtype=np.uint8)
    for size in SIZES:
        chosen = np.flatnonzero(pitches < SPLIT) if size == SIZES[0] else np.flatnonzero(pitches >= SPLIT)
        if not len(chosen):
            continue
        centers, inside = _bins(pitches[chosen], size)
        lower = np.floor(centers).astype(int)
        fraction = (centers - lower).astype(np.float32)
        window = np.hanning(size).astype(np.float32)
        reference = window.sum() / 2      # uma senoide de amplitude 1 dá 0 dB
        padded = np.pad(signal, (size // 2, size // 2 + HOP))
        for first in range(0, count, CHUNK):
            last = min(count, first + CHUNK)
            starts = np.arange(first, last) * HOP
            frames = np.lib.stride_tricks.sliding_window_view(padded, size)[starts]
            magnitude = np.abs(np.fft.rfft(frames * window, axis=1)) / reference
            band = magnitude[:, lower] * (1 - fraction) + magnitude[:, lower + 1] * fraction
            for column, (lo, hi) in enumerate(inside):
                if hi > lo:
                    band[:, column] = np.maximum(band[:, column], magnitude[:, lo:hi].max(axis=1))
            decibels = 20 * np.log10(np.maximum(band, 1e-9))
            out[first:last, chosen] = np.round((np.clip(decibels, FLOOR_DB, 0) - FLOOR_DB) / -FLOOR_DB * 255)
    return {"frames": count, "rows": rows(), "hop": HOP / RATE, "low": LOW, "perSemitone": PER_SEMITONE,
            "data": out}


def _bins(pitches: np.ndarray, size: int) -> tuple[np.ndarray, list[tuple[int, int]]]:
    """A raia (fracionária) do centro de cada linha e as raias inteiras dentro de ±1/6 de semitom dela (`lens-core.js`,
    `rowPlan`: de `ceil(from)` a `floor(to)`, às vezes nenhuma)."""
    def bin_of(midi):
        return 440 * 2 ** ((midi - 69) / 12) * size / RATE
    top = size // 2
    centers = np.minimum(bin_of(pitches), top - 1)
    inside = []
    for pitch in pitches:
        lo = int(np.ceil(bin_of(pitch - 1 / 6)))
        hi = min(int(np.floor(bin_of(pitch + 1 / 6))), top) + 1
        inside.append((lo, max(lo, hi)))
    return centers, inside


__all__ = ["HOP", "LOW", "PER_SEMITONE", "RATE", "VERSION", "compute", "rows"]
