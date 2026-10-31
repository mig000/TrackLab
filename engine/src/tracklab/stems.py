"""Faixas separadas de uma música do repertório: a chave junta provedor, modelo, versão e o hash do áudio.

A mesma música com o mesmo modelo nunca separa duas vezes (no MVSEP, isso é uma conversão do dia que não se gasta de
novo); cada provedor é outra pasta em `stems/`, e o A/B do app escolhe qual fica ativa. A escada da Fase 4:

    demucs6s-…     Demucs 6s local, na GPU: sempre, a primeira e a reserva
    multitrack-…   as faixas da gravação, da biblioteca de multitracks, alinhadas ao áudio do vídeo
    mvsep31-…      a guitarra do MVSEP (e o resto da banda pelo Demucs local)
    mvsep101-…     guitarra solo e base do MVSEP
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable

from . import multitracks
from .errors import PackageError, TrackLabError
from .media import mogg as mogg_media
from .media import multitrack as multitrack_media
from .media import mvsep
from .media import separate as demucs
from .media import synth as synth_media
from .package import SongPackage
from .util import read_json, sha256_file, sha256_text

Progress = Callable[[str, str, float | None], None]

# A faixa do TrackLab de cada instrumento da multitrack; `rhythm` é decidido pelo song.ini.
MULTITRACK_STEMS = {"guitar": "guitar", "bass": "bass", "drums": "drums", "vocals": "vocals", "keys": "piano",
                    "backing": "other", "other": "other"}
SKIPPED = re.compile(r"crowd|preview|click|count.?in", re.IGNORECASE)


def demucs_key(audio_sha: str, version: str) -> str:
    return f"demucs6s-{sha256_text(audio_sha + '|' + version)[:8]}"


def multitrack_key(audio_sha: str, library_path: str) -> str:
    return f"multitrack-{sha256_text(audio_sha + '|' + library_path + '|' + multitrack_media.PROCEDURE)[:8]}"


def mvsep_key(audio_sha: str, model: int) -> str:
    options = sorted(mvsep.MODELS[model]["options"].items())
    return f"mvsep{model}-{sha256_text(f'{audio_sha}|{model}|{options}|{mvsep.PROCEDURE}')[:8]}"


def separate_song(package: SongPackage, *, progress: Progress | None = None, cancel=None, device: str | None = None,
                  run=None) -> dict:
    """Separa o áudio do pacote com o Demucs 6s (GPU quando houver) e publica as seis faixas; devolve o registro."""
    audio = _audio(package)
    version = demucs.separator_version()
    key = demucs_key(audio["sha256"], version)

    def build(folder):
        receipt = (run or demucs.separate)(package.file(audio["file"]), folder, progress=progress, cancel=cancel,
                                           device=device)
        receipt["provider"] = "demucs"
        return receipt

    return _publish(package, key, build, progress, demucs.STAGE, activate=True)


def import_multitrack(package: SongPackage, entry: dict, *, folder: Path | None = None,
                      progress: Progress | None = None, cancel=None) -> dict:
    """As faixas da multitrack `entry` (uma linha do índice) alinhadas ao áudio do vídeo do pacote."""
    audio = _audio(package)
    if entry.get("format") == "mogg":
        return _import_mogg(package, entry, audio, folder=folder, progress=progress, cancel=cancel)
    base = Path(folder or multitracks.root()) / entry["path"]
    if not base.is_dir():
        raise multitracks.MultitrackError(f"Não achei {entry['path']} na biblioteca (o HD externo está ligado?).")
    tracks = multitrack_tracks(entry, base)
    key = multitrack_key(audio["sha256"], entry["path"])

    def build(output):
        receipt = multitrack_media.assemble(
            package.file(audio["file"]), tracks, output, progress=progress, cancel=cancel,
            details={"library": entry["path"], "format": entry.get("format"),
                     "name": " — ".join(part for part in (entry.get("artist"), entry.get("title")) if part)})
        receipt["provider"] = "multitrack"
        return receipt

    return _publish(package, key, build, progress, multitrack_media.STAGE, activate=False)


def _import_mogg(package: SongPackage, entry: dict, audio: dict, *, folder: Path | None, progress, cancel) -> dict:
    """Um .mogg do Rock Band: os canais reconhecidos pelas faixas do Demucs da música (sem o mapa do jogo)."""
    path = Path(folder or multitracks.root()) / entry["path"]
    if not path.is_file():
        raise multitracks.MultitrackError(f"Não achei {entry['path']} na biblioteca (o HD externo está ligado?).")
    manifest = package.manifest
    demucs = next((value for key, value in manifest.get("stems", {}).items()
                   if key.startswith("demucs") and value.get("files")), None)
    if demucs is None:
        raise multitracks.MultitrackError("Um .mogg precisa das faixas do Demucs da música para reconhecer os canais: "
                                          "separe as faixas primeiro.")
    references = {name: package.file(relative) for name, relative in demucs["files"].items()}
    key = multitrack_key(audio["sha256"], entry["path"])

    def build(output):
        receipt = mogg_media.assemble(
            package.file(audio["file"]), path, references, output, progress=progress, cancel=cancel,
            details={"library": entry["path"], "format": "mogg",
                     "name": " — ".join(part for part in (entry.get("artist"), entry.get("title")) if part)})
        receipt["provider"] = "multitrack"
        return receipt

    return _publish(package, key, build, progress, multitrack_media.STAGE, activate=False)


def multitrack_tracks(entry: dict, base: Path) -> list[tuple[Path, str]]:
    """Os arquivos da multitrack e a faixa do TrackLab de cada um. No Clone Hero, `rhythm` é a guitarra base quando
    o song.ini tem a parte de base (`diff_rhythm`); senão é o baixo, como no Rock Band."""
    ini = multitracks._read_ini(base / "song.ini") if entry.get("format") == "clonehero" else {}
    rhythm = "rhythm" if entry.get("format") != "clonehero" or _number(ini.get("diff_rhythm")) >= 0 else "bass"
    tracks = []
    names = [stem["file"] for stem in entry.get("stems", [])]
    # O instrumento pelos nomes, não pelo índice: um índice feito antes de uma correção ainda erraria.
    for name, kind in zip(names, multitracks.kinds_of(names)):
        if SKIPPED.search(Path(name).stem):
            continue
        key = rhythm if kind == "rhythm" else MULTITRACK_STEMS.get(kind, "other")
        tracks.append((base / name, key))
    return tracks


def separate_mvsep(package: SongPackage, *, key: str, model: int = 31, progress: Progress | None = None,
                   cancel=None, session=None, demucs_run=None, pause=None) -> dict:
    """A guitarra do MVSEP (uma conversão do dia) com o resto da banda pelo Demucs local."""
    audio = _audio(package)
    model = mvsep.check_model(model)
    api_key = mvsep.check_key(key)
    stems_key = mvsep_key(audio["sha256"], model)

    def build(output):
        extra = {"pause": pause} if pause is not None else {}
        receipt = mvsep.separate(package.file(audio["file"]), output, key=api_key, model=model, progress=progress,
                                 cancel=cancel, session=session, demucs_run=demucs_run, **extra)
        receipt["provider"] = "mvsep"
        return receipt

    return _publish(package, stems_key, build, progress, mvsep.STAGE, activate=False)


def synthesize_tab(package: SongPackage, *, progress: Progress | None = None, cancel=None, font=None,
                   engine: str | None = None) -> dict:
    """A TAB sintetizada de todas as pistas no mapa de tempo de agora (refeita a cada mapa novo; a chave junta a
    partitura, o mapa, o SoundFont e a versão do procedimento)."""
    manifest = package.manifest
    audio, score, entry = _audio(package), manifest.get("score"), manifest.get("tempoMap")
    if not score or not entry:
        raise PackageError("Esta música não tem partitura e mapa de tempo para sintetizar.")
    font = Path(font or synth_media.soundfont())
    tempo_file = package.file(entry["file"])
    tempo_sha, sound_sha = sha256_file(tempo_file), font_sha(font)
    key = "tab-" + sha256_text("|".join((score.get("sha256") or "", tempo_sha, sound_sha, synth_media.PROCEDURE)))[:8]
    done = manifest.get("synth")
    if done and done.get("key") == key and all(package.file(t["file"]).is_file() for t in done["tracks"].values()):
        # A chave já junta partitura, mapa, SoundFont e versão: a síntese é desta partitura, deste mapa, deste som e
        # deste procedimento. Uma feita antes de o manifesto guardar os quatro ganha os quatro aqui (sem eles ela
        # pareceria velha para sempre).
        if (done.get("tempoSHA256") != tempo_sha or done.get("scoreSHA256") != score.get("sha256")
                or done.get("version") != synth_media.PROCEDURE or done.get("soundfontSHA256") != sound_sha):
            def record(data: dict) -> None:
                data["synth"].update(tempoSHA256=tempo_sha, scoreSHA256=score.get("sha256"), version=synth_media.PROCEDURE,
                                     soundfont=font.name, soundfontSHA256=sound_sha)

            done = package.update(record)["synth"]
        if progress is not None:
            progress(synth_media.STAGE, "A TAB sintetizada já estava pronta.", 1.0)
        return {**done, "reused": True}
    points = read_json(tempo_file)["points"]

    def build(output):
        receipt = synth_media.synthesize(package.file(score["file"]), points, package.file(audio["file"]), output,
                                         progress=progress, cancel=cancel, font=font, engine=engine)
        receipt["tempoSHA256"] = tempo_sha
        receipt["scoreSHA256"] = score.get("sha256")
        receipt["soundfontSHA256"] = sound_sha
        return receipt

    return {**package.add_synth(key, build)["synth"], "reused": False}


def synth_state(package: SongPackage) -> dict | None:
    """A TAB sintetizada do manifesto, com `stale` quando o mapa de tempo, a partitura, o SoundFont escolhido ou o
    procedimento (uma síntese de uma versão anterior do TrackLab) mudou depois dela, ou quando falta um arquivo dela."""
    manifest = package.manifest
    done, entry = manifest.get("synth"), manifest.get("tempoMap")
    if not done:
        return None
    current = sha256_file(package.file(entry["file"])) if entry and package.file(entry["file"]).is_file() else None
    score = (manifest.get("score") or {}).get("sha256")
    return {**done, "stale": current != done.get("tempoSHA256") or (score is not None and score != done.get("scoreSHA256"))
            or done.get("version") != synth_media.PROCEDURE or _other_font(done)
            or not all(package.file(t["file"]).is_file() for t in done.get("tracks", {}).values())}


_FONT_SHA: dict[tuple, str] = {}


def font_sha(font: Path) -> str:
    """O SHA-256 do SoundFont, lembrado pelo caminho, tamanho e data (o GeneralUser tem 30 MB e o GET de cada música
    pergunta): o mesmo nome com outro conteúdo é outro som."""
    info = Path(font).stat()
    key = (str(Path(font).resolve()), info.st_size, info.st_mtime_ns)
    if key not in _FONT_SHA:
        _FONT_SHA[key] = sha256_file(font)
    return _FONT_SHA[key]


def _other_font(done: dict) -> bool:
    """Se o SoundFont escolhido agora não é o da síntese (uma de antes de o manifesto guardar o SHA compara o nome)."""
    try:
        font = synth_media.soundfont()
    except (TrackLabError, OSError):
        return False   # sem SoundFont não há como refazer; a de antes continua valendo
    if done.get("soundfontSHA256"):
        return font_sha(font) != done["soundfontSHA256"]
    return bool(done.get("soundfont")) and font.name != done["soundfont"]


def _publish(package: SongPackage, key: str, build, progress, stage: str, *, activate: bool) -> dict:
    done = package.manifest.get("stems", {}).get(key)
    if done and all(package.file(path).is_file() for path in done.get("files", {}).values()):
        if progress is not None:
            progress(stage, "Estas faixas já estavam prontas.", 1.0)
        return {"key": key, **done, "reused": True}
    updated = package.add_stems(key, build, activate=activate)
    return {"key": key, **updated["stems"][key], "active": updated["activeStems"] == key, "reused": False}


def _audio(package: SongPackage) -> dict:
    audio = package.manifest.get("audio")
    if not audio:
        raise PackageError("Esta música não tem áudio para separar.")
    return audio


def _number(text) -> float:
    try:
        return float(text)
    except (TypeError, ValueError):
        return -1.0
