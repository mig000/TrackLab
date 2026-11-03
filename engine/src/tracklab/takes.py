"""Os takes gravados (Fase 5): a guitarra do Miguel por cima da música, em até quatro pistas ("Guitarra 1" a 4).

O app grava o áudio de cada take direto no pacote (`takes/<id>.caf`, sem perda, e o timbre dos efeitos em
`takes/<id>.chain.plist`) e manda a lista ao motor, que a guarda no manifesto (`takes`) e apaga os arquivos dos takes
que saíram dela. Depois, o motor passa o áudio de cada take da lista para MP3 (`compress`, `takes/<id>.mp3`, como todo
áudio do TrackLab desde 3/11/2026) e apaga o CAF; o app acha o take pelo que existe (um ou outro). Cada take sabe onde cai na música (`start` e `length` em segundos da música) e em que velocidade e tom
foi tocado (`rate`, `cents`): gravado a 85 %, ele é tocado de volta no tempo da música.
"""

from __future__ import annotations

import re
import time
from pathlib import Path

from .errors import PackageError

LANES = range(1, 5)
FOLDER = "takes"
_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
# Um arquivo que não está na lista só sai depois de um minuto: o take que acabou de ser gravado chega ao disco antes
# de entrar na lista, e outra mudança (um favorito) não pode levá-lo.
STALE_SECONDS = 60


class TakeError(PackageError):
    pass


def _number(value, name: str, low: float, high: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TakeError(f"O take precisa de {name} em número.")
    value = float(value)
    if value < low or (high is not None and value > high):
        raise TakeError(f"{name} fora do alcance: {value}.")
    return value


def check(takes, folder: Path) -> list[dict]:
    """A lista como o app mandou, conferida: ids únicos, o áudio de cada um no pacote, a pista de 1 a 4."""
    if not isinstance(takes, list):
        raise TakeError("Envie os takes numa lista.")
    clean: list[dict] = []
    seen: set[str] = set()
    for take in takes:
        if not isinstance(take, dict):
            raise TakeError("Cada take é um objeto.")
        take_id = take.get("id")
        if not isinstance(take_id, str) or not _ID.match(take_id) or take_id in seen:
            raise TakeError(f"Id de take inválido ou repetido: {take_id!r}.")
        seen.add(take_id)
        audio = next((f"{FOLDER}/{take_id}{suffix}" for suffix in (".mp3", ".caf")
                      if (folder / FOLDER / f"{take_id}{suffix}").is_file()), None)
        if audio is None:
            raise TakeError(f"O áudio do take {take_id} não está no pacote.")
        lane = take.get("lane")
        if isinstance(lane, bool) or lane not in LANES:
            raise TakeError(f"Pista de take inválida: {lane!r} (de 1 a 4).")
        entry = {
            "id": take_id,
            "file": audio,
            "lane": lane,
            "start": _number(take.get("start"), "start", 0),
            "length": _number(take.get("length"), "length", 0.01),
            "rate": _number(take.get("rate", 1), "rate", 0.25, 4),
            "cents": int(_number(take.get("cents", 0), "cents", -1200, 1200)),
            "name": str(take.get("name") or f"Take {len(clean) + 1}")[:80],
            "created": str(take.get("created") or ""),
            "favorite": bool(take.get("favorite")),
            "active": bool(take.get("active", True)),
        }
        for key in ("input", "offset"):
            if key in take:
                entry[key] = take[key] if key == "input" else _number(take[key], key, -10, 10)
        if isinstance(entry.get("input"), str):
            entry["input"] = entry["input"][:120]
        elif "input" in entry:
            del entry["input"]
        chain = f"{FOLDER}/{take_id}.chain.plist"
        if (folder / chain).is_file():
            entry["chain"] = chain
        clean.append(entry)
    return clean


def sweep(folder: Path, takes: list[dict], now: float | None = None) -> list[str]:
    """Apaga de `takes/` os arquivos de take que não estão na lista (há mais de um minuto); devolve os apagados."""
    directory = folder / FOLDER
    if not directory.is_dir():
        return []
    keep = {take["id"] for take in takes}
    now = time.time() if now is None else now
    removed = []
    for path in directory.iterdir():
        if not path.is_file() or path.name.split(".")[0] in keep:
            continue
        if now - path.stat().st_mtime < STALE_SECONDS:
            continue
        path.unlink()
        removed.append(path.name)
    return sorted(removed)


def compress(folder: Path, take: dict) -> str | None:
    """Passa o áudio de um take de CAF para MP3 (o mesmo tempo, o atraso do codificador descontado) e apaga o CAF;
    devolve o arquivo novo, ou None se já era MP3 ou o CAF sumiu."""
    from .media import encode
    from .media.probe import tool

    if not take["file"].endswith(".caf"):
        return None
    source = folder / take["file"]
    if not source.is_file():
        return None
    target = source.with_suffix(encode.SUFFIX)
    temp = target.with_name(f".{target.stem}.tmp{encode.SUFFIX}")
    import subprocess

    done = subprocess.run([tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-i", str(source), *encode.codec_args(),
                           str(temp)], capture_output=True, check=False)
    try:
        if done.returncode != 0:
            return None
        import soundfile

        encode.check(temp, soundfile.info(str(source)).frames)
        temp.replace(target)
    except Exception:
        return None
    finally:
        temp.unlink(missing_ok=True)
    source.unlink(missing_ok=True)
    return f"{FOLDER}/{target.name}"
