"""O pacote da música: nasce oculto, aparece inteiro, e as separações entram de uma vez."""

from pathlib import Path

import pytest

from tracklab import package
from tracklab.errors import PackageError


def make(title="Sunshine of Your Love", artist="Cream"):
    draft = package.Draft(title, artist, {"kind": "test"})
    draft.file("score/original.gp").write_bytes(b"gp")
    return draft


def test_a_draft_is_hidden_until_published_and_names_do_not_collide():
    draft = make()
    assert draft.path.name.startswith(".") and package.packages() == []
    first = draft.publish()
    second = make().publish()
    assert first.path.name == "cream-sunshine-of-your-love.tracklab"
    assert second.path.name == "cream-sunshine-of-your-love-2.tracklab"
    assert sorted(p.id for p in package.packages()) == sorted([first.id, second.id])
    assert package.find(second.id).path == second.path
    assert not [p for p in first.path.parent.iterdir() if p.name.startswith(".")]


def test_discarded_drafts_leave_nothing():
    draft = make()
    draft.discard()
    assert not draft.path.exists()


def test_files_outside_the_package_are_refused():
    song = make().publish()
    assert song.file("score/original.gp").read_bytes() == b"gp"
    for bad in ("../x", "/etc/passwd", "score/../../x"):
        with pytest.raises(PackageError):
            song.file(bad)


def test_stems_are_published_whole_or_not_at_all():
    song = make().publish()

    def broken(folder):
        (folder / "guitar.flac").write_bytes(b"half")
        raise RuntimeError("caiu no meio")

    with pytest.raises(RuntimeError):
        song.add_stems("demucs6s-aaaa", broken)
    assert list((song.path / "stems").iterdir()) == []
    assert song.manifest["stems"] == {}

    def good(folder):
        (folder / "guitar.flac").write_bytes(b"ok")
        return {"model": "htdemucs_6s", "device": "mps", "seconds": 1.0, "stems": {"guitar": {"file": "guitar.flac"}}}

    data = song.add_stems("demucs6s-aaaa", good)
    assert data["activeStems"] == "demucs6s-aaaa"
    assert data["stems"]["demucs6s-aaaa"]["files"] == {"guitar": "stems/demucs6s-aaaa/guitar.flac"}
    assert song.file("stems/demucs6s-aaaa/guitar.flac").read_bytes() == b"ok"
    with pytest.raises(PackageError):
        song.add_stems("../escape", good)


def test_unknown_schema_is_not_listed(scratch_home):
    song = make().publish()
    (song.path / "manifest.json").write_text('{"schema": 99, "id": "x"}')
    assert package.packages() == []


def test_a_broken_guitar_pro_is_refused_and_the_score_stays(scratch_home):
    """O motor só grava um Guitar Pro 7 inteiro: um zip quebrado, sem a partitura ou com o XML estragado tomaria o
    lugar da partitura da música (a próxima abertura e a síntese falhariam)."""
    import io
    import zipfile

    fixtures = Path(__file__).resolve().parents[2] / "web" / "tests" / "fixtures"
    draft = package.Draft("Teste", "Banda", {})
    draft.file("score/original.gp").write_bytes((fixtures / "quatro-por-quatro.gp").read_bytes())
    draft.manifest["score"] = {"file": "score/original.gp", "measures": 4, "tracks": []}
    song = draft.publish()
    for name, bars in (("notacao.gp", 24), ("combinacoes.gp", 32), ("seis-por-oito.gp", 3), ("quatro-por-quatro.gp", 4)):
        assert song.save_score((fixtures / name).read_bytes())["measures"] == bars
    kept, manifest = song.file("score/edited.gp").read_bytes(), song.manifest

    def archive(files: dict) -> bytes:
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as made:
            for path, content in files.items():
                made.writestr(path, content)
        return buffer.getvalue()

    good = (fixtures / "notacao.gp").read_bytes()
    for bad in (b"PKbroken", archive({"outro.txt": "x"}), good[: len(good) // 2],
                archive({"Content/score.gpif": "<GPIF><MasterBars>"}),
                archive({"Content/score.gpif": "<GPIF><MasterBars/></GPIF>"}),
                archive({"Content/score.gpif": "<html/>"})):
        with pytest.raises(PackageError, match="Guitar Pro 7"):
            song.save_score(bad)
        assert song.file("score/edited.gp").read_bytes() == kept and song.manifest == manifest
