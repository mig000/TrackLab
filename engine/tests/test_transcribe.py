"""As notas de um trecho do som (a seleção no espectro): a nota limpa, o ligado, o slide que anda de casa em casa, o bend
que sobe liso, a mesma nota atacada de novo e o buraco do rastreador no meio de uma nota."""

import numpy as np
import pytest

from test_pitch import tone
from tracklab.media import pitch, transcribe

RATE = pitch.RATE


def envelope(seconds, attacks, decay=3.0):
    """O volume de uma corda palhetada em `attacks` (s): sobe em 5 ms e cai devagar."""
    t = np.arange(int(seconds * RATE)) / RATE
    out = np.zeros_like(t)
    for a in attacks:
        after = t - a
        out = np.where(after >= 0, np.minimum(1, after / 0.005) * np.exp(-decay * after), out)
    return out


def found(x, low, high, start=0.05, end=None):
    return transcribe.notes(x, start, end or len(x) / RATE - 0.05, low, high)


def test_a_clean_note_is_one_note_at_its_pitch():
    notes = found(tone(lambda t: 64.0), 62, 67)
    assert len(notes) == 1 and notes[0]["level"] == pytest.approx(64, abs=0.1) and notes[0]["slide"] is None


def test_a_legato_step_makes_two_notes():
    notes = found(tone(lambda t: 64.0 if t < 0.5 else 66.0), 62, 68)
    assert [round(n["level"]) for n in notes] == [64, 66]
    assert notes[1]["start"] == pytest.approx(0.5, abs=0.03) and notes[1]["slide"] is None


def test_a_slide_walks_fret_by_fret_and_the_arrival_says_so():
    # 66 → 69 em 110 ms, de casa em casa (degraus com patamares de 25 ms), e segura.
    def midi(t):
        if t < 0.3:
            return 66.0
        k = min(3, int((t - 0.3) / 0.0275))
        return 66.0 + k
    notes = found(tone(midi), 64, 71)
    assert [round(n["level"]) for n in notes] == [66, 69]
    assert notes[1]["slide"] == "previous"


def test_a_smooth_bend_stays_inside_the_note():
    notes = found(tone(lambda t: 64.0 + min(1.0, max(0.0, (t - 0.3) / 0.15)) * 2.0), 62, 68)
    assert len(notes) == 1 and round(notes[0]["level"]) == 64
    values = [v for v in notes[0]["curve"]["values"] if v is not None]
    assert max(values) == pytest.approx(66, abs=0.2)


def test_the_same_note_picked_again_is_two_notes():
    x = tone(lambda t: 64.0, seconds=1.2) * envelope(1.2, [0.02, 0.6], decay=6)
    notes = found(x, 62, 67, start=0.0)
    assert len(notes) == 2 and notes[1]["start"] == pytest.approx(0.6, abs=0.04)


def test_a_short_dropout_in_a_held_note_is_bridged():
    # Outra coisa soando forte por 40 ms (o ataque de outra corda): o rastreador perde a nota, e ela continua uma só.
    x = tone(lambda t: 64.0)
    burst = slice(int(0.5 * RATE), int(0.54 * RATE))
    x[burst] += np.random.default_rng(1).normal(0, 0.6, burst.stop - burst.start)
    notes = found(x, 62, 67)
    assert len(notes) == 1


def test_only_the_band_counts():
    # Duas cordas: a seleção em volta de uma só acha a dela.
    x = tone(lambda t: 64.0) + tone(lambda t: 71.0)
    notes = found(x, 69.5, 72.5)
    assert notes and all(round(n["level"]) == 71 for n in notes)
