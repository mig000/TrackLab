"""As notas de um trecho do som, para a seleção no espectro do app (um retângulo de tempo × altura na Lente): a altura a
cada 8 ms só dentro da faixa do retângulo (a correlação de `pitch.track_pitch`; onde ela não acha, os harmônicos de
`pitch.track_harmonics`), cortada em notas onde o som some, onde a altura salta e fica (ligado, outra casa) e onde a
mesma nota é atacada de novo (a energia nos harmônicos dela cai e volta de repente).

Um buraco curto na mesma altura é emendado (o rastreador perde a nota quando outra corda ataca), e um salto de um a
três quadros que volta é ignorado. Um movimento grande que anda de casa em casa (degraus de quase um semitom, com
patamares curtos no meio) é slide: a nota de chegada começa onde ele termina e diz que veio por slide (`slide`:
"previous", da nota anterior; "below" ou "above", de fora, quando o som já começa deslizando). Um movimento liso fica
dentro da nota (bend, vibrato): o app o lê pela curva. Medido no Sultans of Swing: o slide do c. 105 sobe 3 semitons em
110 ms, em degraus de 0,4 a 0,8 com patamares de 30 ms; o bend do c. 77 sobe 1,3 semitom em 150 ms, de 0,1 a 0,2 por
quadro.
"""

from __future__ import annotations

import math

import numpy as np

from . import pitch

HOP = pitch.HOP
MIN_NOTE = 0.04       # s: menos que isso não é nota
BRIDGE = 8            # quadros sem altura emendados quando a altura dos dois lados é a mesma (meio semitom)
GLITCH = 3            # quadros de um salto que volta (e é ignorado)
STEP = 0.75           # semitons de um quadro para o seguinte: outra nota, se a altura nova fica
SLIDE_RISE = 1.5      # semitons que um slide anda, no mínimo
SLIDE_STEP = 0.35     # um quadro que anda isso ou mais é um degrau (a casa trocando)
SLIDE_STEPPY = 0.5    # a fração do movimento feita em degraus para ser slide (um bend anda liso)
SLIDE_PAUSE = 5       # quadros parados que ainda são o mesmo slide (o patamar numa casa do caminho)
SLIDE_HOLD = 0.06     # s que o som fica na chegada do slide
REATTACK_DB = 6.0     # dB que a energia da nota volta depois de cair: ataque de novo
SETTLE = 0.05         # s depois do começo da nota em que um ataque de novo ainda é o próprio ataque
EDGE = 0.2            # semitons da borda da faixa: o que fica ali é outra nota puxada para dentro
JOIN = 0.2            # s de buraco entre dois pedaços da mesma altura que ainda são a mesma nota (sem ataque de novo)


def track(x: np.ndarray, start: float, end: float, low: float, high: float, rate: int = pitch.RATE) -> np.ndarray:
    """A altura a cada `HOP` de `start` a `end`, buscada só de `low` a `high`; NaN onde não há."""
    first = pitch.track_pitch(x, rate, start, end, low, high)
    # Numa faixa estreita quase todas as candidatas ficam perto do pico: a folga é a do acorde.
    second = pitch.track_harmonics(x, rate, start, end, low, high, narrow=high - low < 8)
    values = np.where(np.isfinite(first), first, second)
    # Colado na borda da faixa é outra nota, de fora, puxada para dentro (no c. 106 do Sultans, o Fá 4 da base com o
    # retângulo do Lá 4 do solo um pouco abaixo do Fá♯): fora.
    values[(values < low + EDGE) | (values > high - EDGE)] = np.nan
    return pitch.smooth(values)


def harmonic_level(x: np.ndarray, times: np.ndarray, values: np.ndarray, rate: int = pitch.RATE) -> np.ndarray:
    """A energia (dB) nos três primeiros harmônicos da altura de cada quadro; NaN sem altura."""
    size = 1024
    window = np.hanning(size)
    out = np.full(len(values), np.nan)
    for k, (t, v) in enumerate(zip(times, values)):
        if not math.isfinite(v):
            continue
        begin = round(t * rate) - size // 2
        if begin < 0 or begin + size >= len(x):
            continue
        spectrum = np.abs(np.fft.rfft(x[begin:begin + size] * window))
        f0 = pitch.frequency(v)
        bins = [round(h * f0 * size / rate) for h in (1, 2, 3)]
        energy = sum(float(spectrum[max(0, b - 1):b + 2].max() ** 2) for b in bins if b + 1 < len(spectrum))
        out[k] = 10 * math.log10(energy + 1e-12)
    return out


