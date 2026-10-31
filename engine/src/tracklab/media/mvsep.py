"""As faixas boas pelo MVSEP (mvsep.com): o áudio sobe e as faixas separadas lá descem. Nos modelos só de guitarra, o
resto da banda sai do Demucs local sobre o original menos as guitarras, para as faixas continuarem somando o original;
o BS-RoFormer SW devolve as seis faixas de uma vez (o mesmo modelo que leva ~57 min na CPU do iMac).

Vem do `mvsep_worker.py` do BackingLab 2: só https em mvsep.com, sem reenvio automático (cada envio gasta uma das
conversões do dia da conta), a chave nunca aparece numa mensagem. A chave chega do app (Chaves do macOS) a cada envio
e só vive na tarefa. O motor conta os envios do dia em `~/TrackLab/mvsep.json`, para o app mostrar quantos restam.

    63   BS Roformer SW: voz, baixo, bateria, guitarra, piano e outros, numa conversão
    31   MVSep Guitar (BS Roformer SW): guitarra e o resto
    101  MVSep Lead/Rhythm Guitar (dois estágios): guitarra solo e guitarra base
"""

from __future__ import annotations

import datetime as dt
import json
import re
import shutil
import time
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

import numpy as np
import soundfile

from .. import home
from ..errors import JobCancelled, MediaError
from ..util import atomic_json, new_id, now_iso, sha256_file
from . import align
from . import separate as demucs

Progress = Callable[[str, str, float | None], None]

STAGE = "mvsep"
API = "https://mvsep.com/api/"
PROCEDURE = "mvsep.v1"
DAILY_LIMIT = 10
OUTPUT_FORMAT = "1"        # WAV 16 bits: sem perda e sem atraso de codificador (o MP3 deslocaria as faixas)
POLL_SECONDS = 5.0
MAX_POLLS = 2880           # quatro horas de fila
MAX_DOWNLOAD = 2_000_000_000

# O modelo do MVSEP (sep_type), as opções fixas e a faixa do TrackLab de cada saída esperada; `complete`: as saídas
# já são a banda inteira, sem resto para o Demucs local.
MODELS = {
    63: {"name": "MVSEP 6 faixas (SW)", "options": {}, "complete": True,
         "targets": {name: name for name in ("vocals", "bass", "drums", "guitar", "piano", "other")}},
    31: {"name": "MVSEP Guitar", "options": {"add_opt1": "7"}, "targets": {"guitar": "guitar"}},
    101: {"name": "MVSEP Solo e base", "options": {"add_opt1": "0"},
          "targets": {"lead-guitar": "guitar", "rhythm-guitar": "rhythm"}},
}


class MVSEPError(MediaError):
    """O MVSEP recusou, falhou ou devolveu algo que não serve; a mensagem nunca leva a chave."""


# MARK: - A cota do dia


def _usage_file() -> Path:
    return home.home() / "mvsep.json"


def usage(today: dt.date | None = None) -> dict:
    """Quantos envios o TrackLab fez hoje (dia local) e o limite da conta."""
    today = today or dt.date.today()
    uses = _uses()
    used = sum(1 for stamp in uses if _local_date(stamp) == today)
    return {"usedToday": used, "limit": DAILY_LIMIT, "left": max(0, DAILY_LIMIT - used)}


