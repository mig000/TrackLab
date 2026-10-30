"""Os .mogg do Rock Band: o Ogg de dentro do cabeçalho aberto, os canais reconhecidos pelas faixas do Demucs e
montados no tempo do vídeo."""

import struct

import numpy as np
import pytest
import soundfile

from tracklab.errors import MediaError
from tracklab.media import mogg

RATE = 22_050
SECONDS = 40.0


def _parts(seed=7):
    rng = np.random.default_rng(seed)
    t = np.arange(int(SECONDS * RATE)) / RATE
    beat = (t % 0.5) < 0.08
    drums = rng.normal(0, 0.3, t.size) * np.exp(-(t % 0.5) * 30) * beat
    notes = 41 + 5 * ((t // 0.5) % 3)                      # o baixo muda de nota a cada batida
    bass = 0.35 * np.sin(2 * np.pi * np.cumsum(440 * 2 ** ((notes - 69) / 12)) / RATE) * ((t % 0.5) < 0.4)
    riff = 64 + 3 * ((t // 0.25) % 4)                      # a guitarra, de semicolcheia em semicolcheia
    phase = 2 * np.pi * np.cumsum(440 * 2 ** ((riff - 69) / 12)) / RATE
    guitar = (0.2 * np.sin(phase) + 0.1 * np.sin(2 * phase) + 0.05 * np.sin(3 * phase)) * ((t % 1.0) < 0.7)
    crowd = rng.normal(0, 0.02, t.size)
    return drums, bass, guitar, crowd


def _write_mogg(path, channels, header=True):
    data = np.stack(channels, axis=1)
    ogg = path.with_suffix(".ogg")
    soundfile.write(str(ogg), data, RATE, format="OGG", subtype="VORBIS")
    body = ogg.read_bytes()
    path.write_bytes((struct.pack("<II", 10, 8) if header else b"") + body)


def test_the_channels_are_recognized_and_land_on_the_video(tmp_path):
    drums, bass, guitar, crowd = _parts()
    shift = int(1.0 * RATE)                               # o vídeo tem 1 s a mais antes da música

    def late(x):
        return np.concatenate([np.zeros(shift), x])

    video = late(drums + bass + guitar)
    source = tmp_path / "source.flac"
    soundfile.write(str(source), np.stack([video, video], 1), RATE)
    stems = {}
    for name, part in (("drums", drums), ("bass", bass), ("guitar", guitar), ("vocals", np.zeros_like(drums))):
        stems[name] = tmp_path / f"demucs-{name}.flac"
        soundfile.write(str(stems[name]), np.stack([late(part)] * 2, 1), RATE)
    song = tmp_path / "song.mogg"
    _write_mogg(song, [drums, drums * 0.9, bass, guitar, guitar * 0.8, crowd])
    receipt = mogg.assemble(source, song, stems, tmp_path / "out")
    # A ordem dos canais muda no Vorbis (som surround) e o ffmpeg reordena: o que conta é quantos de cada.
    kinds = sorted(str(c["stem"]) for c in receipt["channels"])
    assert kinds == ["None", "bass", "drums", "drums", "guitar", "guitar"], receipt["channels"]
    assert set(receipt["stems"]) == {"drums", "bass", "guitar"}
    assert receipt["alignment"]["offset"] == pytest.approx(1.0, abs=0.01)
    # A guitarra montada cai sobre a guitarra do vídeo.
    built, _ = soundfile.read(str(tmp_path / "out" / "guitar.flac"))
    expected = late(guitar)
    n = min(len(built), len(expected))
    assert np.corrcoef(built[:n, 0], expected[:n])[0, 1] > 0.9
    assert not (tmp_path / "out" / "mogg.ogg").exists()


def test_open_plain_and_encrypted_headers(tmp_path):
    drums, bass, guitar, crowd = _parts()
    plain = tmp_path / "plain.mogg"
    _write_mogg(plain, [drums, bass], header=False)
    assert mogg.ogg_start(plain) == 0
    opened = tmp_path / "open.mogg"
    _write_mogg(opened, [drums, bass])
    assert mogg.ogg_start(opened) == 8
    locked = tmp_path / "locked.mogg"
    locked.write_bytes(struct.pack("<II", 13, 8) + b"\0" * 64)
    with pytest.raises(MediaError, match="criptografado"):
        mogg.ogg_start(locked)


def test_the_rock_band_order_breaks_the_tie():
    """As notas do Highway Star (13 canais): pelo som só, o backing (o órgão) ia para a guitarra; com a ordem do Rock
    Band (bateria, baixo, guitarra, voz, backing), ele vai para "other"."""
    def row(guitar, bass, drums, vocals, piano, other):
        return {"guitar": guitar, "bass": bass, "drums": drums, "vocals": vocals, "piano": piano, "other": other}
    scores = [row(0.1, 0.1, 0.7, 0.1, 0.1, 0.1)] * 6 + [
        row(0.31, 0.5, 0.18, 0.14, 0.15, 0.14),
        row(0.35, 0.13, 0.09, 0.21, 0.09, 0.05), row(0.46, 0.16, 0.1, 0.15, 0.15, 0.18),
        row(0.0, 0.0, 0.0, 0.72, 0.0, 0.0), row(0.0, 0.0, 0.0, 0.72, 0.0, 0.0),
        row(0.54, 0.13, 0.07, -0.2, 0.16, 0.33), row(0.54, 0.15, 0.09, -0.06, 0.16, 0.2),
        row(0.05, 0.05, 0.05, 0.05, 0.05, 0.05)]
    kinds = [kind for kind, _ in mogg._ordered(scores)]
    assert kinds == ["drums"] * 6 + ["bass", "guitar", "guitar", "vocals", "vocals", "other", "other", None]
