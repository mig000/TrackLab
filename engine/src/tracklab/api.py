"""A API local do motor, só em 127.0.0.1: o app nativo pede, a fila pesada executa, o progresso chega por SSE."""

from __future__ import annotations

import platform

from fastapi import Body, FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from . import __version__, home, package, songsterr, stems, tempomap
from .errors import PackageError, TrackLabError
from .jobs import JobManager
from .media.peaks import peaks
from .util import atomic_json, read_json

PEAKS_PER_SECOND = 200


class ImportRequest(BaseModel):
    url: str
    separate: bool = True


def create_app(jobs: JobManager | None = None, *, source: songsterr.Source | None = None, separate_run=None) -> FastAPI:
    jobs = jobs or JobManager(home.home())
    app = FastAPI(title="TrackLab", version=__version__)
    app.state.jobs = jobs

    def song(song_id: str) -> package.SongPackage:
        try:
            return package.find(song_id)
        except PackageError as error:
            raise HTTPException(404, str(error)) from None

    def separation(song_id: str):
        def work(progress, cancel):
            return stems.separate_song(package.find(song_id), progress=progress, cancel=cancel, run=separate_run)
        return work

    @app.exception_handler(TrackLabError)
    def expected(_request, error: TrackLabError):
        from fastapi.responses import JSONResponse

        return JSONResponse({"detail": str(error)}, status_code=400)

    @app.get("/api/info")
    def info() -> dict:
        return {"version": __version__, "home": str(home.home()), "songs": str(home.songs()),
                "machine": platform.machine(), "device": _device()}

    @app.get("/api/songsterr/search")
    def search(q: str) -> dict:
        return {"results": songsterr.search(q)}

    @app.post("/api/songs/import", status_code=202)
    def import_song(request: ImportRequest) -> dict:
        songsterr.song_id(request.url)   # recusa já, antes da fila, o que não é do Songsterr

        def work(progress, cancel):
            made = songsterr.import_song(request.url, source=source, progress=progress, cancel=cancel)
            result = {"song": made.summary()}
            if request.separate and made.manifest.get("audio"):
                try:
                    result["stems"] = stems.separate_song(made, progress=progress, cancel=cancel, run=separate_run)
                except TrackLabError as error:
                    # A música já está no repertório; a separação pode ser pedida de novo depois.
                    made.update(lambda data: data["warnings"].append(f"Faixas não separadas: {error}"))
                    result["warning"] = str(error)
            return result

        return _job(jobs.submit("import", work))

    @app.get("/api/songs")
    def songs() -> dict:
        return {"songs": [item.summary() for item in package.packages()]}

    @app.get("/api/songs/{song_id}")
    def song_detail(song_id: str) -> dict:
        found = song(song_id)
        return {**found.manifest, "folder": str(found.path)}

    @app.get("/api/songs/{song_id}/tempo-map")
    def tempo_map(song_id: str) -> dict:
        found = song(song_id)
        entry = found.manifest.get("tempoMap")
        if not entry:
            raise HTTPException(404, "Esta música ainda não tem mapa de tempo.")
        return read_json(found.file(entry["file"]))

    @app.get("/api/songs/{song_id}/tempo-map/original")
    def original_tempo_map(song_id: str) -> dict:
        """O mapa como veio do Songsterr, para recomeçar o Ajuste (o app o grava com `PUT`, que guarda o atual)."""
        found = song(song_id).original_tempo_map()
        if found is None:
            raise HTTPException(404, "Esta música ainda não tem mapa de tempo.")
        return found

    @app.post("/api/songs/{song_id}/tempo-map/edit")
    def edit_tempo_map(song_id: str, gesture: dict = Body(...)) -> dict:
        """Um gesto do Ajuste sobre o mapa gravado (`tempomap.anchor_edit`: move ou release de uma batida); o
        resultado é gravado e devolvido."""
        found = song(song_id)
        current = tempo_map(song_id)
        return found.save_tempo_map(tempomap.anchor_edit({**gesture, "tempoMap": current}))

    @app.put("/api/songs/{song_id}/tempo-map")
    def put_tempo_map(song_id: str, document: dict = Body(...)) -> dict:
        """Um mapa inteiro no lugar do gravado (o Desfazer e o Refazer do app), conferido antes."""
        found = song(song_id)
        return found.save_tempo_map(tempomap.normalize_tempo_map(document))

    @app.put("/api/songs/{song_id}/checked")
    def checked(song_id: str, body: dict = Body(...)) -> dict:
        """Os compassos conferidos no Ajuste (`{"bars": [1, 2, …]}`), no lugar dos que estavam."""
        if not isinstance(body.get("bars"), list):
            raise HTTPException(400, "Envie os compassos conferidos em bars.")
        return {"bars": song(song_id).set_checked_bars(body["bars"])}

    @app.get("/api/songs/{song_id}/files/{relative:path}")
    def song_file(song_id: str, relative: str):
        found = song(song_id)
        path = found.file(relative)
        if relative == package.MANIFEST or not path.is_file():
            raise HTTPException(404, "Arquivo não encontrado no pacote.")
        return FileResponse(path)

    @app.get("/api/songs/{song_id}/peaks")
    def song_peaks(song_id: str, stem: str | None = None) -> dict:
        """A onda da Fita: do áudio original, ou de uma faixa da separação ativa; guardada em `peaks/`."""
        found = song(song_id)
        manifest = found.manifest
        if stem is None:
            if not manifest.get("audio"):
                raise HTTPException(404, "Esta música não tem áudio.")
            relative, name = manifest["audio"]["file"], "source"
        else:
            active = manifest.get("stems", {}).get(manifest.get("activeStems") or "", {})
            relative = active.get("files", {}).get(stem)
            if relative is None:
                raise HTTPException(404, f"Não há a faixa {stem} na separação ativa.")
            name = f"{manifest['activeStems']}-{stem}"
        cache = found.file(f"peaks/{name}.json")
        if cache.is_file():
            return read_json(cache)
        drawn = peaks(found.file(relative), PEAKS_PER_SECOND)
        atomic_json(cache, drawn)
        return drawn

    @app.post("/api/songs/{song_id}/separate", status_code=202)
    def separate(song_id: str) -> dict:
        song(song_id)
        return _job(jobs.submit("separate", separation(song_id), project=song_id))

    @app.get("/api/jobs")
    def recent() -> dict:
        return {"jobs": [_job(job) for job in jobs.recent()]}

    @app.get("/api/jobs/{job_id}")
    def job(job_id: str) -> dict:
        found = jobs.get(job_id)
        if found is None:
            raise HTTPException(404, "Tarefa não encontrada.")
        return found.to_dict()

    @app.get("/api/jobs/{job_id}/events")
    def events(job_id: str):
        if jobs.get(job_id) is None:
            raise HTTPException(404, "Tarefa não encontrada.")
        return StreamingResponse(jobs.sse(job_id), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache"})

    @app.post("/api/jobs/{job_id}/cancel")
    def cancel(job_id: str) -> dict:
        return {"cancelled": jobs.cancel(job_id)}

    return app


def _job(job) -> dict:
    return {"id": job.id, "kind": job.kind, "status": job.status, "project": job.project}


def _device() -> str:
    try:
        import torch
    except ImportError:
        return "sem torch"
    return "mps" if torch.backends.mps.is_available() else "cpu"


__all__ = ["create_app"]
