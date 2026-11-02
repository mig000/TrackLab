"""O tempo ouvido de uma faixa para o Ajuste: a força dos ataques e as batidas que o detector acha."""

import numpy as np
import pytest

from tracklab.media import beats


def clicks(period: float, seconds: float = 20.0, offset: float = 0.25) -> np.ndarray:
    """Um bumbo de mentira: um estalo curto (ruído que decai) a cada `period`, sobre um chiado baixo."""
    rng = np.random.default_rng(3)
    signal = rng.standard_normal(int(seconds * beats.RATE)).astype(np.float32) * 0.002
    hit = rng.standard_normal(int(0.05 * beats.RATE)).astype(np.float32) * np.exp(-np.linspace(0, 8, int(0.05 * beats.RATE)))
    for at in np.arange(offset, seconds - 0.1, period):
        start = int(at * beats.RATE)
        signal[start:start + len(hit)] += hit
    return signal


def test_the_beats_fall_on_the_clicks_and_the_envelope_peaks_there():
    result = beats.analyse_signal(clicks(0.5), bpm=120)
    found = np.array(result["beats"])
    assert len(found) >= 30
    # Cada batida achada cai num estalo (a até 25 ms), e o passo é o do andamento.
    grid = 0.25 + 0.5 * np.round((found - 0.25) / 0.5)
    assert np.median(np.abs(found - grid)) < 0.01
    assert np.median(np.diff(found)) == pytest.approx(0.5, abs=0.02)
    assert result["tempo"] == pytest.approx(120, abs=3)
    envelope = np.array(result["envelope"])
    frame = round(5.25 * result["rate"])
    # O pico cai no estalo (a força vem adiantada o tanto que ela atrasa), não um quadro depois.
    assert envelope.max() == 255 and int(np.argmax(envelope[frame - 6:frame + 7])) - 6 in (-1, 0, 1)
    assert envelope[frame + 20:frame + 40].max() < 60   # entre um estalo e o outro, quase nada


def test_the_tempo_of_the_map_keeps_the_detector_off_the_double():
    # 75 bpm; sem o andamento do mapa o detector pode dobrar. Com ele, o passo fica em 0,8 s.
    result = beats.analyse_signal(clicks(0.8, seconds=30), bpm=75)
    assert np.median(np.diff(result["beats"])) == pytest.approx(0.8, abs=0.03)
