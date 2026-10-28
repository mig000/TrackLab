"""O repertório: estados, trechos com meta e o treino guardados no pacote, e o resumo que a lista lê."""

import pytest

from tracklab import package, repertoire
from tracklab.repertoire import RepertoireError


def make():
    draft = package.Draft("White Room", "Cream", {"kind": "test"})
    draft.manifest["score"] = {"file": "score/original.gp", "measures": 4, "tracks": [
        {"index": 0, "name": "Jack Bruce | Bass", "instrument": "Electric Bass", "tuning": [43, 38, 33, 28]},
        {"index": 1, "name": "Eric Clapton | Lead Guitar", "instrument": "Distortion Guitar",
         "tuning": [62, 57, 53, 48, 43, 38]}]}
    return draft.publish()


def test_a_new_song_wants_to_be_learned_and_its_state_changes():
    song = make()
    assert song.summary()["status"] == "want"
    assert song.set_status("learning") == "learning" and song.summary()["status"] == "learning"
    with pytest.raises(RepertoireError):
        song.set_status("talvez")


def test_sections_keep_their_practice_when_the_app_sends_them_again():
    song = make()
    riff, = song.set_sections([{"name": "Riff", "from": 0, "to": 3840, "goal": 100}])
    assert riff["id"].startswith("sec-") and riff["best"] is None and riff["history"] == []
    song.practice(riff["id"], 80, clean=True)
    song.practice(riff["id"], 85, clean=False)
    after = song.practice(riff["id"], 82.4, clean=True)
    assert after["best"] == 82 and [h["rate"] for h in after["history"]] == [80, 85, 82]
    # O app renomeia e acrescenta um trecho antes: o treino do Riff continua, e a lista sai em ordem.
    intro, kept = song.set_sections([{"id": riff["id"], "name": "Riff principal", "from": 3840, "to": 7680, "goal": 110},
                                     {"name": "Intro", "from": 0, "to": 1920}])
    assert [s["name"] for s in (intro, kept)] == ["Intro", "Riff principal"]
    assert kept["best"] == 82 and kept["goal"] == 110 and len(kept["history"]) == 3
    summary = song.summary()
    assert [s["name"] for s in summary["sections"]] == ["Intro", "Riff principal"]
    assert "history" not in summary["sections"][1] and summary["sections"][1]["best"] == 82


def test_bad_sections_and_practice_are_refused():
    song = make()
    for bad in ([{"name": "x", "from": 10, "to": 5}], [{"name": " ", "from": 0, "to": 5}],
                [{"name": "x", "from": 0, "to": 5, "goal": 300}], "x"):
        with pytest.raises(RepertoireError):
            song.set_sections(bad)
    with pytest.raises(RepertoireError):
        song.practice("sec-nada", 80, clean=True)


def test_the_summary_has_the_guitar_tuning_and_how_much_is_checked():
    song = make()
    song.set_checked_bars([1, 2])
    summary = song.summary()
    assert summary["tuning"] == [62, 57, 53, 48, 43, 38] and summary["measures"] == 4 and summary["checked"] == 2


def test_history_is_limited():
    section = {"id": "sec-x", "best": None, "history": []}
    for _ in range(repertoire.HISTORY_LIMIT + 5):
        section = repertoire.record_practice(section, 90, clean=False)
    assert len(section["history"]) == repertoire.HISTORY_LIMIT and section["best"] is None
