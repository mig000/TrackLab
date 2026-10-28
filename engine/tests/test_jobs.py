import asyncio
import json
import threading
import time

import pytest

from tracklab import util
from tracklab.errors import JobCancelled, JobError, MediaError
from tracklab.jobs import FINAL, INTERRUPTED, Cancel, Job, JobManager

TIMEOUT = 5.0


@pytest.fixture
def manager(tmp_path):
    jobs = JobManager(tmp_path)
    yield jobs
    jobs.close()


def run_to_end(manager, job_id, *, after=0, timeout=TIMEOUT):
    """Coleta eventos com wait até o evento final; falha em vez de travar."""
    events: list[dict] = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        events += manager.wait(job_id, events[-1]["seq"] if events else after, 0.5)
        if events and events[-1]["status"] in FINAL:
            return events
    raise AssertionError(f"a tarefa {job_id} não terminou em {timeout} s")


def gate():
    event = threading.Event()
    return event, lambda: event.wait(TIMEOUT) or pytest.fail("portão não liberado a tempo")


def record(tmp_path, job_id):
    return util.read_json(tmp_path / "jobs" / f"{job_id}.json")


def test_events_in_order_with_growing_seq_and_result(manager, tmp_path):
    def work(progress, cancel):
        progress("detect", "Analisando o áudio…", 0.25)
        progress("refine", "Refinando…", 0.75)
        return {"notes": 3}

    submitted = manager.submit("transcribe", work, project="demo-abc123")
    assert submitted.status == "queued"
    assert [e["status"] for e in submitted.events] == ["queued"]
    events = run_to_end(manager, submitted.id)
    assert [e["seq"] for e in events] == [1, 2, 3, 4, 5]
    assert [e["stage"] for e in events] == ["queue", "start", "detect", "refine", "done"]
    assert [e["status"] for e in events] == ["queued", "running", "running", "running", "done"]
    assert [e["progress"] for e in events] == [None, None, 0.25, 0.75, 1.0]
    assert set(events[0]) == {"seq", "time", "stage", "message", "progress", "status"}
    job = manager.get(submitted.id)
    assert job.status == "done"
    assert job.result == {"notes": 3}
    assert job.project == "demo-abc123"
    assert job.started and job.finished
    assert job.error is None
    assert record(tmp_path, job.id) == job.to_dict()


def test_wait_returns_only_new_events(manager):
    step, wait_step = gate()

    def work(progress, cancel):
        progress("detect", "primeiro", 0.1)
        wait_step()
        progress("detect", "segundo", 0.9)
        return None

    job = manager.submit("demo", work)
    seen: list[dict] = []
    while not seen or seen[-1]["message"] != "primeiro":
        seen += manager.wait(job.id, seen[-1]["seq"] if seen else 0, TIMEOUT)
    assert [e["seq"] for e in seen] == [1, 2, 3]
    # Nada novo: wait bloqueia até o timeout e volta vazio.
    started = time.monotonic()
    assert manager.wait(job.id, 3, 0.2) == []
    assert time.monotonic() - started >= 0.15
    step.set()
    rest = run_to_end(manager, job.id, after=3)
    assert [(e["seq"], e["message"]) for e in rest] == [(4, "segundo"), (5, "Concluído.")]
    assert manager.get(job.id).result is None
    # Job terminado: wait volta na hora, vazio, quando não há nada depois do último evento.
    started = time.monotonic()
    assert manager.wait(job.id, 5, TIMEOUT) == []
    assert time.monotonic() - started < 1.0


def test_cancel_in_the_middle(manager, tmp_path):
    running = threading.Event()
    proceed, wait_proceed = gate()

    def work(progress, cancel):
        progress("detect", "passo 1", 0.5)
        running.set()
        wait_proceed()
        cancel.check()
        progress("refine", "passo 2", 1.0)
        return {"never": True}

    job = manager.submit("demo", work)
    assert running.wait(TIMEOUT)
    assert manager.cancel(job.id) is True
    proceed.set()
    events = run_to_end(manager, job.id)
    assert events[-1]["status"] == "cancelled"
    assert events[-1]["message"] == "Cancelada pelo usuário."
    assert "passo 2" not in [e["message"] for e in events]
    finished = manager.get(job.id)
    assert finished.status == "cancelled"
    assert finished.result is None
    assert manager.cancel(job.id) is False
    assert record(tmp_path, job.id) == finished.to_dict()


