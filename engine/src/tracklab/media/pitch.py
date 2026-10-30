"""A altura que soa em cada nota da TAB: a curva do som (a cada 8 ms) que a Fita desenha pontilhada dentro da barra
da nota, como a Lente do TabLab (`web/lens-core.js`: `trackPitch`, `trackHarmonics`, `trackNote`, `smoothCurve`).

A busca é só em volta da altura escrita (de 2 semitons abaixo a 4 acima, para caber um bend): a correlação normalizada
da janela consigo mesma atrasada, a mais fina com uma corda só; quando ela se perde em mais da metade (outra corda
soando junto), a soma dos seis primeiros harmônicos de cada candidata, a cada 0,05 semitom. Pontos soltos saem
(mediana de 5; trechos com menos de 3 pontos seguidos viram vazio).
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np

from . import align

RATE = 22_050
HOP = 0.008
FLOOR = 1e-7            # potência média abaixo disto (−70 dBFS) é silêncio
CLARITY = 0.6
HARMONICS = 6
HARMONIC_STEP = 0.05
HARMONIC_CLARITY = 0.45
CHORD_CLARITY = 0.15
ATTACK_REACH = 0.12     # o ataque procurado até 120 ms antes ou depois do começo escrito
ATTACK_RISE = 6.0       # dB em 10 ms: menos que isso não é ataque (ligado, nota que já soava)
BELOW = 2.0             # semitons abaixo da altura escrita
ABOVE = 4.0             # e acima (um bend de 2 tons cabe)

_cache: dict[str, np.ndarray] = {}


def samples(path: Path) -> np.ndarray:
    """O áudio mono a 22 050 Hz, guardado na memória: os três últimos arquivos (a pista e a segunda pista da tela
    podem estar em faixas diferentes, a guitarra e o baixo, e pedem alternadas)."""
    key = str(path)
    if key in _cache:
        _cache[key] = _cache.pop(key)
    else:
        while len(_cache) >= 3:
            _cache.pop(next(iter(_cache)))
        _cache[key] = align.decode(path, RATE, channels=1)[:, 0].astype(np.float64)
    return _cache[key]


def frequency(midi: float) -> float:
    return 440.0 * 2 ** ((midi - 69) / 12)


def track_pitch(x: np.ndarray, rate: int, start: float, end: float, low: float, high: float) -> np.ndarray:
    """A altura (MIDI) a cada `HOP` de `start` a `end` pela correlação normalizada; NaN no silêncio ou no ruído."""
    shortest = max(2, int(rate / frequency(high)))
    longest = math.ceil(rate / frequency(low))
    size = max(math.ceil(2.5 * longest), round(0.012 * rate))
    count = max(0, int((end - start) / HOP + 1e-9) + 1)
    values = np.full(count, np.nan)
    lags = np.arange(shortest - 1, longest + 2)
    previous = math.nan
    for k in range(count):
        begin = round((start + k * HOP) * rate) - size // 2
        if begin < 0 or begin + size + longest + 1 >= len(x):
            previous = math.nan
            continue
        window = x[begin:begin + size]
        energy = float(window @ window)
        if energy / size < FLOOR:
            previous = math.nan
            continue
        segment = x[begin:begin + size + longest + 2]
        shifted = np.lib.stride_tricks.sliding_window_view(segment, size)[lags]
        cross = shifted @ window
        lagged = np.einsum("ij,ij->i", shifted, shifted)
        scores = cross / np.sqrt(energy * np.maximum(lagged, 1e-12))
        chosen, merit = -1, -math.inf
        for i in range(1, len(lags) - 1):
            score = scores[i]
            if score < CLARITY or score < scores[i - 1] or score < scores[i + 1]:
                continue
            pitch = 69 + 12 * math.log2(rate / lags[i] / 440)
            value = score - (0.15 * abs(pitch - previous) if math.isfinite(previous) else 0)
            if value > merit:
                merit, chosen = value, i
        if chosen < 0:
            previous = math.nan
            continue
        a, b, c = scores[chosen - 1], scores[chosen], scores[chosen + 1]
        curve = a - 2 * b + c
        shift = max(-0.5, min(0.5, 0.5 * (a - c) / curve)) if curve < 0 else 0.0
        values[k] = 69 + 12 * math.log2(rate / (lags[chosen] + shift) / 440)
        previous = values[k]
    return values


def track_harmonics(x: np.ndarray, rate: int, start: float, end: float, low: float, high: float,
                    others: tuple[float, ...] | list[float] = ()) -> np.ndarray:
    """A altura pelos harmônicos (quando outra corda soa junto e a correlação se perde). Com `others` (as outras
    notas do acorde), os harmônicos que caem a menos de 0,3 semitom de um harmônico delas não contam: são delas."""
    size = 2048 if frequency(low) < 165 else 1024
    padded = size * 4
    window = np.hanning(size)
    per_bin = padded / rate
    candidates = low + np.arange(round((high - low) / HARMONIC_STEP) + 1) * HARMONIC_STEP
    f0 = 440.0 * 2 ** ((candidates - 69) / 12)
    bins = f0[:, None] * np.arange(1, HARMONICS + 1)[None, :] * per_bin
    usable = bins * (1 / per_bin) < 0.45 * rate
    for other in others:
        theirs = frequency(other) * np.arange(1, 2 * HARMONICS + 1)
        near = np.abs(12 * np.log2((bins / per_bin)[:, :, None] / theirs[None, None, :])).min(axis=2) < 0.3
        usable &= ~near
    first_bin = max(1, int(frequency(low) * 0.8 * per_bin))
    last_bin = min(padded // 2 - 2, math.ceil(frequency(high) * (HARMONICS + 0.5) * per_bin))
    count = max(0, int((end - start) / HOP + 1e-9) + 1)
    values = np.full(count, np.nan)
    previous = math.nan
    for k in range(count):
        begin = round((start + k * HOP) * rate) - size // 2
        if begin < 0 or begin + size >= len(x):
            previous = math.nan
            continue
        frame = x[begin:begin + size]
        if float(frame @ frame) / size < FLOOR:
            previous = math.nan
            continue
        level = 10 * np.log10(np.abs(np.fft.rfft(frame * window, padded)) ** 2 + 1e-20)
        floor = float(np.median(level[first_bin:last_bin + 1:2]))
        at = np.interp(bins, np.arange(len(level)), level)
        scores = np.where(usable, np.maximum(0, at - floor), 0).sum(axis=1)
        middle = float(np.median(scores))
        chosen, merit = -1, -math.inf
        for c in range(1, len(scores) - 1):
            score = scores[c]
            if score < scores[c - 1] or score < scores[c + 1] or score <= 0:
                continue
            pitch = candidates[c]
            penalty = min(0.5, 0.12 * abs(pitch - previous)) if math.isfinite(previous) else 0
            if score * (1 - penalty) > merit:
                merit, chosen = score * (1 - penalty), c
        if chosen < 0:
            previous = math.nan
            continue
        best = scores[chosen]
        strong = max(at[chosen, 0], at[chosen, 1]) - floor >= 12
        # No acorde a janela é estreita (entre as vizinhas): quase todas as candidatas estão perto do pico e o vazamento
        # as levanta; a folga sobre a mediana fica menor.
        if (best - middle) / best < (CHORD_CLARITY if others else HARMONIC_CLARITY) or not strong:
            previous = math.nan
            continue
        a, c = scores[chosen - 1], scores[chosen + 1]
        curve = a - 2 * best + c
        shift = max(-0.5, min(0.5, 0.5 * (a - c) / curve)) if curve < 0 else 0.0
        values[k] = low + (chosen + shift) * HARMONIC_STEP
        previous = values[k]
    return values


def smooth(values: np.ndarray) -> np.ndarray:
    """Mediana de 5 entre os pontos válidos; trechos com menos de 3 pontos seguidos viram NaN."""
    n = len(values)
    out = np.full(n, np.nan)
    for i in range(n):
        if math.isfinite(values[i]):
            near = values[max(0, i - 2):i + 3]
            out[i] = float(np.median(near[np.isfinite(near)]))
    run = 0
    for i in range(n + 1):
        if i < n and math.isfinite(out[i]):
            run += 1
            continue
        if 0 < run < 3:
            out[i - run:i] = np.nan
        run = 0
    return out


def attack(x: np.ndarray, start: float, rate: int = RATE) -> float | None:
    """Quando a nota soa de fato: a maior subida de energia (em 10 ms, do sinal sem os graves, onde a palhetada
    aparece) até `ATTACK_REACH` antes ou depois de `start`; None sem uma subida clara (ligado, slide, nota já soando).
    A diferença para o começo escrito diz se o mapa de tempo está adiantado ou atrasado ali."""
    hop, size, lag = int(0.0025 * rate), int(0.01 * rate), 4
    first = max(0, int((start - ATTACK_REACH) * rate) - (lag + 1) * hop - size)
    last = min(len(x), int((start + ATTACK_REACH) * rate) + size)
    if last - first < size * 4:
        return None
    edge = np.diff(x[first:last])
    count = (len(edge) - size) // hop + 1
    if count <= lag:
        return None
    frames = np.lib.stride_tricks.sliding_window_view(edge, size)[::hop][:count]
    level = 10 * np.log10(np.mean(frames * frames, axis=1) + 1e-12)
    rise = level[lag:] - level[:-lag]
    # A janela que acaba de entrar no ataque: o começo dela é o instante da subida.
    times = first / rate + (np.arange(lag, count) * hop + size) / rate - 0.005
    inside = np.abs(times - start) <= ATTACK_REACH
    if not inside.any():
        return None
    best = int(np.argmax(np.where(inside, rise, -np.inf)))
    return round(float(times[best]), 4) if rise[best] >= ATTACK_RISE else None


def note_curve(x: np.ndarray, start: float, end: float, pitch: float, rate: int = RATE,
               others: tuple[float, ...] | list[float] = ()) -> dict:
    """A curva de uma nota: a correlação; se ela tem menos da metade dos pontos, os harmônicos, se acham mais.

    `others`: as outras notas da pista na mesma batida (um acorde, um double stop). A busca fica entre elas, até meio
    semitom antes da vizinha de baixo e da de cima: sem isso, com as duas cordas no mesmo volume, a curva caía entre as
    duas ou pulava de uma para a outra."""
    low, high = pitch - BELOW, pitch + ABOVE
    for other in others:
        if other < pitch:
            low = max(low, other + 0.5)
        elif other > pitch:
            high = min(high, other - 0.5)
    if others:
        # Num acorde a correlação acha o período comum das cordas (uma altura entre elas): só os harmônicos.
        values = smooth(track_harmonics(x, rate, start, end, low, high, others))
        return {"from": start, "hop": HOP, "attack": attack(x, start, rate),
                "values": [None if not math.isfinite(v) else round(float(v), 3) for v in values]}
    first = track_pitch(x, rate, start, end, low, high)
    share = lambda v: float(np.isfinite(v).mean()) if len(v) else 0.0  # noqa: E731
    values = first
    if share(first) < 0.5:
        second = track_harmonics(x, rate, start, end, low, high)
        if share(second) > share(first):
            values = second
    values = smooth(values)
    return {"from": start, "hop": HOP, "attack": attack(x, start, rate),
            "values": [None if not math.isfinite(v) else round(float(v), 3) for v in values]}


__all__ = ["HOP", "RATE", "attack", "note_curve", "samples", "smooth", "track_harmonics", "track_pitch"]
