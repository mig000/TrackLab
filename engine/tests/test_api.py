"""A API do motor: importar pela fila, ver o pacote, a onda, o mapa e os arquivos; nada fora do pacote."""

import json
import time

import pytest
from fastapi.testclient import TestClient

from conftest import guitar_track
from test_songsterr import FakeSource
from test_stems import fake_run
from tracklab import package
from tracklab.api import create_app
from tracklab.jobs import FINAL, JobManager
from tracklab.media import separate as demucs


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(demucs, "separator_version", lambda model=demucs.MODEL: "v")
    jobs = JobManager(tmp_path / "jobs-home")
    app = create_app(jobs, source=FakeSource([guitar_track(2)], points=[0.0, 2.0, 4.0]), separate_run=fake_run([]))
    with TestClient(app) as test:
        yield test
    jobs.close()


def wait(client, job_id):
    for _ in range(100):
        job = client.get(f"/api/jobs/{job_id}").json()
        if job["status"] in FINAL:
            return job
        time.sleep(0.05)
    raise AssertionError("a tarefa não terminou")


def test_import_then_read_everything_back(client):
    started = client.post("/api/songs/import", json={"url": "https://www.songsterr.com/a/wsa/cream-x-tab-s27"})
    assert started.status_code == 202
    job = wait(client, started.json()["id"])
    assert job["status"] == "done", job
    song_id = job["result"]["song"]["id"]
    assert job["result"]["stems"]["key"].startswith("demucs6s-")
    listed = client.get("/api/songs").json()["songs"]
    assert [s["id"] for s in listed] == [song_id] and listed[0]["hasAudio"]
    detail = client.get(f"/api/songs/{song_id}").json()
    assert detail["score"]["measures"] == 2 and detail["activeStems"] == job["result"]["stems"]["key"]
    assert client.get(f"/api/songs/{song_id}/tempo-map").json()["points"][4]["seconds"] == 2.0
    gp = client.get(f"/api/songs/{song_id}/files/score/original.gp")
    assert gp.status_code == 200 and gp.content[:2] == b"PK"
    wave = client.get(f"/api/songs/{song_id}/peaks").json()
    assert wave["perSecond"] == 200 and len(wave["max"]) == pytest.approx(200 * 6, abs=2)
    guitar = client.get(f"/api/songs/{song_id}/peaks", params={"stem": "guitar"}).json()
    assert max(guitar["max"]) == pytest.approx(max(wave["max"]) * 0.5, abs=1e-3)
    assert client.get(f"/api/songs/{song_id}/peaks", params={"stem": "nada"}).status_code == 404
    for bad in ("manifest.json", "../../x", "score/nada.gp"):
        assert client.get(f"/api/songs/{song_id}/files/{bad}").status_code in (400, 404)
    events = client.get(f"/api/jobs/{job['id']}/events").text
    stages = [json.loads(line[6:])["stage"] for line in events.splitlines() if line.startswith("data: ")]
    assert stages[0] == "queue" and "songsterr" in stages and "separate" in stages and stages[-1] == "done"


def test_a_url_that_is_not_songsterr_is_refused_before_the_queue(client):
    response = client.post("/api/songs/import", json={"url": "https://example.com/x-s27"})
    assert response.status_code == 400 and "songsterr" in response.json()["detail"].lower()
    assert client.get("/api/jobs").json()["jobs"] == []


def test_unknown_song_and_job(client):
    assert client.get("/api/songs/song-nada").status_code == 404
    assert client.post("/api/songs/song-nada/separate").status_code == 404
    assert client.get("/api/jobs/job-nada").status_code == 404
    info = client.get("/api/info").json()
    assert info["version"] and info["songs"].endswith("Repertorio")


def test_tempo_map_gestures_are_saved_with_history_and_undone(client):
    started = client.post("/api/songs/import", json={"url": "https://www.songsterr.com/a/wsa/cream-x-tab-s27",
                                                     "separate": False})
    song_id = wait(client, started.json()["id"])["result"]["song"]["id"]
    original = client.get(f"/api/songs/{song_id}/tempo-map").json()
    beat = original["points"][2]
    moved = client.post(f"/api/songs/{song_id}/tempo-map/edit",
                        json={"action": "move", "tick": beat["tick"], "seconds": beat["seconds"] + 0.1}).json()
    anchor = next(p for p in moved["points"] if p["tick"] == beat["tick"])
    assert anchor["kind"] == "anchor" and anchor["seconds"] == pytest.approx(beat["seconds"] + 0.1)
    assert client.get(f"/api/songs/{song_id}/tempo-map").json() == moved
    found = package.find(song_id)
    history = sorted(found.file("score/tempo-map-history").glob("*.json"))
    assert len(history) == 1 and json.loads(history[0].read_text()) == original
    entry = client.get(f"/api/songs/{song_id}").json()["tempoMap"]
    assert entry["anchors"] == 1 and entry["points"] == len(moved["points"]) and entry["edited"]
    # Desfazer: o app manda o mapa de antes; o do gesto vai para o histórico.
    undone = client.put(f"/api/songs/{song_id}/tempo-map", json=original).json()
    assert undone["points"] == original["points"]
    assert len(list(found.file("score/tempo-map-history").glob("*.json"))) == 2
    assert client.get(f"/api/songs/{song_id}").json()["tempoMap"]["anchors"] == 0
    # Soltar a âncora deixa a batida onde está.
    again = client.post(f"/api/songs/{song_id}/tempo-map/edit",
                        json={"tick": beat["tick"], "seconds": beat["seconds"] + 0.1}).json()
    released = client.post(f"/api/songs/{song_id}/tempo-map/edit", json={"action": "release", "tick": beat["tick"]}).json()
    point = next(p for p in released["points"] if p["tick"] == beat["tick"])
    assert point["kind"] == "detected" and point["seconds"] == next(p for p in again["points"] if p["tick"] == beat["tick"])["seconds"]


def test_a_gesture_the_map_cannot_take_is_refused_and_nothing_changes(client):
    started = client.post("/api/songs/import", json={"url": "https://www.songsterr.com/a/wsa/cream-x-tab-s27",
                                                     "separate": False})
    song_id = wait(client, started.json()["id"])["result"]["song"]["id"]
    before = client.get(f"/api/songs/{song_id}/tempo-map").json()
    first, second = before["points"][1], before["points"][3]
    client.post(f"/api/songs/{song_id}/tempo-map/edit", json={"tick": second["tick"], "seconds": second["seconds"]})
    refused = client.post(f"/api/songs/{song_id}/tempo-map/edit", json={"tick": first["tick"], "seconds": second["seconds"] + 1})
    assert refused.status_code == 400 and "âncoras" in refused.json()["detail"]
    assert client.put(f"/api/songs/{song_id}/tempo-map", json={"points": [{"tick": 0, "seconds": 1}]}).status_code == 400
    assert client.post("/api/songs/song-nada/tempo-map/edit", json={"tick": 0, "seconds": 1}).status_code == 404