def fill(values: np.ndarray) -> np.ndarray:
    """A altura sem os buracos curtos na mesma altura (interpolados) e sem os saltos de até `GLITCH` quadros que voltam
    para onde estavam."""
    v = values.copy()
    n = len(v)
    # Os saltos que voltam (contando de um lado ao outro de um buraco curto): a altura segue a de antes.
    valid = [k for k in range(n) if math.isfinite(v[k])]
    i = 1
    while i < len(valid):
        p, k = valid[i - 1], valid[i]
        if k - p <= BRIDGE + 1 and abs(v[k] - v[p]) >= STEP:
            ahead = [j for j in valid[i + 1:i + 1 + GLITCH] if j - k < GLITCH + BRIDGE]
            back = next((j for j in ahead if abs(v[j] - v[p]) <= 0.5), None)
            if back is not None:
                v[p + 1:back] = np.interp(np.arange(p + 1, back), [p, back], [v[p], v[back]])
                i = valid.index(back)
        i += 1
    valid = [k for k in range(n) if math.isfinite(v[k])]
    for a, b in zip(valid, valid[1:]):
        if 1 < b - a <= BRIDGE + 1 and abs(v[b] - v[a]) <= 0.5:
            v[a + 1:b] = np.interp(np.arange(a + 1, b), [a, b], [v[a], v[b]])
    return v


def _glide(v: np.ndarray, at: int) -> tuple[int, int] | None:
    """O slide que passa pelo quadro `at` (um degrau): o movimento numa direção só em volta dele, com patamares curtos
    (as casas do caminho), de pelo menos `SLIDE_RISE` semitons, a maior parte em degraus, passando por alturas do meio
    e parando na chegada. Devolve os quadros de onde ele sai e onde chega, ou None."""
    sign = 1 if v[at] > v[at - 1] else -1
    moving = lambda k: math.isfinite(v[k]) and math.isfinite(v[k - 1]) and sign * (v[k] - v[k - 1]) >= 0.1  # noqa: E731
    reverse = lambda k: not math.isfinite(v[k]) or not math.isfinite(v[k - 1]) or sign * (v[k] - v[k - 1]) < -0.15  # noqa: E731
    first = at
    k = at - 1
    while k > 0 and not reverse(k) and first - k <= SLIDE_PAUSE:
        if moving(k):
            first = k
        k -= 1
    last = at
    k = at + 1
    while k < len(v) and not reverse(k) and k - last <= SLIDE_PAUSE:
        if moving(k):
            last = k
        k += 1
    a, b = first - 1, last
    rise = sign * (v[b] - v[a])
    if rise < SLIDE_RISE:
        return None
    steppy = sum(sign * (v[k] - v[k - 1]) for k in range(a + 1, b + 1) if sign * (v[k] - v[k - 1]) >= SLIDE_STEP)
    low, high = min(v[a], v[b]), max(v[a], v[b])
    between = [k for k in range(a + 1, b) if low + 0.4 < v[k] < high - 0.4]
    if steppy < SLIDE_STEPPY * rise or len(between) < 2:
        return None
    # A chegada segura: o som fica a meio semitom dela por `SLIDE_HOLD`.
    hold = 0
    for k in range(b, len(v)):
        if not math.isfinite(v[k]) or abs(v[k] - v[b]) > 0.5:
            break
        hold = k - b + 1
    if hold * HOP < SLIDE_HOLD:
        return None
    return a, b


