"""Tarefas em segundo plano: um único worker, porque os modelos disputam a GPU; progresso em memória, em disco e por SSE."""

from __future__ import annotations

import asyncio
import collections
import copy
import dataclasses
import json
import logging
import math
import threading
from dataclasses import dataclass, field
from pathlib import Path
from traceback import format_exc
from typing import AsyncIterator, Callable

from tracklab.errors import JobCancelled, JobError, TrackLabError
from tracklab.util import atomic_json, new_id, now_iso, read_json

log = logging.getLogger(__name__)

Progress = Callable[[str, str, float | None], None]   # progress(stage, message, fraction)

ACTIVE = frozenset({"queued", "running"})
FINAL = frozenset({"done", "error", "cancelled"})
INTERRUPTED = "Interrompida ao reiniciar o TrackLab."
KEEPALIVE_S = 10.0
CLOSE_TIMEOUT_S = 10.0


@dataclass
class Job:
    id: str
    kind: str
    project: str | None
    status: str          # queued | running | done | error | cancelled
    created: str
    started: str | None = None
    finished: str | None = None
    events: list[dict] = field(default_factory=list)
    error: str | None = None
    result: dict | None = None
    traceback: str | None = None   # só em falha interna; é o que permite diagnosticar sem reproduzir

    def to_dict(self) -> dict:
        """Forma gravada em disco e devolvida pela API; uma cópia, nunca o estado vivo."""
        return dataclasses.asdict(self)


class Cancel:
    """Pedido de cancelamento que o trabalho consulta entre etapas; cumpre o protocolo `Cancel` do contrato."""

    def __init__(self) -> None:
        self.requested = False

    def check(self) -> None:
        """Levanta JobCancelled quando o usuário pediu para parar."""
        if self.requested:
            raise JobCancelled()


Work = Callable[[Progress, Cancel], dict | None]