def test_cancel_queued_job_never_runs(manager):
    release, wait_release = gate()
    ran = []

    def blocker(progress, cancel):
        wait_release()
        return {"ok": 1}

    def queued_work(progress, cancel):
        ran.append("queued")
        return None

    first = manager.submit("demo", blocker)
    second = manager.submit("demo", queued_work)
    third = manager.submit("demo", lambda progress, cancel: {"ok": 3})
    assert manager.cancel(second.id) is True
    cancelled = manager.get(second.id)
    assert cancelled.status == "cancelled"
    assert [e["status"] for e in cancelled.events] == ["queued", "cancelled"]
    assert cancelled.started is None
    release.set()
    assert run_to_end(manager, first.id)[-1]["status"] == "done"
    # FIFO: se o segundo ainda estivesse na fila, rodaria antes do terceiro.
    assert run_to_end(manager, third.id)[-1]["status"] == "done"
    assert ran == []
    assert manager.cancel("job-inexistente") is False


def test_tracklab_error_becomes_error_with_message(manager, tmp_path):
    def work(progress, cancel):
        raise MediaError("O arquivo tem 6 canais; escolha um ou dois.")

    job = manager.submit("import", work)
    events = run_to_end(manager, job.id)
    finished = manager.get(job.id)
    assert finished.status == "error"
    assert finished.error == "O arquivo tem 6 canais; escolha um ou dois."
    assert events[-1]["message"] == finished.error
    assert events[-1]["status"] == "error"
    assert finished.traceback is None
    assert record(tmp_path, job.id) == finished.to_dict()


def test_generic_exception_becomes_internal_failure_with_traceback_on_disk(manager, tmp_path):
    def work(progress, cancel):
        raise RuntimeError("detalhe que não vai para a interface")

    job = manager.submit("import", work)
    run_to_end(manager, job.id)
    finished = manager.get(job.id)
    assert finished.status == "error"
    assert finished.error == "Falha interna: RuntimeError"
    assert finished.events[-1]["message"] == "Falha interna: RuntimeError"
    on_disk = record(tmp_path, job.id)
    assert "Traceback" in on_disk["traceback"]
    assert "RuntimeError: detalhe que não vai para a interface" in on_disk["traceback"]
    assert on_disk == finished.to_dict()


def test_result_that_is_not_json_is_internal_failure(manager):
    job = manager.submit("demo", lambda progress, cancel: {"bad": float("nan")})
    run_to_end(manager, job.id)
    assert manager.get(job.id).error == "Falha interna: ValueError"
    other = manager.submit("demo", lambda progress, cancel: [1, 2])
    run_to_end(manager, other.id)
    assert manager.get(other.id).error == "Falha interna: TypeError"


def test_progress_fraction_is_clamped_and_late_progress_ignored(manager):
    saved = {}

    def work(progress, cancel):
        progress("detect", "acima", 3.0)
        progress("detect", "abaixo", -1)
        progress("detect", "nan", float("nan"))
        saved["progress"] = progress
        return None

    job = manager.submit("demo", work)
    events = run_to_end(manager, job.id)
    assert [e["progress"] for e in events[2:5]] == [1.0, 0.0, None]
    saved["progress"]("detect", "depois do fim", 0.5)
    assert manager.get(job.id).events == events