def _uses() -> list[str]:
    try:
        data = json.loads(_usage_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [stamp for stamp in data.get("uses", []) if isinstance(stamp, str)]


def _record_use() -> None:
    uses = (_uses() + [now_iso()])[-200:]
    atomic_json(_usage_file(), {"uses": uses})


def _local_date(stamp: str) -> dt.date | None:
    try:
        return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone().date()
    except ValueError:
        return None


# MARK: - A separação


def check_key(key: str | None) -> str:
    key = (key or "").strip()
    if not 8 <= len(key) <= 512 or any(c.isspace() for c in key):
        raise MVSEPError("Falta a chave da API do MVSEP (TrackLab › Ajustes).")
    return key


def check_model(model) -> int:
    if model not in MODELS:
        raise MVSEPError(f"Modelo do MVSEP desconhecido: {model}. Use {', '.join(map(str, MODELS))}.")
    return model


def separate(source: Path, output: Path, *, key: str, model: int = 31, progress: Progress | None = None,
             cancel=None, session=None, demucs_run=None, pause=time.sleep) -> dict:
    """Separa `source` no MVSEP e grava `output/<faixa>.flac`: as faixas do MVSEP e, nos modelos só de guitarra, o
    resto pelo Demucs local."""
    source, output = Path(source), Path(output)
    key, model = check_key(key), check_model(model)
    spec = MODELS[model]
    if usage()["left"] <= 0:
        raise MVSEPError(f"As {DAILY_LIMIT} conversões do MVSEP de hoje já foram usadas. Amanhã tem mais.")
    session = session or _session()
    started = time.monotonic()
    info = soundfile.info(str(source))
    rate, frames = int(info.samplerate), int(info.frames)
    output.mkdir(parents=True, exist_ok=True)
    job_hash = None
    try:
        _emit(progress, "Enviando o áudio ao MVSEP…", 0.02)
        # Cancelada antes do envio: nada sai e a cota fica (depois do envio, o MVSEP já conta a conversão).
        _check(cancel)
        fields ={"api_token": key, "sep_type": str(model), "output_format": OUTPUT_FORMAT, "is_demo": "0",
                  **spec["options"]}
        try:
            with source.open("rb") as audio:
                response = session.post(API + "separation/create", data=fields, timeout=(30, 900),
                                        files={"audiofile": (f"audio{source.suffix}", audio, "application/octet-stream")})
        except OSError:
            raise MVSEPError("A conexão com o MVSEP caiu no envio. Confira o histórico da conta antes de reenviar.") \
                from None
        created = _json(response, key)
        if created.get("success") is not True:
            raise MVSEPError("O MVSEP não aceitou a separação. Confira a chave, os créditos e a fila na sua conta.")
        job_hash = (created.get("data") or {}).get("hash")
        if not isinstance(job_hash, str) or not job_hash or len(job_hash) > 1024:
            raise MVSEPError("O MVSEP não devolveu a identificação do trabalho. Confira o histórico antes de reenviar.")
        _record_use()
        files = _wait(session, job_hash, key, progress, cancel, pause)
        downloaded = {}
        wanted = spec["targets"]
        picked = {_stem_key(f): f for f in files if _stem_key(f) in wanted}
        if set(picked) != set(wanted):
            raise MVSEPError("O MVSEP não devolveu as faixas esperadas; nada foi trocado.")
        for index, (name, file) in enumerate(picked.items()):
            _check(cancel)
            _emit(progress, f"Baixando a faixa {index + 1} de {len(picked)}…", 0.3 + 0.1 * index / len(picked))
            temp = output / f".download-{index}.wav"
            _download(session, file.get("url", ""), temp, key)
            data = align.decode(temp, rate, channels=2)
            temp.unlink(missing_ok=True)
            if abs(len(data) - frames) > max(2, int(rate * 0.02)):
                raise MVSEPError("A faixa do MVSEP não tem a duração do original; nada foi trocado.")
            downloaded[wanted[name]] = align.place(data, 0, frames)
        _check(cancel)
        rest = None if spec.get("complete") else _rest(source, downloaded, model, rate, frames, output, progress,
                                                          cancel, demucs_run)
        outputs = rest["outputs"] if rest else downloaded
        stems = {name: demucs._write_stem(output / f"{name}.flac", data.T, rate) for name, data in outputs.items()}
    except JobCancelled:
        if job_hash:
            try:
                session.post(API + "separation/cancel", data={"api_token": key, "hash": job_hash}, timeout=10)
            except Exception:  # noqa: BLE001 — cancelar no MVSEP é uma gentileza; o trabalho local já parou
                pass
        raise
    receipt = {"model": f"mvsep{model}", "version": PROCEDURE, "name": spec["name"], "options": spec["options"],
               "mvsepHash": job_hash, "audioSHA256": sha256_file(source), "sampleRate": rate, "frames": frames,
               "duration": frames / rate, "device": rest["device"] if rest else None,
               "seconds": round(time.monotonic() - started, 3), "created": now_iso(), "stems": stems}
    if rest:
        receipt["rest"] = {"model": rest["model"], "device": rest["device"]}
        if rest.get("fallback"):
            receipt["fallback"] = rest["fallback"]
    atomic_json(output / "receipt.json", receipt)
    _emit(progress, "Faixas do MVSEP prontas.", 1.0)
    return receipt


def _rest(source: Path, guitars: dict, model: int, rate: int, frames: int, output: Path, progress, cancel,
          demucs_run) -> dict:
    """O resto da banda pelo Demucs local, sobre o original menos as guitarras do MVSEP; devolve as faixas todas."""
    original = align.place(soundfile.read(str(source), dtype="float32", always_2d=True)[0][:, :2], 0, frames)
    if original.shape[1] == 1:
        original = np.repeat(original, 2, axis=1)
    remainder = original - sum(guitars.values())
    folder = output / f".rest-{new_id()}"
    (folder / "stems").mkdir(parents=True)
    try:
        rest_source = folder / "rest.wav"
        soundfile.write(str(rest_source), remainder, rate, subtype="FLOAT")

        def rest_progress(_stage, message, fraction):
            _emit(progress, f"Resto da banda: {message[0].lower()}{message[1:]}",
                  None if fraction is None else 0.4 + 0.55 * fraction)

        receipt = (demucs_run or demucs.separate)(rest_source, folder / "stems", progress=rest_progress, cancel=cancel)
        parts = {name: soundfile.read(str(folder / "stems" / info["file"]), dtype="float32", always_2d=True)[0]
                 for name, info in receipt["stems"].items()}
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    outputs = dict(guitars)
    leftover = parts.pop("guitar")
    if model == 31:
        outputs["guitar"] = outputs["guitar"] + leftover     # o que o MVSEP deixou de guitarra no resto
    else:
        parts["other"] = parts["other"] + leftover           # outras guitarras, que não são solo nem base
    outputs.update(parts)
    return {"outputs": outputs, "model": receipt.get("model"), "device": receipt.get("device"),
            "fallback": receipt.get("fallback")}


def _session():
    import certifi
    import requests

    session = requests.Session()
    session.verify = certifi.where()
    session.headers["User-Agent"] = "TrackLab/1"
    session.max_redirects = 3
    return session


def _wait(session, job_hash: str, key: str, progress, cancel, pause) -> list[dict]:
    """Acompanha o trabalho no MVSEP até ficar pronto; quedas de conexão não reenviam o áudio."""
    failures = 0
    for _ in range(MAX_POLLS):
        _check(cancel)
        try:
            status = _json(session.get(API + "separation/get", params={"hash": job_hash}, timeout=60), key)
            failures = 0
        except (_Temporary, OSError):   # as falhas de rede do requests são OSError
            failures += 1
            if failures >= 12:
                raise MVSEPError("A conexão com o MVSEP caiu. O trabalho continua lá: confira o histórico.") from None
            _emit(progress, "Reconectando ao trabalho no MVSEP…", None)
            pause(POLL_SECONDS)
            continue
        state, data = status.get("status"), status.get("data") or {}
        if status.get("success") is not True or state in ("failed", "error", "not_found"):
            raise MVSEPError("A separação no MVSEP falhou ou expirou. O áudio não é reenviado sozinho.")
        if state == "done":
            files = data.get("files")
            if not isinstance(files, list) or not 1 <= len(files) <= 32:
                raise MVSEPError("O MVSEP devolveu uma lista de faixas que não serve.")
            return files
        if state not in ("waiting", "processing", "distributing", "merging"):
            raise MVSEPError("Estado inesperado do MVSEP. Confira o histórico antes de reenviar.")
        order = data.get("current_order")
        message = (f"Na fila do MVSEP{f' · posição {order}' if isinstance(order, int) else ''}…" if state == "waiting"
                   else "O MVSEP está separando…" if state in ("processing", "distributing")
                   else "O MVSEP está juntando as faixas…")
        _emit(progress, message, None)
        pause(POLL_SECONDS)
    raise MVSEPError("O MVSEP demorou demais. Confira o trabalho no histórico antes de reenviar.")


class _Temporary(MVSEPError):
    """Falha de rede ou do servidor que vale tentar de novo, sem reenviar o áudio."""


def _json(response, key: str) -> dict:
    status = response.status_code
    if status in (400, 401, 403):
        raise MVSEPError("O MVSEP recusou: " + (_detail(response, key) or "confira a chave, o modelo e os créditos."))
    if status == 429:
        raise MVSEPError("Pedidos demais ao MVSEP. Espere um pouco e confira a fila antes de reenviar.")
    if status >= 500:
        raise _Temporary(f"MVSEP indisponível (HTTP {status}).")
    if status != 200:
        raise MVSEPError(f"MVSEP respondeu HTTP {status}; nada foi reenviado.")
    try:
        data = response.json()
    except ValueError:
        raise MVSEPError("O MVSEP respondeu algo que não é JSON.") from None
    if not isinstance(data, dict):
        raise MVSEPError("O MVSEP respondeu algo inesperado.")
    return data


def _detail(response, key: str) -> str:
    """A mensagem de validação do MVSEP, sem a chave, sem endereços e curta."""
    try:
        payload = response.json()
    except ValueError:
        return ""
    message = payload.get("message") or payload.get("errors") or (payload.get("data") or {}).get("message") or ""
    if isinstance(message, dict):
        message = "; ".join(str(v) for v in message.values())
    text = str(message).replace(key, "[chave]")
    text = re.sub(r"https?://\S+", "[endereço]", text)
    return re.sub(r"[\r\n\t<>]", " ", text)[:240]


def _download(session, url: str, path: Path, key: str) -> None:
    parts = urlsplit(url)
    host = parts.hostname or ""
    if parts.scheme != "https" or not (host == "mvsep.com" or host.endswith(".mvsep.com")) or parts.username:
        raise MVSEPError("O MVSEP devolveu um endereço de download fora do mvsep.com.")
    try:
        response = session.get(url, stream=True, timeout=(30, 600))
        if response.status_code != 200:
            _json(response, key)
        count = 0
        with path.open("wb") as file:
            for block in response.iter_content(262_144):
                count += len(block)
                if count > MAX_DOWNLOAD:
                    raise MVSEPError("A faixa do MVSEP passa de 2 GB.")
                file.write(block)
    except OSError:
        raise MVSEPError("A conexão caiu baixando a faixa do MVSEP. O trabalho continua no histórico da conta.") \
            from None
    if count == 0:
        raise MVSEPError("O MVSEP devolveu um arquivo vazio.")


def _stem_key(file: dict) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(file.get("type", "")).lower()).strip("-")


def _check(cancel) -> None:
    if cancel is not None:
        cancel.check()


def _emit(progress: Progress | None, message: str, fraction: float | None) -> None:
    if progress is not None:
        progress(STAGE, message, fraction)


__all__ = ["DAILY_LIMIT", "MODELS", "MVSEPError", "check_key", "check_model", "separate", "usage"]
