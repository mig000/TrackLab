"""O índice de multitracks: os três jeitos de guardar uma música, os nomes limpos, a busca sem acento e o casamento
com o Songsterr."""

import pytest

from tracklab import multitracks
from tracklab.multitracks import MultitrackError


def touch(path, text=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


@pytest.fixture
def library(tmp_path):
    root = tmp_path / "Multitracks"
    rock = root / "Rock Band" / "Cream - Sunshine Of Your Love"
    touch(rock / "song.ini", "[song]\nname = Sunshine of Your Love\nartist = Cream\nalbum = Disraeli Gears\nyear = 1967\n")
    for name in ("guitar.ogg", "rhythm.ogg", "song.ogg", "drums_1.ogg", "drums_2.ogg", "vocals.ogg", "album.png"):
        touch(rock / name)
    touch(root / "The Beatles - Rock Band MOGGs" / "Help DLC" / "03 - Ticket to Ride.mogg")
    touch(root / "PACK 12" / "Megadeth" / "07 - I Ain't Superstitious" / "07 - I Ain't Superstitious.mogg")
    studio = root / "PACK 5" / "Caesars" / "Caesars - Jerk It Out (Multitrack)"
    for name in ("01 Kick.flac", "03 Bass.flac", "04 Guitars.flac", "05 Vocals.flac", "06 Hammond Organ.flac"):
        touch(studio / name)
    nested = root / "PACK 11" / "Lady Gaga" / "Lady Gaga Love Game (Stems Sample Pack)" / "Lady Gaga Love Game"
    for name in ("Bass.wav", "Lead Vocals.wav"):
        touch(nested / name)
    loose = root / "Heartbreaker"
    for part in ("Bass", "Guitar", "Vocal"):
        touch(loose / f"Led Zeppelin - Heartbreaker {part} Track Isolated.mp3")
    touch(root / "Songsterr" / "Cream - White Room.gp")
    touch(root / ".Trashes" / "x" / "a.wav")
    return root


def test_each_kind_of_song_is_found_with_a_clean_name(library):
    songs = {(s["artist"], s["title"]): s for s in multitracks.scan(library)}
    assert set(songs) == {("Cream", "Sunshine of Your Love"), ("The Beatles", "Ticket to Ride"),
                          ("Megadeth", "I Ain't Superstitious"), ("Caesars", "Jerk It Out"),
                          ("Lady Gaga", "Love Game"), ("Led Zeppelin", "Heartbreaker")}
    sunshine = songs[("Cream", "Sunshine of Your Love")]
    assert sunshine["format"] == "clonehero" and sunshine["album"] == "Disraeli Gears" and sunshine["year"] == "1967"
    assert {s["file"]: s["kind"] for s in sunshine["stems"]} == {
        "guitar.ogg": "guitar", "rhythm.ogg": "rhythm", "song.ogg": "backing", "drums_1.ogg": "drums",
        "drums_2.ogg": "drums", "vocals.ogg": "vocals"}
    assert songs[("The Beatles", "Ticket to Ride")]["format"] == "mogg"
    jerk = songs[("Caesars", "Jerk It Out")]
    assert [s["kind"] for s in jerk["stems"]] == ["drums", "bass", "guitar", "vocals", "keys"]
    assert songs[("Led Zeppelin", "Heartbreaker")]["path"] == "Heartbreaker"


def test_the_index_finds_by_word_start_without_accents_and_matches_songsterr(library, tmp_path):
    index = tmp_path / "mt.sqlite"
    status = multitracks.build(multitracks.scan(library), library, index)
    assert status["count"] == 6 and status["scanned"]
    assert [s["title"] for s in multitracks.search("sunsh lov", path=index)] == ["Sunshine of Your Love"]
    assert [s["artist"] for s in multitracks.search("CÁESARS", path=index)] == ["Caesars"]
    assert multitracks.search("", path=index) == [] and multitracks.search("x", path=tmp_path / "nada.sqlite") == []
    found = multitracks.match("Cream", "Sunshine Of Your Love (Live)", path=index)
    assert found["kinds"] == ["backing", "drums", "guitar", "rhythm", "vocals"]
    assert multitracks.match("Beatles", "Ticket To Ride", path=index)["format"] == "mogg"
    assert multitracks.match("Cream", "White Room", path=index) is None
    assert multitracks.match("Jimi Hendrix", "Sunshine of Your Love", path=index) is None


def test_a_missing_library_says_where_it_looked(tmp_path, monkeypatch):
    monkeypatch.setenv("TRACKLAB_MULTITRACKS", str(tmp_path / "desligado"))
    with pytest.raises(MultitrackError, match="HD externo"):
        multitracks.scan(multitracks.root())
    assert multitracks.status()["available"] is False and multitracks.status()["count"] == 0


def test_names_and_kinds():
    assert multitracks.clean_name("22 3 Doors Down - Kryptonite") == "3 Doors Down - Kryptonite"
    assert multitracks.clean_name("Walking Away-Multitrack") == "Walking Away"
    assert multitracks.split_name("Ramble On", None) == (None, "Ramble On")
    assert [multitracks.kind_of(n) for n in ("Lead Vocals.wav", "Organ, Electric Piano.wav", "drums_3.ogg",
                                             "Strings, French Horns.wav", "keys.ogg")] == [
        "vocals", "keys", "drums", "other", "keys"]
