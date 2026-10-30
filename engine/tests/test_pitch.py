"""A curva de altura do som numa nota: a nota limpa, o bend que sobe, o acorde (pelos harmônicos) e o silêncio."""

import math

import numpy as np
import pytest

from tracklab.media import pitch

RATE = pitch.RATE


def tone(midi_at, seconds=1.0, harmonics=(1.0, 0.5, 0.3)):
    """Um som com harmônicos cuja altura (MIDI) segue `midi_at(t)`."""
    t = np.arange(int(seconds * RATE)) / RATE
    f = 440 * 2 ** ((np.vectorize(midi_at)(t) - 69) / 12)
    phase = 2 * np.pi * np.cumsum(f) / RATE
    return sum(a * np.sin((h + 1) * phase) for h, a in enumerate(harmonics)) * 0.2


def values(curve):
    return np.array([np.nan if v is None else v for v in curve["values"]])


def test_a_clean_note_is_its_own_pitch():
    x = tone(lambda t: 57.0)
    v = values(pitch.note_curve(x, 0.1, 0.9, 57))
    assert np.isfinite(v).mean() > 0.9 and np.nanmedian(np.abs(v - 57)) < 0.05


def test_a_bend_rises_in_the_curve():
    x = tone(lambda t: 64.0 + (min(1.0, max(0.0, (t - 0.3) / 0.2)) * 2.0))
    v = values(pitch.note_curve(x, 0.05, 0.95, 64))
    start, end = np.nanmedian(v[:20]), np.nanmedian(v[-20:])
    assert start == pytest.approx(64, abs=0.1) and end == pytest.approx(66, abs=0.15)


def test_another_string_ringing_softer_still_gives_the_note():
    # A nota tocada sobre outra corda que ainda soa, mais baixa (a Lente do TabLab dá o mesmo: com as duas no mesmo
    # volume, nenhuma das duas buscas acha a nota, lá e aqui).
    x = tone(lambda t: 55.0) + 0.5 * tone(lambda t: 62.0)
    v = values(pitch.note_curve(x, 0.1, 0.9, 55))
    assert np.isfinite(v).mean() > 0.9 and np.nanmedian(np.abs(v - 55)) < 0.15


def test_a_chord_note_is_searched_between_its_neighbours():
    """Ré 3 e Fá 3 no mesmo volume (um double stop): sem as vizinhas, as duas medidas caem entre as notas; com elas,
    cada uma acha a sua."""
    x = tone(lambda t: 50.0) + tone(lambda t: 53.0)
    for note, other in ((50, 53), (53, 50)):
        v = values(pitch.note_curve(x, 0.1, 0.9, note, others=[other]))
        assert np.isfinite(v).mean() > 0.6 and np.nanmedian(np.abs(v - note)) < 0.15, note


def test_silence_has_no_curve_and_lonely_points_go():
    x = np.zeros(RATE)
    assert all(v is None for v in pitch.note_curve(x, 0.1, 0.9, 60)["values"])
    smoothed = pitch.smooth(np.array([np.nan, 60.0, np.nan, 61, 61.1, 61.2, np.nan]))
    assert math.isnan(smoothed[1]) and np.isfinite(smoothed[3:6]).all()


def test_the_attack_is_when_the_note_really_sounds():
    """A nota escrita em 0,5 s soa em 0,53 (o mapa está adiantado 30 ms ali); a que vem logo depois de outra que ainda
    soa também tem ataque; um ligado (a altura muda sem subida de energia) não tem."""
    t = np.arange(int(1.2 * RATE)) / RATE
    late = np.where(t >= 0.53, tone(lambda _: 57.0, 1.2), 0) * np.exp(-np.maximum(0, t - 0.53) * 3)
    assert pitch.attack(late, 0.5) == pytest.approx(0.53, abs=0.008)
    first = tone(lambda _: 57.0, 1.2) * np.exp(-t * 4)
    second = np.where(t >= 0.6, tone(lambda _: 60.0, 1.2), 0) * np.exp(-np.maximum(0, t - 0.6) * 4)
    assert pitch.attack(first + second, 0.62) == pytest.approx(0.6, abs=0.008)
    legato = tone(lambda s: 57.0 if s < 0.6 else 59.0, 1.2)
    assert pitch.attack(legato, 0.6) is None
