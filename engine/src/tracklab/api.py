"""A API local do motor, só em 127.0.0.1: o app nativo pede, a fila pesada executa, o progresso chega por SSE."""

from __future__ import annotations

import platform

from fastapi import Body, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from . import __version__, home, multitracks, package, songsterr, stems, tempomap
from .errors import PackageError, TrackLabError
from .jobs import JobManager
from .media import mvsep
from .media.peaks import peaks
from .util import atomic_json, read_json

PEAKS_PER_SECOND = 200


class ImportRequest(BaseModel):
    url: str
    separate: bool = True


def create_app(jobs: JobManager | None = None, *, source: songsterr.Source | None = None, separate_run=None,
               mvsep_session=None, mvsep_pause=None) -> FastAPI:
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
        """Os resultados do Songsterr, cada um com a música da biblioteca de multitracks que é ela (ou null)."""
        return {"results": [{**item, "multitrack": multitracks.match(item["artist"], item["title"])}
                            for item in songsterr.search(q)]}

    @app.get("/api/multitracks")
    def multitrack_status() -> dict:
        """Onde está a biblioteca de multitracks, se o HD está ligado e quantas músicas o índice tem."""
        return multitracks.status()

    @app.post("/api/multitracks/scan", status_code=202)
    def multitrack_scan() -> dict:
        """Refaz o índice inteiro, na fila (o HD externo leva minutos)."""
        def work(progress, cancel):
            folder = multitracks.root()
            progress("multitracks", f"Lendo {folder}…", None)
            found = multitracks.scan(folder, progress=progress, cancel=cancel)
            return multitracks.build(found, folder)

        return _job(jobs.submit("multitracks", work))

    @app.get("/api/multitracks/search")
    def multitrack_search(q: str) -> dict:
        return {"results": multitracks.search(q)}

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
        return {**found.manifest, "folder": str(found.path), "synth": stems.synth_state(found)}

    @app.put("/api/songs/{song_id}/score")
    async def put_score(song_id: str, request: Request) -> dict:
        """A partitura editada na TAB (Guitar Pro 7 no corpo do pedido); o original do Songsterr fica guardado."""
        found = song(song_id)
        return {"score": found.save_score(await request.body())}

    @app.post("/api/songs/{song_id}/synth", status_code=202)
    def synth(song_id: str) -> dict:
        """A TAB sintetizada (todas as pistas, no mapa de tempo de agora), na fila."""
        song(song_id)

        def work(progress, cancel):
            return stems.synthesize_tab(package.find(song_id), progress=progress, cancel=cancel)

        return _job(jobs.submit("synth", work, project=song_id))

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

    @app.put("/api/songs/{song_id}/status")
    def status(song_id: str, body: dict = Body(...)) -> dict:
        """O estado de estudo da música."""
        return {"status": song(song_id).set_status(body.get("status"))}

    @app.put("/api/songs/{song_id}/sections")
    def sections(song_id: str, body: dict = Body(...)) -> dict:
        """Os trechos da música (nome, from e to em tiques, meta em %), no lugar dos que estavam; o treino fica."""
        return {"sections": song(song_id).set_sections(body.get("sections"))}

    @app.post("/api/songs/{song_id}/sections/{section_id}/practice")
    def practice(song_id: str, section_id: str, body: dict = Body(...)) -> dict:
        """Uma passada pelo trecho (`rate` em %, `clean`): guarda a hora, o histórico e o recorde."""
        return song(song_id).practice(section_id, body.get("rate"), bool(body.get("clean")))

    @app.put("/api/songs/{song_id}/checked")
    def checked(song_id: str, body: dict = Body(...)) -> dict:
        """Os compassos conferidos no Ajuste (`{"bars": [1, 2, …]}`), no lugar dos que estavam."""
        if not isinstance(body.get("bars"), list):
            raise HTTPException(400, "Envie os compassos conferidos em bars.")
        return {"bars": song(song_id).set_checked_bars(body["bars"])}

    @app.get("/api/songs/{song_id}/multitrack")
    def song_multitrack(song_id: str) -> dict:
        """A música da biblioteca de multitracks que é esta (mesmo título e artista), ou null."""
        manifest = song(song_id).manifest
        return {"multitrack": multitracks.match(manifest.get("artist") or "", manifest.get("title") or "")}

    @app.post("/api/songs/{song_id}/stems/multitrack", status_code=202)
    def stems_multitrack(song_id: str, body: dict = Body(default={})) -> dict:
        """As faixas da multitrack (`path` do índice; sem ele, a que casa com a música) alinhadas ao vídeo, na fila."""
        manifest = song(song_id).manifest
        wanted = body.get("path")
        entry = (multitracks.by_path(str(wanted)) if wanted
                 else multitracks.match(manifest.get("artist") or "", manifest.get("title") or ""))
        if entry is None:
            raise HTTPException(404, "Esta música não está na biblioteca de multitracks.")

        def work(progress, cancel):
            return stems.import_multitrack(package.find(song_id), entry, progress=progress, cancel=cancel)

        return _job(jobs.submit("multitrack", work, project=song_id))

    @app.get("/api/mvsep")
    def mvsep_usage() -> dict:
        """Quantas conversões do MVSEP o TrackLab já usou hoje e os modelos que ele sabe pedir."""
        return {**mvsep.usage(), "models": [{"id": k, "name": v["name"]} for k, v in mvsep.MODELS.items()]}

    @app.post("/api/songs/{song_id}/stems/mvsep", status_code=202)
    def stems_mvsep(song_id: str, body: dict = Body(default={}),
                    x_mvsep_key: str | None = Header(default=None)) -> dict:
        """A guitarra do MVSEP (`model` 31 ou 101) com o resto pelo Demucs local, na fila; a chave vem no cabeçalho
        `X-MVSEP-Key` e só vive na tarefa."""
        song(song_id)
        model = mvsep.check_model(body.get("model", 31))
        key = mvsep.check_key(x_mvsep_key)

        def work(progress, cancel):
            return stems.separate_mvsep(package.find(song_id), key=key, model=model, progress=progress, cancel=cancel,
                                        session=mvsep_session, demucs_run=separate_run, pause=mvsep_pause)

        return _job(jobs.submit("mvsep", work, project=song_id))

    @app.put("/api/songs/{song_id}/stems/active")
    def active_stems(song_id: str, body: dict = Body(...)) -> dict:
        """A separação que o app toca (`{"key": …}`)."""
        return {"activeStems": song(song_id).set_active_stems(str(body.get("key") or ""))}

    @app.get("/api/songs/{song_id}/files/{relative:path}")
    def song_file(song_id: str, relative: str):
        found = song(song_id)
        path = found.file(relative)
        if relative == package.MANIFEST or not path.is_file():
            raise HTTPException(404, "Arquivo não encontrado no pacote.")
        return FileResponse(path)

    @app.get("/api/songs/{song_id}/spectrum")
    def song_spectrum(song_id: str, stem: str | None = None):
        """O espectro da Fita (media/spectrum.py) do áudio original ou de uma faixa da separação ativa, em bytes
        (quadros × linhas); as medidas vão nos cabeçalhos X-Frames, X-Rows, X-Hop, X-Low e X-Per-Semitone. Calculado
        uma vez e guardado em `peaks/`."""
        from fastapi.responses import Response

        from .media import spectrum

        found = song(song_id)
        manifest = found.manifest
        if stem is None:
            if not manifest.get("audio"):
                raise HTTPException(404, "Esta música não tem áudio.")
            relative, name = manifest["audio"]["file"], "source"
        else:
            relative = manifest.get("stems", {}).get(manifest.get("activeStems") or "", {}).get("files", {}).get(stem)
            if relative is None:
                raise HTTPException(404, f"Não há a faixa {stem} na separação ativa.")
            name = f"{manifest['activeStems']}-{stem}"
        base, name = name, f"{name}-v{spectrum.VERSION}"
        data_file, meta_file = found.file(f"peaks/spectrum-{name}.u8"), found.file(f"peaks/spectrum-{name}.json")
        if data_file.is_file() and meta_file.is_file():
            meta, data = read_json(meta_file), data_file.read_bytes()
        else:
            made = spectrum.compute(found.file(relative))
            data = made.pop("data").tobytes()
            meta = made
            data_file.parent.mkdir(exist_ok=True)
            temp = data_file.with_name(data_file.name + ".partial")
            temp.write_bytes(data)
            temp.replace(data_file)
            atomic_json(meta_file, meta)
            # As receitas antigas da mesma faixa não servem mais.
            for stale in [*found.file("peaks").glob(f"spectrum-{base}.*"), *found.file("peaks").glob(f"spectrum-{base}-v*")]:
                if stale not in (data_file, meta_file):
                    stale.unlink(missing_ok=True)
        headers = {"X-Frames": str(meta["frames"]), "X-Rows": str(meta["rows"]), "X-Hop": repr(meta["hop"]),
                   "X-Low": str(meta["low"]), "X-Per-Semitone": str(meta["perSemitone"])}
        return Response(content=data, media_type="application/octet-stream", headers=headers)

    @app.post("/api/songs/{song_id}/pitch")
    def song_pitch(song_id: str, body: dict = Body(...)) -> dict:
        """A curva de altura do som em cada nota pedida (`notes`: [{key, start, end, pitch}], até 200, cada uma até
        8 s), na guitarra da separação ativa (ou no original): `{curves: {key: {from, hop, values}}}`."""
        from .media import pitch as pitch_media

        found = song(song_id)
        manifest = found.manifest
        guitar = manifest.get("stems", {}).get(manifest.get("activeStems") or "", {}).get("files", {}).get("guitar")
        relative = guitar or (manifest.get("audio") or {}).get("file")
        if not relative:
            raise HTTPException(404, "Esta música não tem áudio.")
        notes = body.get("notes")
        if not isinstance(notes, list) or len(notes) > 200:
            raise HTTPException(400, "Envie até 200 notas em notes.")
        x = pitch_media.samples(found.file(relative))
        curves = {}
        for note in notes:
            try:
                key, start, end, height = str(note["key"]), float(note["start"]), float(note["end"]), float(note["pitch"])
            except (KeyError, TypeError, ValueError):
                raise HTTPException(400, "Cada nota precisa de key, start, end e pitch.") from None
            if not (0 <= start < end <= start + 8) or not 20 <= height <= 110:
                continue
            curves[key] = pitch_media.note_curve(x, start, end, height)
        return {"curves": curves}

    @app.get("/api/songs/{song_id}/peaks")
    def song_peaks(song_id: str, stem: str | None = None, stems_key: str | None = None) -> dict:
        """A onda da Fita: do áudio original, ou de uma faixa da separação ativa (ou da `stems_key`); guardada em
        `peaks/`."""
        found = song(song_id)
        manifest = found.manifest
        if stem is None:
            if not manifest.get("audio"):
                raise HTTPException(404, "Esta música não tem áudio.")
            relative, name = manifest["audio"]["file"], "source"
        else:
            chosen = stems_key or manifest.get("activeStems") or ""
            relative = manifest.get("stems", {}).get(chosen, {}).get("files", {}).get(stem)
            if relative is None:
                raise HTTPException(404, f"Não há a faixa {stem} nesta separação.")
            name = f"{chosen}-{stem}"
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
