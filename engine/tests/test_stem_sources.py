"""A escada de separação (Fase 4): as faixas da multitrack alinhadas ao vídeo, a guitarra do MVSEP com o resto pelo
Demucs local, nada vira a separação ativa sem o A/B e nenhuma conversão do MVSEP se gasta duas vezes."""

import io
import json

import numpy as np
import pytest
import soundfile

from conftest import guitar_track
from test_songsterr import FakeSource
from test_stems import fake_run
from tracklab import multitracks, songsterr, stems
from tracklab.errors import JobCancelled, MediaError
from tracklab.jobs import Cancel
from tracklab.media import align, mvsep
from tracklab.media import separate as demucs

RATE = 48_000
SECONDS = 40.0
DELAY = 0.75     # o vídeo começa 0,75 s depois da multitrack


def instrument(seed: int, seconds: float = SECONDS, rate: int = RATE) -> np.ndarray:
    """Ruído em rajadas (um "instrumento" que a correlação reconhece), estéreo."""
    rng = np.random.default_rng(seed)
    frames = int(seconds * rate)
    envelope = np.repeat(rng.random(int(seconds * 8)) > 0.4, rate // 8)[:frames]
    envelope = np.pad(envelope, (0, frames - len(envelope))).astype(np.float32)
    noise = rng.standard_normal((frames, 2))
    spectrum = np.fft.rfft(noise, axis=0)
    spectrum[np.fft.rfftfreq(frames, 1 / rate) > 3000] = 0      # só até 3 kHz: o Vorbis e a reamostragem preservam
    noise = np.fft.irfft(spectrum, frames, axis=0)
    return (noise / noise.std() * 0.08 * envelope[:, None]).astype(np.float32)


class NoisySource(FakeSource):
    """O vídeo é a soma dos instrumentos, atrasada e mais baixa."""

    def __init__(self, parts):
        super().__init__([guitar_track(2)], points=[0.0, 2.0, 4.0])
        self.parts = parts

    def download(self, video_id, folder):
        mix = sum(self.parts) * 0.8
        video = align.place(mix, int(DELAY * RATE), len(mix))
        soundfile.write(str(folder / "audio.wav"), video, RATE)
        return folder / "audio.wav", {"title": "Cream - Sunshine", "duration": SECONDS}


@pytest.fixture
def parts():
    return {"guitar": instrument(1), "rhythm": instrument(2), "song": instrument(3)}


@pytest.fixture
def song(monkeypatch, parts):
    monkeypatch.setattr(demucs, "separator_version", lambda model=demucs.MODEL: "v")
    made = songsterr.import_song("27", source=NoisySource(list(parts.values())))
    stems.separate_song(made, run=fake_run([]))
    return made


def library(tmp_path, parts, rate=44_100, ini="[song]\nname = Sunshine of Your Love\nartist = Cream\ndiff_bass = 0\n"):
    """Uma multitrack do Clone Hero com os instrumentos sem o atraso do vídeo, gravada em outra taxa."""
    folder = tmp_path / "Multitracks" / "Pack" / "Cream - Sunshine"
    folder.mkdir(parents=True)
    (folder / "song.ini").write_text(ini)
    for name, data in parts.items():
        frames = round(len(data) * rate / RATE)
        resampled = np.stack([np.interp(np.arange(frames) * RATE / rate, np.arange(len(data)), data[:, c])
                              for c in range(2)], axis=1)
        soundfile.write(str(folder / f"{name}.ogg"), resampled, rate, format="OGG", subtype="VORBIS")
    soundfile.write(str(folder / "crowd.ogg"), instrument(9) * 0.1, rate, format="OGG", subtype="VORBIS")
    found = multitracks.scan(tmp_path / "Multitracks")
    return tmp_path / "Multitracks", found[0]


def test_the_multitrack_lands_on_the_video_and_waits_for_the_ab(song, parts, tmp_path):
    folder, entry = library(tmp_path, parts)
    demucs_key = song.manifest["activeStems"]
    result = stems.import_multitrack(song, entry, folder=folder)
    assert result["key"].startswith("multitrack-") and result["active"] is False
    assert song.manifest["activeStems"] == demucs_key                    # o A/B decide
    alignment = result["alignment"]
    assert alignment["offset"] == pytest.approx(DELAY, abs=0.0003) and alignment["speed"] == pytest.approx(1, abs=1e-4)
    assert set(result["files"]) == {"guitar", "bass", "other"}           # rhythm é o baixo; crowd fica de fora
    guitar, rate = soundfile.read(str(song.file(result["files"]["guitar"])), dtype="float32")
    video, _ = soundfile.read(str(song.file(song.manifest["audio"]["file"])), dtype="float32")
    assert rate == RATE and len(guitar) == len(video)
    expected = align.place(parts["guitar"] * 0.8, int(DELAY * RATE), len(video))
    middle = slice(RATE * 5, RATE * 35)
    assert np.corrcoef(guitar[middle, 0], expected[middle, 0])[0, 1] > 0.95   # o Vorbis perde um pouco
    assert np.std(guitar[middle]) == pytest.approx(np.std(expected[middle]), rel=0.1)   # no volume do vídeo
    again = stems.import_multitrack(song, entry, folder=folder)
    assert again["reused"] is True
    song.set_active_stems(result["key"])
    assert song.manifest["activeStems"] == result["key"]


def test_rhythm_is_the_rhythm_guitar_when_the_chart_has_one(tmp_path, parts):
    _, entry = library(tmp_path, parts, ini="[song]\nname = X\nartist = Y\ndiff_rhythm = 2\n")
    keys = {path.stem: key for path, key in stems.multitrack_tracks(entry, tmp_path / "Multitracks" / entry["path"])}
    assert keys == {"guitar": "guitar", "rhythm": "rhythm", "song": "other"}


def test_another_recording_is_refused(song, tmp_path):
    other = {"guitar": instrument(11), "song": instrument(12)}
    folder, entry = library(tmp_path, other)
    with pytest.raises(MediaError, match="outra gravação"):
        stems.import_multitrack(song, entry, folder=folder)
    assert [key for key in song.manifest["stems"] if key.startswith("multitrack")] == []


class Response:
    def __init__(self, status=200, payload=None, content=b""):
        self.status_code, self.payload, self.content = status, payload, content

    def json(self):
        if self.payload is None:
            raise ValueError
        return self.payload

    def iter_content(self, size):
        for start in range(0, len(self.content), size):
            yield self.content[start:start + size]


class FakeMVSEP:
    """O servidor do MVSEP: aceita o envio, fica na fila uma vez e devolve as guitarras (metade do original)."""

    def __init__(self, source, targets=("guitar",), refuse=False):
        data, rate = soundfile.read(str(source), dtype="float32")
        buffer = io.BytesIO()
        soundfile.write(buffer, data * 0.5, rate, format="WAV", subtype="PCM_16")
        self.wav, self.targets, self.refuse = buffer.getvalue(), targets, refuse
        self.posts, self.polls = [], 0

    def post(self, url, data=None, files=None, timeout=None):
        self.posts.append((url, dict(data or {})))
        if self.refuse:
            return Response(403, {"message": f"Invalid api_token {data['api_token']} at https://mvsep.com/x"})
        return Response(200, {"success": True, "data": {"hash": "h123"}})

    def get(self, url, params=None, stream=False, timeout=None):
        if url.endswith("separation/get"):
            self.polls += 1
            if self.polls == 1:
                return Response(200, {"success": True, "status": "waiting", "data": {"current_order": 3}})
            return Response(200, {"success": True, "status": "done", "data": {"files": [
                {"type": name.replace("-", " ").title(), "url": f"https://mvsep.com/storage/{name}.wav"}
                for name in (*self.targets, "other")]}})
        assert url.startswith("https://mvsep.com/storage/")
        return Response(200, content=self.wav)


KEY = "chave-secreta-123"


def test_the_mvsep_guitar_with_the_rest_from_demucs(song):
    server = FakeMVSEP(song.file(song.manifest["audio"]["file"]))
    events = []
    result = stems.separate_mvsep(song, key=KEY, model=31, session=server, demucs_run=fake_run([]),
                                  pause=lambda _: None, progress=lambda *e: events.append(e[1]))
    assert result["key"].startswith("mvsep31-") and result["active"] is False and result["name"] == "MVSEP Guitar"
    assert server.posts[0][1]["sep_type"] == "31" and server.posts[0][1]["add_opt1"] == "7"
    assert any("posição 3" in message for message in events)
    assert set(result["files"]) == set(demucs.STEMS)
    video, _ = soundfile.read(str(song.file(song.manifest["audio"]["file"])), dtype="float32")
    read = {name: soundfile.read(str(song.file(path)), dtype="float32")[0] for name, path in result["files"].items()}
    # MVSEP: metade do original; o resto (a outra metade) passa pelo Demucs falso, que devolve metade dele em cada
    # faixa; a guitarra leva também o que o Demucs achou de guitarra no resto.
    assert np.allclose(read["guitar"], video * 0.5 + video * 0.25, atol=2e-3)
    assert np.allclose(read["drums"], video * 0.25, atol=2e-3)
    assert mvsep.usage()["usedToday"] == 1 and mvsep.usage()["left"] == mvsep.DAILY_LIMIT - 1
    again = stems.separate_mvsep(song, key=KEY, model=31, session=server, demucs_run=fake_run([]))
    assert again["reused"] is True and len(server.posts) == 1          # nenhuma conversão gasta duas vezes


def test_lead_and_rhythm_from_model_101(song):
    server = FakeMVSEP(song.file(song.manifest["audio"]["file"]), targets=("lead-guitar", "rhythm-guitar"))
    result = stems.separate_mvsep(song, key=KEY, model=101, session=server, demucs_run=fake_run([]),
                                  pause=lambda _: None)
    assert set(result["files"]) == {"guitar", "rhythm", "bass", "drums", "vocals", "piano", "other"}


def test_a_refusal_never_shows_the_key_and_publishes_nothing(song):
    server = FakeMVSEP(song.file(song.manifest["audio"]["file"]), refuse=True)
    with pytest.raises(mvsep.MVSEPError) as error:
        stems.separate_mvsep(song, key=KEY, model=31, session=server, demucs_run=fake_run([]))
    assert KEY not in str(error.value) and "mvsep.com" not in str(error.value) and "recusou" in str(error.value)
    assert not any(key.startswith("mvsep") for key in song.manifest["stems"])
    assert mvsep.usage()["usedToday"] == 0


def test_the_daily_quota_and_a_missing_key(song, monkeypatch):
    with pytest.raises(mvsep.MVSEPError, match="chave"):
        stems.separate_mvsep(song, key="", model=31)
    (mvsep.home.home() / "mvsep.json").write_text(json.dumps({"uses": [mvsep.now_iso()] * mvsep.DAILY_LIMIT}))
    with pytest.raises(mvsep.MVSEPError, match="já foram usadas"):
        stems.separate_mvsep(song, key=KEY, model=31, session=FakeMVSEP(song.file(song.manifest["audio"]["file"])))


def test_the_six_tracks_of_the_sw_come_straight_from_mvsep(song):
    six = ("vocals", "bass", "drums", "guitar", "piano", "other")
    server = FakeMVSEP(song.file(song.manifest["audio"]["file"]), targets=six)
    calls = []
    result = stems.separate_mvsep(song, key=KEY, model=63, session=server, demucs_run=fake_run(calls),
                                  pause=lambda _: None)
    assert result["key"].startswith("mvsep63-") and set(result["files"]) == set(six)
    assert calls == []                                                   # sem resto para o Demucs local
    assert server.posts[0][1]["sep_type"] == "63" and "add_opt1" not in server.posts[0][1]
    video, _ = soundfile.read(str(song.file(song.manifest["audio"]["file"])), dtype="float32")
    guitar, _ = soundfile.read(str(song.file(result["files"]["guitar"])), dtype="float32")
    assert np.allclose(guitar, video * 0.5, atol=2e-3)
    assert mvsep.usage()["usedToday"] == 1


def test_cancelled_before_the_upload_sends_nothing_and_keeps_the_quota(song):
    """Cancelada enquanto o envio se prepara: nenhum pedido sai e a cota do dia fica (depois do envio, o MVSEP já conta
    a conversão)."""
    server, cancel = FakeMVSEP(song.file(song.manifest["audio"]["file"])), Cancel()

    def progress(stage, message, fraction):
        if "Enviando" in message:
            cancel.requested = True

    with pytest.raises(JobCancelled):
        stems.separate_mvsep(song, key=KEY, model=31, session=server, demucs_run=fake_run([]), cancel=cancel,
                             progress=progress, pause=lambda _: None)
    assert server.posts == [] and mvsep.usage()["usedToday"] == 0
