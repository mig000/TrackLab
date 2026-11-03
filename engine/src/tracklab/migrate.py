"""A passagem das músicas de antes para MP3 (3/11/2026): `tracklab mp3`.

Até 3/11 o TrackLab gravava FLAC de 24 bits (o áudio do vídeo, as separações, a multitrack, a TAB sintetizada) e os
takes em CAF. Cada FLAC vira o MP3 do TrackLab (`encode`) no mesmo lugar, conferido pelo número de quadros; o manifesto
e os recibos passam a apontar para o MP3; o áudio do vídeo guarda o SHA-256 do FLAC em `audio.id` (as chaves das
separações saem dele, e uma separação já feita não se repete); os takes em CAF viram MP3 (`compress_takes`). Os FLAC
vão para uma pasta na Lixeira (`~/.Trash/TrackLab FLAC <data>/<música>/…`): o espaço só volta ao esvaziá-la, e até lá
dá para desfazer. Rode com o app fechado (o motor do app escreveria no manifesto ao mesmo tempo).
"""

from __future__ import annotations

import json
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import soundfile

from . import home, package
from .media import encode
from .media.probe import tool
from .util import atomic_json, sha256_file

JSON_FILES = ("manifest.json", "stems/*/receipt.json", "synth/*/receipt.json")


def transcode(flac: Path) -> Path:
    """Um FLAC vira o MP3 ao lado dele (o FLAC fica); devolve o MP3."""
    target = flac.with_suffix(encode.SUFFIX)
    temp = target.with_name(f".{target.stem}.tmp{encode.SUFFIX}")
    done = subprocess.run([tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-i", str(flac), *encode.codec_args(),
                           str(temp)], capture_output=True, check=False)
    try:
        if done.returncode != 0:
            raise RuntimeError(done.stderr.decode("utf-8", "replace").strip()[-300:])
        encode.check(temp, soundfile.info(str(flac)).frames)
        temp.replace(target)
    finally:
        temp.unlink(missing_ok=True)
    return target


def _rename(value, converted: set[str]):
    """Os caminhos `….flac` que viraram MP3, em qualquer lugar do JSON."""
    if isinstance(value, dict):
        return {key: _rename(item, converted) for key, item in value.items()}
    if isinstance(value, list):
        return [_rename(item, converted) for item in value]
    if isinstance(value, str) and value.endswith(".flac") and Path(value).name in converted:
        return value[:-5] + encode.SUFFIX
    return value


def song_to_mp3(song: package.SongPackage, trash: Path, *, workers: int = 6, say=print) -> dict:
    """Passa uma música para MP3; devolve quantos arquivos e quanto espaço antes e depois."""
    root = song.path
    flacs = sorted(path for path in root.rglob("*.flac") if not path.name.startswith("."))
    before = sum(path.stat().st_size for path in flacs)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        made = list(pool.map(transcode, flacs))
    after = sum(path.stat().st_size for path in made)
    names = {path.name for path in flacs}
    audio = song.manifest.get("audio") or {}
    old_sha = audio.get("sha256")
    for pattern in JSON_FILES:
        for file in root.glob(pattern):
            data = json.loads(file.read_text(encoding="utf-8"))
            changed = _rename(data, names)
            if file.name == "manifest.json" and isinstance(changed.get("audio"), dict) and old_sha:
                if changed["audio"].get("file", "").endswith(encode.SUFFIX):
                    changed["audio"].setdefault("id", old_sha)
                    changed["audio"]["sha256"] = sha256_file(root / changed["audio"]["file"])
            if changed != data:
                atomic_json(file, changed)
    for flac in flacs:
        destination = trash / root.name / flac.relative_to(root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        flac.rename(destination)
    fresh = package.SongPackage(root)
    takes = fresh.compress_takes()
    say(f"{root.name}: {len(flacs)} FLAC → MP3, {before / 1e6:.0f} MB → {after / 1e6:.0f} MB"
        + (f", {len(takes)} takes" if takes else ""))
    return {"song": root.name, "files": len(flacs), "before": before, "after": after, "takes": len(takes)}


def all_to_mp3(*, say=print) -> list[dict]:
    trash = Path.home() / ".Trash" / f"TrackLab FLAC {time.strftime('%Y-%m-%d %H.%M')}"
    trash.mkdir(parents=True, exist_ok=True)
    reports = []
    for root in sorted(home.songs().glob(f"*{package.SUFFIX}")):
        reports.append(song_to_mp3(package.SongPackage(root), trash, say=say))
    before = sum(report["before"] for report in reports)
    after = sum(report["after"] for report in reports)
    say(f"Pronto: {before / 1e9:.2f} GB de FLAC viraram {after / 1e9:.2f} GB de MP3; os FLAC estão em {trash}.")
    return reports


__all__ = ["all_to_mp3", "song_to_mp3", "transcode"]