def test_restart_marks_pending_records_as_error(tmp_path):
    folder = tmp_path / "jobs"
    event = {"seq": 1, "time": util.now_iso(), "stage": "queue", "message": "Aguardando na fila…", "progress": None, "status": "queued"}
    queued = Job(id="job-aaaaaaaaaaaa", kind="transcribe", project="p-1", status="queued",
                 created="2026-10-12T10:00:00+00:00", events=[event])
    running = Job(id="job-bbbbbbbbbbbb", kind="transcribe", project="p-1", status="running", created="2026-10-12T10:01:00+00:00",
                  started="2026-10-12T10:01:01+00:00", events=[event, {**event, "seq": 2, "stage": "detect", "status": "running"}])
    done = Job(id="job-cccccccccccc", kind="import", project="p-2", status="done", created="2026-10-12T09:00:00+00:00",
               finished="2026-10-12T09:00:05+00:00", events=[{**event, "status": "done", "stage": "done"}], result={"ok": True})
    for job in (queued, running, done):
        util.atomic_json(folder / f"{job.id}.json", job.to_dict())
    (folder / "job-quebrado.json").write_text("{não é json")

    manager = JobManager(tmp_path)
    try:
        for job_id, previous in ((queued.id, 1), (running.id, 2)):
            restored = manager.get(job_id)
            assert restored.status == "error"
            assert restored.error == INTERRUPTED
            assert restored.finished is not None
            assert restored.events[-1]["seq"] == previous + 1
            assert restored.events[-1]["status"] == "error"
            assert restored.events[-1]["message"] == INTERRUPTED
            assert record(tmp_path, job_id) == restored.to_dict()
        assert manager.get(done.id).to_dict() == done.to_dict()
        assert record(tmp_path, done.id) == done.to_dict()
        assert manager.get("job-quebrado") is None
        assert [job.id for job in manager.recent()] == [running.id, queued.id, done.id]
        assert [job.id for job in manager.recent(project="p-2")] == [done.id]
        # Um registro terminado não bloqueia quem espera eventos.
        assert manager.wait(running.id, 3, TIMEOUT) == []
    finally:
        manager.close()


def test_recent_newest_first_with_filter_and_limit(manager):
    ids = [manager.submit("demo", lambda progress, cancel: None, project="a" if n % 2 else "b").id for n in range(5)]
    for job_id in ids:
        run_to_end(manager, job_id)
    assert [job.id for job in manager.recent()] == ids[::-1]
    assert [job.id for job in manager.recent(project="a")] == [ids[3], ids[1]]
    assert [job.id for job in manager.recent(limit=2)] == [ids[4], ids[3]]


def test_sse_ends_with_final_event(manager):
    def work(progress, cancel):
        progress("detect", "Analisando o áudio…", 0.5)
        return {"notes": 1}

    job = manager.submit("demo", work)

    async def collect():
        return [chunk async for chunk in manager.sse(job.id)]

    chunks = asyncio.run(asyncio.wait_for(collect(), TIMEOUT))
    data = [json.loads(chunk[len("data: "):]) for chunk in chunks if chunk.startswith("data: ")]
    assert all(chunk.endswith("\n\n") for chunk in chunks)
    assert [e["seq"] for e in data] == [1, 2, 3, 4]
    assert data[-1]["status"] == "done"
    assert data[2]["message"] == "Analisando o áudio…"
    # Depois do fim, um novo cliente recebe o histórico inteiro e o fluxo termina.
    again = asyncio.run(asyncio.wait_for(collect(), TIMEOUT))
    assert again == chunks


def test_sse_sends_keep_alive_while_nothing_changes(manager):
    release, wait_release = gate()
    manager.keepalive = 0.05

    def work(progress, cancel):
        wait_release()
        return None

    job = manager.submit("demo", work)

    async def collect():
        chunks = []
        async for chunk in manager.sse(job.id):
            chunks.append(chunk)
            if chunk == ": keep-alive\n\n":
                release.set()
        return chunks

    chunks = asyncio.run(asyncio.wait_for(collect(), TIMEOUT))
    assert ": keep-alive\n\n" in chunks
    assert json.loads(chunks[-1][len("data: "):])["status"] == "done"


def test_cancel_protocol_and_closed_manager(tmp_path):
    cancel = Cancel()
    cancel.check()
    cancel.requested = True
    with pytest.raises(JobCancelled):
        cancel.check()
    manager = JobManager(tmp_path)
    manager.close()
    with pytest.raises(JobError):
        manager.submit("demo", lambda progress, cancel: None)
    with pytest.raises(JobError):
        manager.wait("job-inexistente", 0, 0.1)
