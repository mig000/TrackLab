"""A API local do motor, só em 127.0.0.1: o app nativo pede, a fila pesada executa, o progresso chega por SSE."""

from __future__ import annotations

import platform
import threading

from fastapi import Body, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from . import __version__, home, multitracks, package, songsterr, stems, tempomap
from .errors import JobCancelled, PackageError, TrackLabError
from .jobs import JobManager
from .media import mvsep
from .media.peaks import peaks
from .util import atomic_bytes, atomic_json, read_json

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
    def multitrack_search(q: str, hidden: bool = False) -> dict:
        """As músicas da biblioteca pelo nome; as escondidas só com `hidden=true` (e marcadas)."""
        return {"results": multitracks.search(q, include_hidden=hidden)}

    @app.get("/api/multitracks/hidden")
    def multitrack_hidden() -> dict:
        """As músicas escondidas da biblioteca (os arquivos ficam onde estão)."""
        return {"results": multitracks.hidden_songs()}

    @app.put("/api/multitracks/hidden")
    def multitrack_hide(body: dict = Body(...)) -> dict:
        """Esconde (`hidden: true`) ou mostra de novo a música da biblioteca com este `path`."""
        relative, hide = body.get("path"), body.get("hidden")
        if not isinstance(relative, str) or not relative or not isinstance(hide, bool):
            raise HTTPException(400, "Mande o caminho da música (path) e se ela fica escondida (hidden).")
        return {"hidden": multitracks.set_hidden(relative, hide)}

    @app.post("/api/songs/import", status_code=202)
    def import_song(request: ImportRequest) -> dict:
        songsterr.song_id(request.url)   # recusa já, antes da fila, o que não é do Songsterr

        def work(progress, cancel):
            made = songsterr.import_song(request.url, source=source, progress=progress, cancel=cancel)
            result = {"song": made.summary()}
            if request.separate and made.manifest.get("audio"):
                try:
                    result["stems"] = stems.separate_song(made, progress=progress, cancel=cancel, run=separate_run)
                except JobCancelled:
                    raise   # cancelada é cancelada (a música fica no repertório), não "concluída com aviso"
                except TrackLabError as error:
                    # A música já está no repertório; a separação pode ser pedida de novo depois.
                    made.update(lambda data: data["warnings"].append(f"Faixas não separadas: {error}"))
                    result["warning"] = str(error)
            return result

        return _job(jobs.submit("import", work))

    @app.post("/api/songs/{song_id}/audio", status_code=202)
    def song_audio(song_id: str) -> dict:
        """O áudio e o mapa do Songsterr de novo, numa música que entrou só com a partitura, na fila."""
        found = song(song_id)
        if found.manifest.get("audio"):
            raise HTTPException(409, "Esta música já tem áudio.")

        def work(progress, cancel):
            return {"song": songsterr.add_audio(found, source=source, progress=progress, cancel=cancel).summary()}

        return _job(jobs.submit("audio", work, project=song_id))

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
        from starlette.concurrency import run_in_threadpool

        found = song(song_id)
        # Numa thread: conferir o Guitar Pro de uma música grande leva alguns décimos e seguraria os outros pedidos.
        return {"score": await run_in_threadpool(found.save_score, await request.body())}

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
        edited = tempomap.anchor_edit({**gesture, "tempoMap": current})
        moved = edited.pop("movedCount", None)
        saved = found.save_tempo_map(edited)
        return saved if moved is None else {**saved, "movedCount": moved}

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

    @app.put("/api/songs/{song_id}/chords")
    def chords(song_id: str, body: dict = Body(...)) -> dict:
        """As correções da barra de acordes (`{"edits": [{"from", "to", "name"}, …]}`), no lugar das que estavam."""
        try:
            return {"edits": song(song_id).set_chord_edits(body.get("edits"))}
        except ValueError as error:
            raise HTTPException(400, str(error)) from error

    @app.put("/api/songs/{song_id}/takes")
    def put_takes(song_id: str, body: dict = Body(...)) -> dict:
        """Os takes gravados (`{"takes": [...]}`, a lista inteira), no lugar dos que estavam."""
        return {"takes": song(song_id).set_takes(body.get("takes"))}

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

    spectrum_guard, spectrum_locks = threading.Lock(), {}

    def spectrum_of(song_id: str, stem: str | None) -> tuple[dict, bytes, str]:
        """O espectro (media/spectrum.py) do original ou de uma faixa da separação ativa: as medidas, os bytes e o
        nome com que fica em `peaks/` (calculado uma vez)."""
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
        # Um cálculo por faixa: dois pedidos juntos (o espectro e os sons, ou a aparência trocada no meio do primeiro)
        # esperam o mesmo cálculo em vez de fazer dois e disputar o arquivo.
        with spectrum_guard:
            lock = spectrum_locks.setdefault(str(data_file), threading.Lock())
        with lock:
            if data_file.is_file() and meta_file.is_file():
                return read_json(meta_file), data_file.read_bytes(), name
            made = spectrum.compute(found.file(relative))
            data = made.pop("data").tobytes()
            meta = made
            atomic_bytes(data_file, data)
            atomic_json(meta_file, meta)
            # As receitas antigas da mesma faixa não servem mais.
            for stale in [*found.file("peaks").glob(f"spectrum-{base}.*"), *found.file("peaks").glob(f"spectrum-{base}-v*")]:
                if stale not in (data_file, meta_file):
                    stale.unlink(missing_ok=True)
        return meta, data, name

    @app.get("/api/songs/{song_id}/spectrum")
    def song_spectrum(song_id: str, stem: str | None = None):
        """O espectro da Fita (media/spectrum.py) do áudio original ou de uma faixa da separação ativa, em bytes
        (quadros × linhas); as medidas vão nos cabeçalhos X-Frames, X-Rows, X-Hop, X-Low e X-Per-Semitone. Calculado
        uma vez e guardado em `peaks/`."""
        from fastapi.responses import Response

        meta, data, _ = spectrum_of(song_id, stem)
        headers = {"X-Frames": str(meta["frames"]), "X-Rows": str(meta["rows"]), "X-Hop": repr(meta["hop"]),
                   "X-Low": str(meta["low"]), "X-Per-Semitone": str(meta["perSemitone"])}
        return Response(content=data, media_type="application/octet-stream", headers=headers)

    chords_guard, chords_locks = threading.Lock(), {}

    @app.post("/api/songs/{song_id}/chords/sound")
    def song_chord_sound(song_id: str, body: dict = Body(default={})) -> dict:
        """Os acordes pelo som (media/chordsound.py) do áudio original: `{chords: [[início, fim, nome], …]}` em
        segundos, com o nome como o Chord-CNN-LSTM escreve ("A:min7", "C:maj/5", "N"). `beats` (`[[segundo, tipo], …]`,
        tipo 2 no 1 do compasso, 3 no meio dele, 4 nos outros tempos) prende as trocas às batidas do mapa. As
        probabilidades (o caro: ~50 s para 5 minutos) são calculadas uma vez e guardadas em `peaks/`; o nome sai na
        hora, com as batidas de agora."""
        import numpy as np

        from . import models
        from .media import chordsound

        found = song(song_id)
        audio = found.manifest.get("audio")
        if not audio:
            raise HTTPException(404, "Esta música não tem áudio.")
        beats = []
        for item in body.get("beats") or []:
            if isinstance(item, list) and len(item) == 2 and all(isinstance(v, (int, float)) for v in item):
                beats.append((float(item[0]), int(item[1])))
        cache = found.file(f"peaks/chordprobs-source-v{chordsound.VERSION}.npy")
        with chords_guard:
            lock = chords_locks.setdefault(str(cache), threading.Lock())
        with lock:
            if cache.is_file():
                probs = np.load(cache)
            else:
                weights = [models.ensure(name) for name in models.CHORDNET]
                probs = chordsound.probabilities(found.file(audio["file"]), weights)
                cache.parent.mkdir(exist_ok=True)
                temp = cache.with_name(f".{cache.name}.{threading.get_ident()}.partial.npy")
                np.save(temp, probs.astype(np.float32))
                temp.replace(cache)
                for old in cache.parent.glob("chordprobs-source-v*.npy"):
                    if old != cache:
                        old.unlink(missing_ok=True)
        return {"chords": chordsound.decode(probs, beats), "version": chordsound.VERSION}

    @app.get("/api/songs/{song_id}/sounds")
    def song_sounds(song_id: str, stem: str | None = None) -> dict:
        """Os sons da faixa (media/sounds.py): os ataques fortes e a altura de cada um, `{sounds: [[segundo, altura,
        dB, dB abaixo do mais forte em ±2 s], …]}`, para o app achar o som sem nota escrita. Lidos no espectro da
        faixa e guardados em `peaks/`."""
        import numpy as np

        from .media import sounds

        meta, data, name = spectrum_of(song_id, stem)
        found = song(song_id)
        cache = found.file(f"peaks/sounds-{name}-s{sounds.VERSION}.json")
        if cache.is_file():
            return read_json(cache)
        grid = np.frombuffer(data, dtype=np.uint8).reshape(meta["frames"], meta["rows"])
        result = {"sounds": sounds.detect(grid, meta["hop"], meta["low"], meta["perSemitone"]), "version": sounds.VERSION}
        cache.parent.mkdir(exist_ok=True)
        atomic_json(cache, result)
        return result

    beats_guard, beats_locks = threading.Lock(), {}

    @app.get("/api/songs/{song_id}/beats")
    def song_beats(song_id: str, stem: str | None = None, bpm: float | None = None) -> dict:
        """O tempo ouvido para o Ajuste (media/beats.py): a força dos ataques (`envelope`, um byte por quadro, `rate`
        quadros por segundo) e as batidas que o detector acha (`beats`, em segundos), com `bpm` (o do mapa) para ele
        começar. Na faixa pedida da separação ativa; sem ela, a bateria, o baixo ou o original (`stem` diz qual).
        Calculado uma vez por faixa e andamento e guardado em `peaks/`."""
        from .media import beats

        found = song(song_id)
        manifest = found.manifest
        files = manifest.get("stems", {}).get(manifest.get("activeStems") or "", {}).get("files", {})
        chosen = next((name for name in (stem, "drums", "bass") if name and files.get(name)), None)
        if chosen:
            relative, name = files[chosen], f"{manifest['activeStems']}-{chosen}"
        elif manifest.get("audio"):
            relative, name, chosen = manifest["audio"]["file"], "source", "source"
        else:
            raise HTTPException(404, "Esta música não tem áudio.")
        tempo = round(bpm) if bpm and 30 <= bpm <= 300 else None
        cache = found.file(f"peaks/beats-{name}-b{beats.VERSION}-{tempo or 'auto'}.json")
        with beats_guard:
            lock = beats_locks.setdefault(str(cache), threading.Lock())
        with lock:
            if cache.is_file():
                return read_json(cache)
            result = {**beats.analyse(found.file(relative), tempo), "stem": chosen}
            cache.parent.mkdir(exist_ok=True)
            atomic_json(cache, result)
            # O mesmo arquivo com outro andamento, ou de outra receita, não serve mais.
            for stale in found.file("peaks").glob(f"beats-{name}-b*.json"):
                if stale != cache:
                    stale.unlink(missing_ok=True)
        return result

    @app.post("/api/songs/{song_id}/pitch")
    def song_pitch(song_id: str, body: dict = Body(...)) -> dict:
        """A curva de altura do som em cada nota pedida (`notes`: [{key, start, end, pitch}], até 200, cada uma até
        8 s), na faixa `stem` da separação ativa (a guitarra se não vier; o baixo para a pista do baixo, a base para a
        guitarra base…), ou no original sem separação, ou num take (`file`, `takes/<nome>`, com os tempos nos segundos
        dele): `{curves: {key: {from, hop, values, attack}}}`."""
        from .media import pitch as pitch_media

        found = song(song_id)
        manifest = found.manifest
        files = manifest.get("stems", {}).get(manifest.get("activeStems") or "", {}).get("files", {})
        stem = body.get("stem")
        take = body.get("file")
        if take is not None:
            # Um take gravado (ou uma volta do Estudar): a nota da volta mede o som dele, nos segundos do arquivo.
            if not (isinstance(take, str) and take.startswith("takes/") and ".." not in take and "/" not in take[6:]):
                raise HTTPException(400, "O arquivo (file) é um take do pacote: takes/<nome>.")
            if not found.file(take).is_file():
                raise HTTPException(404, f"Não achei {take} no pacote.")
            relative = take
        else:
            if stem is not None and stem not in files:
                raise HTTPException(404, f"Não há a faixa {stem} na separação ativa.")
            relative = files.get(stem or "guitar") or (manifest.get("audio") or {}).get("file")
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
                others = [float(o) for o in note.get("others") or []]
            except (KeyError, TypeError, ValueError):
                raise HTTPException(400, "Cada nota precisa de key, start, end e pitch.") from None
            if not (0 <= start < end <= start + 8) or not 20 <= height <= 110:
                continue
            curves[key] = pitch_media.note_curve(x, start, end, height, others=others)
        return {"curves": curves}

    @app.post("/api/songs/{song_id}/transcribe")
    def song_transcribe(song_id: str, body: dict = Body(...)) -> dict:
        """As notas de um trecho do som (a seleção no espectro): de `from` a `to` (s, até 20 s) com altura de `low` a
        `high` (MIDI), na faixa `stem` da separação ativa (como em `pitch`): `{notes: [{start, end, level, slide, curve}]}`."""
        from .media import pitch as pitch_media
        from .media import transcribe

        found = song(song_id)
        manifest = found.manifest
        files = manifest.get("stems", {}).get(manifest.get("activeStems") or "", {}).get("files", {})
        stem = body.get("stem")
        if stem is not None and stem not in files:
            raise HTTPException(404, f"Não há a faixa {stem} na separação ativa.")
        relative = files.get(stem or "guitar") or (manifest.get("audio") or {}).get("file")
        if not relative:
            raise HTTPException(404, "Esta música não tem áudio.")
        try:
            start, end = float(body["from"]), float(body["to"])
            low, high = float(body["low"]), float(body["high"])
        except (KeyError, TypeError, ValueError):
            raise HTTPException(400, "Envie from, to, low e high.") from None
        if not (0 <= start < end <= start + 20) or not (20 <= low < high <= 110):
            raise HTTPException(400, "O trecho vai até 20 s, e as alturas de 20 a 110.")
        x = pitch_media.samples(found.file(relative))
        return {"notes": transcribe.notes(x, start, end, low, high)}

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
