"""A TAB sintetizada: o MIDI do Guitar Pro pelo alphaTab, no andamento do mapa de tempo, uma faixa por pista no
tamanho do áudio do vídeo, refeita quando o mapa muda."""

import os
import shutil
import time
from pathlib import Path

import mido
import numpy as np
import pytest
import soundfile

from tracklab import package, stems
from tracklab.errors import MediaError
from tracklab.media import synth

FIXTURE = Path(__file__).resolve().parents[2] / "web" / "tests" / "fixtures" / "quatro-por-quatro.gp"
needs_node = pytest.mark.skipif(shutil.which("node") is None and not Path("/usr/local/bin/node").exists(),
                                reason="sem node")


def bars(seconds_per_bar=2.0, start=1.0, count=8):
    """Compassos 4/4 de `seconds_per_bar` a partir de `start`, um ponto por batida."""
    beat = seconds_per_bar / 4
    return [{"tick": i * 960, "seconds": start + i * beat, "kind": "detected" if i % 4 == 0 else "interpolated"}
            for i in range(count * 4 + 1)]


@needs_node
def test_the_midi_follows_the_tempo_map(tmp_path):
    info = synth.gp_to_midi(FIXTURE, tmp_path / "score.mid")
    assert info["division"] == 960 and info["tracks"][0]["index"] == 0
    points = bars(2.0, start=1.0)
    points[8]["seconds"] += 0.1     # a terceira batida do segundo compasso atrasa: o andamento muda ali
    midi, offset = synth.retimed(tmp_path / "score.mid", points, 0)
    assert offset == pytest.approx(1.0)
    tempos = [m for m in midi.tracks[0] if m.type == "set_tempo"]
    assert tempos[0].tempo == 500_000 and len(tempos) == len(points) - 1
    assert not any(m.type == "set_tempo" for m in midi.tracks[1])
    # Tocando o MIDI, cada batida (um evento de andamento por ponto) cai no segundo do mapa, contado do tique 0.
    clock, beats = 0.0, []
    for message in midi:
        clock += message.time
        if message.type == "set_tempo":
            beats.append(clock)
    assert beats == pytest.approx([p["seconds"] - offset for p in points[:-1]], abs=1e-4)
    assert sum(1 for m in midi.tracks[1] if m.type == "note_on" and m.velocity) > 0


