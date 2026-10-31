"""Os sons de uma faixa (as suspeitas "som sem nota"): ataques e alturas lidos no espectro."""

import numpy as np
import soundfile

from tracklab.media import sounds, spectrum

RATE = 22_050


def _note(midi, seconds, rate=RATE):
    t = np.arange(int(seconds * rate)) / rate
    f0 = 440 * 2 ** ((midi - 69) / 12)
    tone = sum(0.6 ** (h - 1) * np.sin(2 * np.pi * f0 * h * t) for h in range(1, 7))
    return 0.25 * tone * np.exp(-t * 3)


def test_attacks_and_pitches_of_plucked_notes(tmp_path):
    plan = [(0.5, 64), (1.1, 67), (1.7, 52), (2.3, 71), (2.9, 57)]
    signal = np.zeros(int(3.6 * RATE))
    for start, midi in plan:
        part = _note(midi, 0.55)
        at = int(start * RATE)
        signal[at:at + len(part)] += part
    path = tmp_path / "guitar.wav"
    soundfile.write(str(path), signal, RATE)
    made = spectrum.compute(path)
    found = sounds.detect(made["data"], made["hop"], made["low"], made["perSemitone"])
    for start, midi in plan:
        near = [s for s in found if abs(s[0] - start) < 0.04]
        assert near, f"o ataque em {start} s"
        assert midi in [int(s[1]) for s in near], f"a altura {midi} em {start} s: {near}"
    # Nada além dos cinco ataques (e no máximo um segundo som em cada).
    assert len({round(s[0], 1) for s in found}) == len(plan)


def test_silence_has_no_sounds():
    data = np.zeros((200, spectrum.rows()), dtype=np.uint8)
    assert sounds.detect(data, spectrum.HOP / spectrum.RATE, spectrum.LOW, spectrum.PER_SEMITONE) == []
