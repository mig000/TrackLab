"""O espectro da Fita: cada nota acende a linha da altura dela, no tempo dela."""

import numpy as np
import soundfile

from tracklab.media import spectrum


def test_a_note_lights_its_own_row_at_its_own_time(tmp_path):
    rate = 44_100
    t = np.arange(int(3 * rate)) / rate
    wave = np.zeros_like(t)
    a3 = (t >= 1.0) & (t < 2.0)
    wave[a3] = 0.5 * np.sin(2 * np.pi * 220.0 * t[a3])          # Lá 3 (MIDI 57), de 1 a 2 s
    path = tmp_path / "a.wav"
    soundfile.write(str(path), np.stack([wave, wave], axis=1), rate)
    made = spectrum.compute(path)
    data, hop = made["data"], made["hop"]
    assert data.shape == (made["frames"], spectrum.rows()) and data.dtype == np.uint8
    row = (57 - spectrum.LOW) * spectrum.PER_SEMITONE
    middle = int(1.5 / hop)
    assert int(np.argmax(data[middle])) == row                   # a linha mais acesa é a da nota
    assert data[middle, row] > 200 and data[int(0.5 / hop), row] < 30 and data[int(2.5 / hop), row] < 30
    # Uma oitava acima não acende como a fundamental.
    assert data[middle, row + 12 * spectrum.PER_SEMITONE] < data[middle, row] - 60