@needs_node
def test_each_track_lands_on_the_video_audio_and_goes_stale_with_a_new_map(tmp_path, monkeypatch):
    rate = 48_000
    draft = package.Draft("X", "Y", {"kind": "test"})
    gp = draft.file("score/original.gp")
    gp.write_bytes(FIXTURE.read_bytes())
    draft.manifest["score"] = {"file": "score/original.gp", "sha256": "abc", "measures": 2, "tracks": []}
    t = np.arange(int(20 * rate)) / rate
    soundfile.write(str(draft.file("audio/source.flac")), np.stack([0.2 * np.sin(2 * np.pi * 220 * t)] * 2, axis=1), rate)
    draft.manifest["audio"] = {"file": "audio/source.flac", "sha256": "s"}
    song = draft.publish()
    song.save_tempo_map({"schemaVersion": 1, "source": "reference", "points": bars(2.0, start=1.5)})
    font = tmp_path / "Teste.sf2"
    font.write_bytes(b"riff")

    def fake_render(midi_path, font_path, target, rate):
        # Um "instrumento" que soa o MIDI inteiro: uma nota contínua da primeira nota ao fim.
        midi = mido.MidiFile(str(midi_path))
        first = None
        clock = 0.0
        for message in midi:
            clock += message.time
            if first is None and message.type == "note_on" and message.velocity:
                first = clock
        data = np.zeros((int(midi.length * rate) + rate, 2), dtype=np.float32)
        data[int(first * rate):int(midi.length * rate)] = 0.5
        soundfile.write(str(target), data, rate, subtype="FLOAT")

    monkeypatch.setattr(synth, "render", fake_render)
    # A pasta de uma síntese interrompida (o app fechado no meio) sai na seguinte; a de um trabalho em curso fica.
    song.file("synth").mkdir(exist_ok=True)
    stale = song.file("synth") / ".tab-velha.abc.partial"
    fresh = song.file("synth") / ".tab-agora.def.partial"
    stale.mkdir()
    fresh.mkdir()
    os.utime(stale, (time.time() - 2 * 3600,) * 2)
    result = stems.synthesize_tab(song, font=font, engine="fluidsynth")
    assert not stale.exists() and fresh.exists()
    fresh.rmdir()
    assert result["reused"] is False and result["soundfont"] == "Teste.sf2" and list(result["tracks"]) == ["0"]
    audio, got = soundfile.read(str(song.file(result["tracks"]["0"]["file"])), dtype="float32")
    assert got == rate and len(audio) == 20 * rate
    # O tique 0 cai a 1,5 s no vídeo: antes disso, silêncio.
    assert np.abs(audio[:int(1.49 * rate)]).max() < 1e-4 and np.abs(audio[int(1.6 * rate):int(5 * rate)]).max() > 0.01
    assert stems.synth_state(song)["stale"] is False
    # Uma síntese de antes de o manifesto guardar o SHA da partitura: reaproveitada, ganha o SHA e deixa de ser velha.
    song.update(lambda data: data["synth"].pop("scoreSHA256"))
    assert stems.synth_state(song)["stale"] is True
    assert stems.synthesize_tab(song, font=font, engine="fluidsynth")["reused"] is True
    assert stems.synth_state(song)["stale"] is False
    # Uma síntese de uma versão anterior do procedimento também é velha (o app a refaz ao abrir).
    song.update(lambda data: data["synth"].update(version="synth.v1"))
    assert stems.synth_state(song)["stale"] is True
    assert stems.synthesize_tab(song, font=font, engine="fluidsynth")["reused"] is True
    assert stems.synth_state(song)["stale"] is False
    # Um arquivo dela que falta também (o app abre a música sem ele e a refaz).
    track_file = song.file(result["tracks"]["0"]["file"])
    kept = track_file.read_bytes()
    track_file.unlink()
    assert stems.synth_state(song)["stale"] is True
    track_file.write_bytes(kept)
    assert stems.synth_state(song)["stale"] is False
    song.save_tempo_map({"schemaVersion": 1, "source": "reference", "points": bars(2.0, start=2.0)})
    assert stems.synth_state(song)["stale"] is True
    again = stems.synthesize_tab(song, font=font, engine="fluidsynth")
    assert again["reused"] is False and again["key"] != result["key"]
    assert [p.name for p in song.file("synth").iterdir()] == [again["key"]]   # a antiga sai


@needs_node
def test_alphatab_synthesizes_without_anything_installed(tmp_path):
    """Sem FluidSynth: o TinySoundFont do alphaTab, com o SoundFont do próprio alphaTab (Sonivox, Apache 2.0)."""
    rate = 44_100
    source = tmp_path / "video.flac"
    soundfile.write(str(source), np.full((int(25 * rate), 2), 0.05, dtype=np.float32), rate)
    points = bars(2.0, start=3.0)
    receipt = synth.synthesize(FIXTURE, points, source, tmp_path / "out",
                               font=Path(__file__).parent / "fixtures" / "sonivox.sf2", engine="alphatab")
    assert receipt["engine"] == "alphatab" and receipt["tracks"]
    audio, got = soundfile.read(str(tmp_path / "out" / f"t{next(iter(receipt['tracks']))}.flac"), dtype="float32")
    assert got == rate and len(audio) == 25 * rate
    loud = np.flatnonzero(np.abs(audio[:, 0]) > 0.01)
    # A primeira nota soa no tique 0, que o mapa põe aos 3 s do vídeo; antes, silêncio.
    assert loud[0] / rate == pytest.approx(3.0, abs=0.05)


def test_the_reverb_keeps_the_dry_sound_and_adds_a_tail():
    rate = 8000
    dry = np.zeros((rate * 3, 2), dtype=np.float32)
    dry[100] = 1.0
    wet = synth.reverb(dry, rate)
    assert wet[100, 0] == pytest.approx(1.0, abs=0.05) and np.abs(wet[rate:, 0]).max() > 1e-4
    assert np.abs(wet[100 + int(1.7 * rate):, 0]).max() < 1e-3


def test_the_soundfont_comes_from_the_sounds_folder(monkeypatch):
    monkeypatch.delenv("TRACKLAB_SOUNDFONT", raising=False)
    with pytest.raises(MediaError, match="SoundFont"):
        synth.soundfont()
    (synth.sounds() / "B.sf2").write_bytes(b"x")
    (synth.sounds() / "A.sf3").write_bytes(b"x")
    assert synth.soundfont().name == "A.sf3"