class JobManager:
    """Fila FIFO com um worker; cada evento é acrescentado ao job e gravado em `<home>/jobs/<id>.json`."""

    def __init__(self, home: Path):
        self.folder = Path(home) / "jobs"
        self.folder.mkdir(parents=True, exist_ok=True)
        self.keepalive = KEEPALIVE_S
        # Um só lock protege jobs, fila e disco: as gravações nunca disputam o mesmo arquivo temporário.
        self._changed = threading.Condition()
        self._jobs: dict[str, Job] = {}
        self._cancels: dict[str, Cancel] = {}
        self._works: dict[str, Work] = {}
        self._pending: collections.deque[str] = collections.deque()
        self._closed = False
        with self._changed:
            self._load()
        self._worker = threading.Thread(target=self._serve, name="tracklab-jobs", daemon=True)
        self._worker.start()

    def submit(self, kind: str, work: Work, *, project: str | None = None) -> Job:
        """Enfileira e devolve na hora, com status queued e o evento inicial."""
        job = Job(id=new_id("job"), kind=kind, project=project, status="queued", created=now_iso())
        with self._changed:
            if self._closed:
                raise JobError("As tarefas em segundo plano foram encerradas.")
            self._jobs[job.id] = job
            self._cancels[job.id] = Cancel()
            self._works[job.id] = work
            self._pending.append(job.id)
            self._emit(job, "queue", "Aguardando na fila…", None)
            return copy.deepcopy(job)

    def get(self, job_id: str) -> Job | None:
        """Cópia do job, ou None se o identificador não existe."""
        with self._changed:
            job = self._jobs.get(job_id)
            return copy.deepcopy(job) if job is not None else None

    def recent(self, *, project: str | None = None, limit: int = 20) -> list[Job]:
        """Os mais novos primeiro, inclusive os de execuções anteriores lidos do disco."""
        with self._changed:
            jobs = [job for job in reversed(self._jobs.values()) if project is None or job.project == project]
            return [copy.deepcopy(job) for job in jobs[:max(limit, 0)]]

    def cancel(self, job_id: str) -> bool:
        """Pede o cancelamento; um job na fila sai dela e termina já, um em execução para no próximo `check()`."""
        with self._changed:
            job = self._jobs.get(job_id)
            if job is None or job.status not in ACTIVE:
                return False
            self._cancels[job_id].requested = True
            if job.status == "queued":
                self._pending.remove(job_id)
                self._finish(job, "cancelled", str(JobCancelled()))
            return True

    def wait(self, job_id: str, after: int, timeout: float) -> list[dict]:
        """Eventos com seq > after; bloqueia até haver algum, até o job terminar ou até `timeout` segundos."""
        with self._changed:
            job = self._jobs.get(job_id)
            if job is None:
                raise JobError(f"Tarefa não encontrada: {job_id}.")
            self._changed.wait_for(lambda: _last_seq(job) > after or job.status in FINAL, timeout)
            return [dict(event) for event in job.events if event["seq"] > after]

    async def sse(self, job_id: str) -> AsyncIterator[str]:
        """Eventos no formato SSE até o evento final; um comentário de keep-alive quando nada muda."""
        sent = 0
        while True:
            new = await asyncio.to_thread(self.wait, job_id, sent, self.keepalive)
            for event in new:
                yield f"data: {json.dumps(event, ensure_ascii=False)}\n\n"
                sent = event["seq"]
            if new and new[-1]["status"] in FINAL:
                return
            if not new:
                if self._ended(job_id):
                    return
                yield ": keep-alive\n\n"

    def close(self) -> None:
        """Encerra o worker: pede o cancelamento do job em execução e não começa mais nenhum."""
        with self._changed:
            self._closed = True
            for job in self._jobs.values():
                if job.status == "running":
                    self._cancels[job.id].requested = True
            self._changed.notify_all()
        self._worker.join(timeout=CLOSE_TIMEOUT_S)

    # Worker

    def _serve(self) -> None:
        while True:
            with self._changed:
                self._changed.wait_for(lambda: bool(self._pending) or self._closed)
                if self._closed:
                    return
                job = self._jobs[self._pending.popleft()]
                work = self._works.pop(job.id)
                cancel = self._cancels[job.id]
                job.status = "running"
                job.started = now_iso()
                self._emit(job, "start", "Iniciando…", None)
            self._execute(job, work, cancel)

    def _execute(self, job: Job, work: Work, cancel: Cancel) -> None:
        """Roda o trabalho fora do lock e sempre termina com um evento final; o worker nunca morre por um job."""

        def progress(stage: str, message: str, fraction: float | None = None) -> None:
            self._progress(job, stage, message, fraction)

        try:
            result = _normalized(work(progress, cancel))
        except JobCancelled as exc:
            outcome = {"status": "cancelled", "message": str(exc)}
        except TrackLabError as exc:
            outcome = {"status": "error", "message": str(exc), "error": str(exc)}
        except Exception as exc:
            log.exception("Tarefa %s (%s) falhou", job.id, job.kind)
            message = f"Falha interna: {type(exc).__name__}"
            outcome = {"status": "error", "message": message, "error": message, "trace": format_exc()}
        else:
            outcome = {"status": "done", "message": "Concluído.", "result": result}
        with self._changed:
            self._finish(job, **outcome)

    def _progress(self, job: Job, stage: str, message: str, fraction: float | None) -> None:
        value = _fraction(fraction)
        with self._changed:
            if job.status != "running":   # um aviso atrasado depois do fim não reabre o job
                return
            self._emit(job, str(stage), str(message), value)

    # Estado (sempre com o lock)

    def _finish(self, job: Job, status: str, message: str, *, error: str | None = None,
                result: dict | None = None, trace: str | None = None) -> None:
        job.status = status
        job.finished = now_iso()
        job.error = error
        job.result = result
        job.traceback = trace
        self._works.pop(job.id, None)
        self._cancels.pop(job.id, None)
        self._emit(job, status, message, 1.0 if status == "done" else None)

    def _emit(self, job: Job, stage: str, message: str, fraction: float | None) -> None:
        job.events.append({"seq": _last_seq(job) + 1, "time": now_iso(), "stage": stage,
                           "message": message, "progress": fraction, "status": job.status})
        self._persist(job)
        self._changed.notify_all()

    def _persist(self, job: Job) -> None:
        try:
            atomic_json(self.folder / f"{job.id}.json", job.to_dict())
        except (OSError, TypeError, ValueError):
            # Disco cheio não derruba o worker: o estado em memória continua certo.
            log.exception("Não consegui gravar o registro da tarefa %s", job.id)

    def _ended(self, job_id: str) -> bool:
        with self._changed:
            job = self._jobs.get(job_id)
            return job is None or job.status in FINAL

    def _load(self) -> None:
        """Lê os registros de execuções anteriores; os que estavam na fila ou rodando viram erro."""
        loaded = [job for job in map(_read_job, sorted(self.folder.glob("*.json"))) if job is not None]
        for job in sorted(loaded, key=lambda item: (item.created, item.id)):
            self._jobs[job.id] = job
            if job.status in ACTIVE:
                self._finish(job, "error", INTERRUPTED, error=INTERRUPTED)


def _read_job(path: Path) -> Job | None:
    names = {item.name for item in dataclasses.fields(Job)}
    try:
        raw = read_json(path)
        job = Job(**{key: value for key, value in raw.items() if key in names})
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        log.warning("Registro de tarefa ilegível ignorado: %s (%s)", path.name, exc)
        return None
    events_ok = isinstance(job.events, list) and all(isinstance(event, dict) and type(event.get("seq")) is int for event in job.events)
    if job.id != path.stem or not events_ok:
        log.warning("Registro de tarefa inconsistente ignorado: %s", path.name)
        return None
    return job


def _last_seq(job: Job) -> int:
    return int(job.events[-1]["seq"]) if job.events else 0


def _fraction(value: float | None) -> float | None:
    """Fração entre 0 e 1; o que não for número finito vira None (progresso indeterminado)."""
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):
        return None
    return min(max(number, 0.0), 1.0)


def _normalized(result: object) -> dict | None:
    """Passa o resultado por JSON para que memória e disco guardem exatamente o mesmo dicionário."""
    if result is None:
        return None
    if not isinstance(result, dict):
        raise TypeError(f"o trabalho devolveu {type(result).__name__}, não um dicionário")
    return json.loads(json.dumps(result, ensure_ascii=False, allow_nan=False))
