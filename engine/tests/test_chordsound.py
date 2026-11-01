"""Os acordes pelo som (media/chordsound.py): o HMM do Chord-CNN-LSTM sobre probabilidades feitas à mão, as batidas e
o endpoint que guarda as probabilidades (sem as redes, que o teste não baixa)."""

import numpy as np

from tracklab.media import chordsound

FRAME = chordsound.HOP / chordsound.RATE


def probs(*segments):
    """Probabilidades com um acorde maior forte em cada trecho (`(quadros, fundamental)`) e o baixo nele."""
    rows = []
    for frames, root in segments:
        for _ in range(frames):
            row = np.full(sum(chordsound.WIDTHS), 1e-4, dtype=np.float32)
            row[1 + root] = 0.9            # a tríade maior da fundamental (o índice 1 + 12·(tipo − 1) + fundamental)
            row[73 + 1 + root] = 0.9       # o baixo nela (o índice 0 é "sem baixo")
            row[73 + 13] = 0.9             # sem sétima, sem nona, sem décima primeira, sem décima terceira
            row[73 + 13 + 4] = 0.9
            row[73 + 13 + 8] = 0.9
            row[73 + 13 + 11] = 0.9
            rows.append(row)
    return np.array(rows)


def named(rows):
    """Os acordes sem o "sem acorde" do começo (o HMM do original sempre parte dele, no primeiro quadro)."""
    return [row for row in rows if row[2] != "N" or row[0] > 0]


def test_the_hmm_names_the_chords():
    rows = named(chordsound.decode(probs((100, 0), (100, 7))))
    assert [row[2] for row in rows] == ["C:maj", "G:maj"]
    assert abs(rows[1][0] - 100 * FRAME) < 1e-3


def test_with_beats_the_change_falls_on_a_beat():
    # A troca no som cai no quadro 100; a batida mais perto, no 110 (um 1 de compasso), e entre batidas não se troca.
    beats = [(f * FRAME, kind) for f, kind in [(0, 2), (40, 4), (80, 4), (110, 2), (150, 4)]]
    rows = named(chordsound.decode(probs((100, 0), (100, 7)), beats))
    assert [row[2] for row in rows] == ["C:maj", "G:maj"]
    assert abs(rows[1][0] - 110 * FRAME) < 1e-3 or abs(rows[1][0] - 80 * FRAME) < 1e-3


def test_beat_frames_marks_each_kind():
    arr = chordsound.beat_frames(20, [(0, 2), (2 * FRAME, 2), (6 * FRAME, 4), (10 * FRAME, 3), (14 * FRAME, 4)])
    assert list(arr[:3]) == [1, 1, 2] and arr[6] == 4 and arr[10] == 3 and arr[14] == 4
    assert arr[3:6].sum() == 0 and list(arr[15:]) == [1] * 5