def notes(x: np.ndarray, start: float, end: float, low: float, high: float, rate: int = pitch.RATE) -> list[dict]:
    """As notas de `start` a `end` com altura de `low` a `high` (MIDI): `[{start, end, level, slide, curve: {from, hop,
    values}}]`, em ordem de tempo. `level` é a altura do começo (a mediana dos primeiros 40 ms, sem a afinação descontada:
    o app a desconta e escolhe a casa); `slide` diz se a nota chega por slide ("previous", "below", "above") ou None."""
    raw = track(x, start, end, low, high, rate)
    v = fill(raw)
    n = len(v)
    times = start + np.arange(n) * HOP
    level = harmonic_level(x, times, v, rate)
    # (primeiro quadro, último quadro, slide: "previous below" guarda de onde veio, se a anterior não ficar)
    cuts: list[tuple[int, int, str | None]] = []
    begin: int | None = None
    slide: str | None = None
    k = 0
    while k < n:
        if not math.isfinite(v[k]):
            if begin is not None:
                cuts.append((begin, k - 1, slide))
                begin, slide = None, None
            k += 1
            continue
        if begin is None:
            begin = k
            k += 1
            continue
        jump = abs(v[k] - v[k - 1])
        glide = _glide(v, k) if jump >= SLIDE_STEP else None
        if glide:
            a, b = glide
            outside = "below" if v[b] > v[a] else "above"
            if a - begin < 2:
                # O som já começa deslizando: um slide de fora até a nota.
                slide = outside
            else:
                cuts.append((begin, b - 1, slide))
                slide = "previous " + outside
            begin = b
            k = b + 1
            continue
        if jump >= STEP:
            cuts.append((begin, k - 1, slide))
            begin, slide = k, None
        elif times[k] - times[begin] >= SETTLE and math.isfinite(level[k]) and math.isfinite(level[k - 1]):
            # A mesma nota atacada de novo: a energia nos harmônicos dela cai e volta de repente.
            before = level[max(begin, k - 6):k]
            before = before[np.isfinite(before)]
            if len(before) and level[k] - before.min() >= REATTACK_DB and level[k] - level[k - 1] >= 3:
                cuts.append((begin, k - 1, slide))
                begin, slide = k, None
        k += 1
    if begin is not None:
        cuts.append((begin, n - 1, slide))
    # Dois pedaços da mesma altura com um buraco de até `JOIN` no meio (o rastreador perdeu a nota quando outra corda
    # atacou) são a mesma nota, se a energia dela não volta mais forte depois do buraco (um ataque de novo).
    def edge(a: int, b: int) -> float:
        own = level[a:b + 1]
        own = own[np.isfinite(own)]
        return float(np.mean(own)) if len(own) else -math.inf

    joined: list[tuple[int, int, str | None]] = []
    for a, b, slide in cuts:
        if joined and slide is None:
            pa, pb, ps = joined[-1]
            gap = (a - pb - 1) * HOP
            same = abs(np.nanmedian(v[max(pa, pb - 4):pb + 1]) - np.nanmedian(v[a:a + 5])) <= 0.5
            if gap <= JOIN and same and edge(a, a + 2) - edge(pb - 2, pb) < REATTACK_DB:
                joined[-1] = (pa, b, ps)
                continue
        joined.append((a, b, slide))
    out: list[dict] = []
    for a, b, slide in joined:
        t0, t1 = float(times[a]), float(times[b] + HOP)
        if t1 - t0 < MIN_NOTE:
            continue
        if slide and slide.startswith("previous"):
            # Sem a anterior logo antes (curta demais, ou um buraco), o slide vem de fora.
            slide = "previous" if out and t0 - out[-1]["end"] <= 2 * HOP else slide.split()[1]
        # A altura do começo: os primeiros 40 ms (um bend que sai logo não a puxa para cima).
        head = v[a:min(b + 1, a + 5)]
        out.append({
            "start": round(t0, 4), "end": round(t1, 4), "level": round(float(np.nanmedian(head)), 3), "slide": slide,
            "curve": {"from": round(t0, 4), "hop": HOP,
                      "values": [None if not math.isfinite(r) else round(float(r), 3) for r in raw[a:b + 1]]},
        })
    return out


__all__ = ["fill", "notes", "track"]
