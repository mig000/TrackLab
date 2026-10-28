"""Importação do Songsterr sem rede: a partitura passa pelo conversor de verdade; vídeo e áudio são falsos."""

import json
from zipfile import ZipFile
import xml.etree.ElementTree as ET

import pytest

from conftest import guitar_track, tone
from tracklab import package, songsterr
from tracklab.errors import SongsterrError
from tracklab.tempomap import map_of


class FakeSource(songsterr.Source):
    def __init__(self, tracks, points=None, video="abcdefghijk", download_error=None):
        self.tracks, self.points, self.video, self.download_error = tracks, points, video, download_error

    def fetch(self, ident):
        return {"revisionId": 7, "artist": "Cream", "title": "Sunshine of Your Love",
                "tracks": [{"name": t["name"], "instrument": t["instrument"]} for t in self.tracks]}, self.tracks

    def video_points(self, ident, revision):
        assert revision == 7
        if self.points is None:
            return []
        return [{"feature": "backing", "status": "done", "videoId": "zzzzzzzzzzz", "points": [0, 1]},
                {"feature": None, "status": "done", "videoId": self.video, "points": self.points}]

    def download(self, video_id, folder):
        if self.download_error:
            raise SongsterrError(self.download_error)
        assert video_id == self.video
        return tone(folder / "audio.wav", seconds=6.0), {"title": "Cream - Sunshine", "duration": 6.0}


def test_song_ids_are_constrained():
    assert songsterr.song_id("https://www.songsterr.com/a/wsa/cream-sunshine-of-your-love-tab-s27") == 27
    assert songsterr.song_id(" 1234 ") == 1234
    for bad in ("https://songsterr.com.evil.invalid/a/x-s1234", "file:///a/x-s1234", "https://www.songsterr.com/x"):
        with pytest.raises(SongsterrError):
            songsterr.song_id(bad)


def test_import_makes_a_package_with_score_audio_and_tempo_map():
    events = []
    song = songsterr.import_song("27", source=FakeSource([guitar_track(3)], points=[0.5, 2.5, 4.5, 5.9]),
                                 progress=lambda *a: events.append(a))
    manifest = song.manifest
    assert song.path.name == "cream-sunshine-of-your-love.tracklab"
    assert manifest["origin"]["songId"] == 27 and manifest["origin"]["videoId"] == "abcdefghijk"
    assert manifest["score"]["measures"] == 3 and manifest["score"]["tracks"][0]["name"] == "Lead Guitar"
    with ZipFile(song.file("score/original.gp")) as gp:
        xml = ET.fromstring(gp.read("Content/score.gpif"))
    assert len(xml.findall("./MasterBars/MasterBar")) == 3
    assert manifest["audio"]["sampleRate"] == 48_000 and manifest["audio"]["duration"] == pytest.approx(6.0, abs=0.01)
    assert song.file("audio/source.flac").is_file()
    tempo = json.loads(song.file("score/tempo-map.json").read_text())
    assert map_of(tempo).seconds(3840) == pytest.approx(2.5)
    assert manifest["warnings"] == []
    assert events[0][0] == "songsterr" and events[-1][1] == "Guardando no repertório…"


def test_without_the_closing_point_the_last_bar_is_estimated_and_said():
    song = songsterr.import_song("27", source=FakeSource([guitar_track(2)], points=[0.5, 2.5]))
    assert any("último compasso" in w for w in song.manifest["warnings"])


def test_no_linked_video_still_imports_the_score_with_a_warning():
    song = songsterr.import_song("27", source=FakeSource([guitar_track(2)], points=None))
    manifest = song.manifest
    assert manifest["audio"] is None and manifest["tempoMap"] is None
    assert manifest["warnings"] == ["Áudio não incluído: não há vídeo principal vinculado e pronto no Songsterr."]


def test_a_failed_download_keeps_the_score():
    song = songsterr.import_song("27", source=FakeSource([guitar_track(2)], points=[0, 2, 4], download_error="bloqueado"))
    assert song.manifest["audio"] is None
    assert "bloqueado" in song.manifest["warnings"][0]


def test_too_few_points_are_refused_for_audio():
    song = songsterr.import_song("27", source=FakeSource([guitar_track(3)], points=[0.0, 2.0]))
    assert "insuficientes" in song.manifest["warnings"][0]


def test_a_failure_in_the_score_leaves_no_package():
    class Broken(FakeSource):
        def generate(self, tracks, path, meta):
            raise SongsterrError("conversor falhou")

    with pytest.raises(SongsterrError):
        songsterr.import_song("27", source=Broken([guitar_track(2)]))
    assert package.packages() == []
    assert [p for p in (package.home.songs()).iterdir()] == []


def test_search_keeps_unique_valid_results():
    class Response:
        def raise_for_status(self):
            pass

        def json(self):
            return [{"songId": 27, "artist": "Cream", "title": "Sunshine", "tracks": [{}, {}]},
                    {"songId": 27, "artist": "Cream", "title": "Sunshine"}, {"songId": True}, "x",
                    {"songId": 9, "title": None}]

    found = songsterr.search("cream", get=lambda *a, **k: Response())
    assert found == [{"id": 27, "artist": "Cream", "title": "Sunshine", "tracks": 2},
                     {"id": 9, "artist": "Artista desconhecido", "title": "Sem título", "tracks": 0}]
    with pytest.raises(SongsterrError):
        songsterr.search("x")


def test_signatures_carry_forward():
    track = guitar_track(3, signature=(6, 8))
    track["measures"][2]["signature"] = [4, 4]
    assert songsterr.signatures([track]) == [(6, 8), (6, 8), (4, 4)]
