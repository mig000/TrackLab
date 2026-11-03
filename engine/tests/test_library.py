import json

import pytest

from tracklab import home, library


def make_song(root, name, payload=b"abc"):
    song = root / f"{name}.tracklab"
    (song / "audio").mkdir(parents=True)
    (song / "manifest.json").write_text(json.dumps({"id": name}))
    (song / "audio" / "source.mp3").write_bytes(payload)
    return song


def test_without_a_choice_the_library_is_the_old_repertoire():
    assert home.songs() == home.home() / "Repertorio" and library.info()["default"] is True


def test_moving_copies_checks_and_then_removes_each_song(tmp_path):
    make_song(home.songs(), "a")
    make_song(home.songs(), "b", b"x" * 5000)
    target = tmp_path / "Disco"
    target.mkdir()
    make_song(target, "b", b"outra")            # uma que já estava lá não é sobrescrita
    result = library.move(target)
    assert result == {"path": str(target), "moved": 1, "kept": ["b.tracklab"]}
    assert home.songs() == target and (target / "a.tracklab" / "audio" / "source.mp3").read_bytes() == b"abc"
    assert (target / "b.tracklab" / "audio" / "source.mp3").read_bytes() == b"outra"
    assert not (library.default_folder() / "a.tracklab").exists()
    assert not list(target.glob(".*.partial"))
    assert json.loads((home.home() / "config.json").read_text())["library"] == str(target)


def test_a_copy_that_does_not_match_removes_nothing(tmp_path, monkeypatch):
    song = make_song(home.songs(), "a")
    target = tmp_path / "Disco"
    target.mkdir()
    monkeypatch.setattr(library, "sha256_file", lambda path: str(path))   # toda cópia "difere" do original
    with pytest.raises(library.LibraryError, match="não confere"):
        library.move(target)
    assert song.is_dir() and not list(target.iterdir()) and home.songs() == library.default_folder()


def test_bad_targets_are_refused(tmp_path):
    with pytest.raises(library.LibraryError, match="não existe"):
        library.check_target(tmp_path / "nada")
    with pytest.raises(library.LibraryError, match="já está"):
        library.check_target(home.songs())
    inside = home.songs() / "dentro"
    inside.mkdir()
    with pytest.raises(library.LibraryError, match="dentro"):
        library.check_target(inside)


def test_using_a_ready_library_moves_nothing(tmp_path):
    make_song(home.songs(), "a")
    other = tmp_path / "Outra"
    make_song(other, "c")
    assert library.use(other)["songs"] == 1 and (library.default_folder() / "a.tracklab").is_dir()
