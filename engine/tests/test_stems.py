"""A separação de uma música do repertório: chave pelo áudio e pela versão, reaproveitada, publicada inteira."""

import numpy as np
import pytest
import soundfile

from conftest import guitar_track, tone
from test_songsterr import FakeSource
from tracklab import songsterr, stems
from tracklab.errors import PackageError
from tracklab.media import separate as demucs


def fake_run(calls):
    def run(source, output, *, progress=None, cancel=None, device=None):
        calls.append(device)
        data, rate = soundfile.read(str(source))
        files = {}
        for name in demucs.STEMS:
            soundfile.write(str(output / f"{name}.flac"), data * 0.5, rate)
            files[name] = {"file": f"{name}.flac"}
        progress and progress("separate", "ok", 1.0)
        return {"model": "htdemucs_6s", "device": device or "mps", "seconds": 0.1, "created": "agora", "stems": files}
    return run


@pytest.fixture
def song(monkeypatch):
    monkeypatch.setattr(demucs, "separator_version", lambda model=demucs.MODEL: "separate.v1/demucs-4.1.0/htdemucs_6s")
    return songsterr.import_song("27", source=FakeSource([guitar_track(2)], points=[0.0, 2.0, 4.0]))


def test_separation_is_published_and_reused(song):
    calls = []
    first = stems.separate_song(song, run=fake_run(calls))
    assert first["reused"] is False and first["key"].startswith("demucs6s-")
    assert set(first["files"]) == set(demucs.STEMS)
    assert song.manifest["activeStems"] == first["key"]
    again = stems.separate_song(song, run=fake_run(calls))
    assert again["reused"] is True and len(calls) == 1


def test_a_song_without_audio_cannot_be_separated(monkeypatch):
    monkeypatch.setattr(demucs, "separator_version", lambda model=demucs.MODEL: "v")
    bare = songsterr.import_song("27", source=FakeSource([guitar_track(2)], points=None))
    with pytest.raises(PackageError):
        stems.separate_song(bare, run=fake_run([]))


def test_mps_failure_falls_back_to_the_cpu(monkeypatch, tmp_path):
    source = tone(tmp_path / "mix.wav", seconds=1.0)
    devices = []

    class Network:
        sources = list(demucs.STEMS)

    def run(network, mix, rate, device, progress, cancel):
        devices.append(device)
        if device == "mps":
            raise RuntimeError("ComplexFloat is not supported on MPS\nmais detalhes")
        return {name: mix * 0.1 for name in demucs.STEMS}

    monkeypatch.setattr(demucs, "separator_version", lambda model=demucs.MODEL: "v")
    monkeypatch.setattr(demucs, "_load_model", lambda model: Network())
    monkeypatch.setattr(demucs, "_run", run)
    monkeypatch.setattr(demucs.metadata, "version", lambda name: "4.1.0")
    receipt = demucs.separate(source, tmp_path / "out", device="mps")
    assert devices == ["mps", "cpu"] and receipt["device"] == "cpu"
    assert "ComplexFloat" in receipt["fallback"] and "mais detalhes" not in receipt["fallback"]
    out, rate = soundfile.read(str(tmp_path / "out" / "guitar.flac"))
    assert rate == 48_000 and np.abs(out).max() == pytest.approx(0.03, abs=1e-3)
