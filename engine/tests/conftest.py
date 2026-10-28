import math

import numpy as np
import pytest
import soundfile


@pytest.fixture(autouse=True)
def scratch_home(tmp_path, monkeypatch):
    """Cada teste com um TRACKLAB_HOME próprio: nenhum toca no repertório de verdade."""
    root = tmp_path / "home"
    monkeypatch.setenv("TRACKLAB_HOME", str(root))
    monkeypatch.delenv("TRACKLAB_MODELS", raising=False)
    return root


def guitar_track(measures: int, signature=(4, 4)) -> dict:
    """Uma faixa no formato JSON do Songsterr: semínimas na corda 3, casa 5."""
    beat = {"type": 4, "notes": [{"fret": 5, "string": 2}]}
    bars = [{"voices": [{"beats": [dict(beat) for _ in range(signature[0])]}]} for _ in range(measures)]
    bars[0]["signature"] = list(signature)
    return {"name": "Lead Guitar", "instrument": "Distortion Guitar", "instrumentId": 30, "strings": 6, "frets": 24,
            "tuning": [64, 59, 55, 50, 45, 40], "measures": bars, "automations": {"tempo": [{"bpm": 120}]}}


def tone(path, seconds=3.0, rate=48_000):
    t = np.arange(int(seconds * rate)) / rate
    wave = 0.3 * np.sin(2 * math.pi * 220 * t)
    soundfile.write(str(path), np.stack([wave, wave], axis=1), rate)
    return path
