"""Os sons de uma faixa, para as suspeitas do app ("som sem nota escrita"): os ataques fortes e a altura de cada um,
lidos no espectro da Fita (`spectrum.compute`, linhas de 1/3 de semitom a cada 11,6 ms).

Onde o espectro sobe de repente (o fluxo espectral: a soma das subidas em dB entre um quadro e o seguinte) há um
ataque, se passa de um limiar que acompanha a música (a mediana de ±0,5 s mais 2 desvios). Logo depois do ataque
(de 23 a 58 ms), a altura é a que mais soma com os harmônicos (até o 5º, com peso menor a cada um), exigindo energia na
fundamental (assim uma nota não vira a oitava de baixo); um segundo som no mesmo ataque entra se for forte e não for
harmônico do primeiro. Sons fracos perto do mais forte em ±2 s (vazamento de outro instrumento) ficam de fora. O app
compara com as notas escritas.
"""

from __future__ import annotations

import numpy as np

VERSION = 1
LOWEST = 40              # Mi 2: a corda solta mais grave da guitarra
HIGHEST = 88             # Mi 6: a casa 24 da corda mais aguda
WEIGHTS = (1.0, 0.8, 0.6, 0.5, 0.4)
GAP = 0.06               # segundos entre dois ataques
FUNDAMENTAL_DB = 12.0    # a fundamental precisa passar disso acima do fundo do quadro
BELOW_TOP_DB = 30.0      # um som a mais que isso abaixo do mais forte em ±2 s é vazamento
FLUX_FROM = 60           # o fluxo só nas linhas da FFT curta (a de 2048, do Dó central para cima): o ataque no tempo
LATE = 0.024             # o ataque aparece meia janela curta antes (a janela é centrada): tanto mais tarde


def detect(data: np.ndarray, hop: float, low: int, per_semitone: int) -> list[list[float]]:
    """Os sons de um espectro (`data`: quadros × linhas, uint8 de −90 a 0 dB; a linha 0 é a altura `low`): uma lista
    de `[segundo, altura MIDI, dB, dB abaixo do mais forte em ±2 s]`, em ordem de tempo."""
    if data.size == 0 or len(data) < 8:
        return []
    db = data.astype(np.float32) * (90.0 / 255.0) - 90.0
    level = np.maximum(db[:, max(0, _row(FLUX_FROM, low, per_semitone)):], -70.0)
    flux = np.maximum(np.diff(level, axis=0, prepend=level[:1]), 0).sum(axis=1)
    flux = np.convolve(flux, np.ones(3, dtype=np.float32) / 3, mode="same")
    half = max(1, int(round(0.5 / hop)))
    padded = np.pad(flux, (half, half), mode="edge")
    windows = np.lib.stride_tricks.sliding_window_view(padded, 2 * half + 1)
    median = np.median(windows, axis=1)
    spread = np.median(np.abs(windows - median[:, None]), axis=1)
    threshold = median + 2.0 * spread + 1e-3 * flux.max()
    gap = max(1, int(round(GAP / hop)))
    onsets: list[int] = []
    for f in range(1, len(flux) - 1):
        if flux[f] <= threshold[f] or flux[f] < flux[f - 1] or flux[f] < flux[f + 1]:
            continue
        if onsets and f - onsets[-1] < gap:
            if flux[f] > flux[onsets[-1]]:
                onsets[-1] = f
            continue
        onsets.append(f)

    top_window = max(1, int(round(2.0 / hop)))
    frame_top = db.max(axis=1)
    out: list[list[float]] = []
    rows = db.shape[1]
    late = int(round(LATE / hop))
    for f in onsets:
        a, b = f + late + 2, min(len(db), f + late + 6)
        if b <= a:
            continue
        spectrum = db[a:b].mean(axis=0)
        floor = float(np.median(spectrum))
        above = np.maximum(spectrum - floor, 0.0)
        # Um pouco de folga em volta de cada linha (a gravação pode estar fora do Lá 440).
        loose = np.maximum.reduce([above, np.roll(above, 1), np.roll(above, -1)])
        found = _pitches(loose, above, low, per_semitone, rows)
        local_top = float(frame_top[max(0, f - top_window): f + top_window].max())
        for midi in found:
            strength = float(spectrum[_row(midi, low, per_semitone)])
            if strength < local_top - BELOW_TOP_DB:
                continue
            out.append([round(f * hop + LATE, 4), midi, round(strength, 1), round(strength - local_top, 1)])
    return out


def _row(midi: float, low: int, per_semitone: int) -> int:
    return int(round((midi - low) * per_semitone))


def _salience(loose: np.ndarray, midi: int, low: int, per_semitone: int, rows: int) -> float:
    total = 0.0
    for h, weight in enumerate(WEIGHTS, start=1):
        row = _row(midi + 12 * np.log2(h), low, per_semitone)
        if row < rows:
            total += weight * float(loose[row])
    return total


def _pitches(loose: np.ndarray, above: np.ndarray, low: int, per_semitone: int, rows: int) -> list[int]:
    """A altura mais forte (e uma segunda, forte e fora dos harmônicos da primeira), com energia na fundamental."""
    candidates = [m for m in range(LOWEST, HIGHEST + 1) if _row(m, low, per_semitone) < rows]
    def peak(m: int) -> bool:
        # A fundamental com energia e acima das vizinhas a um semitom (não o vazamento de uma nota ao lado).
        row = _row(m, low, per_semitone)
        side = [above[r] for r in (row - per_semitone, row + per_semitone) if 0 <= r < rows]
        return above[row] >= FUNDAMENTAL_DB and all(above[row] >= v for v in side)
    scored = sorted(((_salience(loose, m, low, per_semitone, rows), m) for m in candidates if peak(m)), reverse=True)
    if not scored:
        return []
    best_score, best = scored[0]
    found = [best]
    harmonics = {best + round(12 * np.log2(h)) for h in range(1, 7)} | {best - 12}
    for score, midi in scored[1:]:
        if score < 0.7 * best_score:
            break
        if all(abs(midi - h) > 1 for h in harmonics):
            found.append(midi)
            break
    return found


__all__ = ["VERSION", "detect"]
