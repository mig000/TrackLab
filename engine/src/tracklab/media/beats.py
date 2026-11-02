"""O tempo ouvido de uma faixa, para o Ajuste: a força dos ataques ao longo da música e as batidas que um detector acha
nela, a segunda opinião contra o mapa de tempo.

A força é a do librosa (`onset_strength`: o fluxo espectral em escala mel, só o que sobe) num quadro a cada 128
amostras a 22 050 Hz (5,8 ms), adiantada dois quadros (ela chega 11,6 ms depois do ataque: a diferença entre quadros
e a janela centrada; sem isso as batidas achadas ficavam 18 ms atrasadas num bumbo de teste, e assim ficam a 4 ms),
normalizada pelo percentil 99 e guardada num byte por quadro. As batidas são as do
`beat_track` do librosa sobre essa força, começando pelo andamento do mapa (`bpm`): sem ele o detector cai no dobro
ou na metade com facilidade. Na bateria da multitrack (ou do Demucs) os ataques são o bumbo, a caixa e os pratos; sem
bateria, o baixo, ou o original.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from . import align

RATE = 22_050
HOP = 128
LAG = 2      # quadros que a força chega depois do ataque
VERSION = 1   # no nome do arquivo guardado: uma receita nova refaz a análise


def analyse(path: Path, bpm: float | None = None) -> dict:
    """A força dos ataques (`envelope`, um byte por quadro, `rate` quadros por segundo) e as batidas detectadas
    (`beats`, em segundos) da faixa em `path`; `tempo` é o andamento que o detector achou."""
    signal = align.decode(path, RATE, channels=1)[:, 0].astype(np.float32)
    return analyse_signal(signal, bpm)


def analyse_signal(signal: np.ndarray, bpm: float | None = None) -> dict:
    import librosa

    strength = librosa.onset.onset_strength(y=signal, sr=RATE, hop_length=HOP)
    strength = np.concatenate([strength[LAG:], np.zeros(min(LAG, len(strength)), dtype=strength.dtype)])
    top = float(np.percentile(strength, 99)) if strength.size else 0.0
    scaled = np.clip(strength / top, 0, 1) if top > 0 else np.zeros_like(strength)
    start = float(bpm) if bpm and 30 <= bpm <= 300 else 120.0
    tempo, beats = librosa.beat.beat_track(onset_envelope=strength, sr=RATE, hop_length=HOP, start_bpm=start,
                                           tightness=100, trim=False, units="time")
    return {"rate": RATE / HOP, "envelope": (scaled * 255).round().astype(np.uint8).tolist(),
            "beats": [round(float(b), 4) for b in np.atleast_1d(beats)],
            "tempo": round(float(np.atleast_1d(tempo)[0]), 2), "version": VERSION}


__all__ = ["HOP", "LAG", "RATE", "VERSION", "analyse", "analyse_signal"]
