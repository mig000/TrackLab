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


def test_takes_become_mp3_and_the_manifest_follows(tmp_path):
    import numpy as np
    import soundfile

    from tracklab import package

    draft = package.Draft("Música", "Artista", {"kind": "teste"})
    song = draft.publish()
    folder = song.path / "takes"
    folder.mkdir(exist_ok=True)
    rate = 48000
    tone = (0.3 * np.sin(np.arange(rate * 2) / rate * 2 * np.pi * 330)).astype("float32")
    soundfile.write(str(folder / "t1.caf"), np.stack([tone, tone], axis=1), rate, format="CAF", subtype="FLOAT")
    listed = song.set_takes([{"id": "t1", "lane": 1, "start": 1.0, "length": 2.0}], compress=False)
    assert listed[0]["file"] == "takes/t1.caf"
    assert song.compress_takes() == ["t1"]
    assert not (folder / "t1.caf").exists() and (folder / "t1.mp3").is_file()
    assert package.find(song.manifest["id"]).manifest["takes"][0]["file"] == "takes/t1.mp3"
    again = song.set_takes([{"id": "t1", "lane": 2, "start": 1.0, "length": 2.0}], compress=False)
    assert again[0]["file"] == "takes/t1.mp3" and again[0]["lane"] == 2


def test_an_old_song_moves_to_mp3_and_keeps_its_stem_keys(tmp_path):
    import json

    import numpy as np
    import soundfile

    from tracklab import migrate, package, stems

    draft = package.Draft("Música", "Artista", {"kind": "teste"})
    rate = 48000
    tone = (0.3 * np.sin(np.arange(rate * 3) / rate * 2 * np.pi * 220)).astype("float32")
    soundfile.write(str(draft.file("audio/source.flac")), np.stack([tone, tone], axis=1), rate, format="FLAC")
    draft.manifest["audio"] = {"file": "audio/source.flac", "sha256": "velho"}
    song = draft.publish()
    folder = song.path / "stems" / "demucs6s-abc"
    folder.mkdir(parents=True)
    soundfile.write(str(folder / "guitar.flac"), np.stack([tone, tone], axis=1), rate, format="FLAC")
    (folder / "receipt.json").write_text(json.dumps({"stems": {"guitar": {"file": "guitar.flac"}}}))
    song.update(lambda data: data.__setitem__("stems", {"demucs6s-abc": {"files": {"guitar": "stems/demucs6s-abc/guitar.flac"}}}))
    key_before = stems.demucs_key(stems.audio_id(song.manifest["audio"]), "v")
    report = migrate.song_to_mp3(song, tmp_path / "Lixeira", say=lambda _: None)
    manifest = package.SongPackage(song.path).manifest
    assert report["files"] == 2
    assert manifest["audio"]["file"] == "audio/source.mp3" and manifest["audio"]["id"] == "velho"
    assert manifest["stems"]["demucs6s-abc"]["files"]["guitar"] == "stems/demucs6s-abc/guitar.mp3"
    assert json.loads((folder / "receipt.json").read_text())["stems"]["guitar"]["file"] == "guitar.mp3"
    assert stems.demucs_key(stems.audio_id(manifest["audio"]), "v") == key_before
    assert not list(song.path.rglob("*.flac")) and (tmp_path / "Lixeira" / song.path.name / "audio" / "source.flac").is_file()
    got, _ = soundfile.read(str(song.path / "audio" / "source.mp3"), dtype="float32")
    assert abs(len(got) - len(tone)) <= 1152
