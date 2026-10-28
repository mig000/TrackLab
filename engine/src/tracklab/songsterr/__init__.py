"""Importação do Songsterr: partitura, vídeo vinculado e pontos de sincronização viram um pacote do TrackLab.

O caminho é o do BackingLab 2: a partitura vem pelas faixas JSON do Songsterr e o conversor de teaqu (MIT, em
`vendor/`) monta o GP; o áudio vem do vídeo principal vinculado pelo Songsterr, sem conta nem cookies. Os pontos
de sincronização (o início de cada compasso no vídeo) viram o mapa de tempo inicial; daí em diante só o ajuste
manual mexe nele.
"""

from __future__ import annotations

import contextlib
import io
import math
import re
import shutil
import tempfile
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

import requests

from .. import tempomap
from ..errors import SongsterrError, TrackLabError
from ..media.convert import to_source
from ..media.probe import TOOL_FOLDERS
from ..package import Draft, SongPackage
from ..util import atomic_json, sha256_file
from . import score

Progress = Callable[[str, str, float | None], None]
STAGE = "songsterr"
SEARCH_LIMIT = 50
VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{11}")


def song_id(value: str) -> int:
    """O número da música numa URL do songsterr.com (…-s1234) ou o próprio número."""
    value = value.strip()
    if value.isdigit():
        return int(value)
    parsed = urlparse(value)
    if parsed.scheme not in ("http", "https") or parsed.hostname not in ("songsterr.com", "www.songsterr.com"):
        raise SongsterrError("Cole uma URL válida de songsterr.com ou um ID numérico.")
    match = re.search(r"-s(\d+)(?:/|$)", parsed.path)
    if not match:
        raise SongsterrError("Não encontrei o identificador da música na URL.")
    return int(match.group(1))


def search(query: str, *, get=requests.get) -> list[dict]:
    """Músicas do Songsterr para a busca, sem repetir; cada uma com id, artista, título e número de faixas."""
    query = query.strip()
    if len(query) < 2:
        raise SongsterrError("Digite pelo menos duas letras para pesquisar.")
    if len(query) > 200:
        raise SongsterrError("A pesquisa deve ter no máximo 200 caracteres.")
    try:
        response = get("https://www.songsterr.com/api/songs", params={"pattern": query, "size": SEARCH_LIMIT}, timeout=25)
        response.raise_for_status()
        data = response.json()
    except (requests.RequestException, ValueError) as error:
        raise SongsterrError(f"O Songsterr não respondeu à busca ({error.__class__.__name__}).") from None
    if not isinstance(data, list):
        raise SongsterrError("O Songsterr retornou um formato de busca inesperado.")
    results, seen = [], set()
    for item in data:
        if not isinstance(item, dict):
            continue
        sid = item.get("songId")
        if not isinstance(sid, int) or isinstance(sid, bool) or sid <= 0 or sid in seen:
            continue
        seen.add(sid)
        tracks = item.get("tracks")
        results.append({"id": sid, "artist": str(item.get("artist") or "Artista desconhecido"),
                        "title": str(item.get("title") or "Sem título"),
                        "tracks": len(tracks) if isinstance(tracks, list) else 0})
    return results


def signatures(tracks: list[dict]) -> list[tuple[int, int]]:
    """A fórmula de cada compasso, como o conversor escreve no GP: a da primeira faixa, que vale até mudar."""
    current = (4, 4)
    result = []
    for measure in tracks[0].get("measures", []):
        sig = measure.get("signature") if isinstance(measure, dict) else None
        if isinstance(sig, (list, tuple)) and len(sig) == 2 and all(isinstance(v, int) and v > 0 for v in sig):
            current = (int(sig[0]), int(sig[1]))
        result.append(current)
    return result


def track_summary(meta: dict, tracks: list[dict]) -> list[dict]:
    listed = meta.get("tracks") if isinstance(meta.get("tracks"), list) else []
    result = []
    for index, track in enumerate(tracks):
        info = listed[index] if index < len(listed) and isinstance(listed[index], dict) else {}
        tuning = track.get("tuning") if isinstance(track.get("tuning"), list) else None
        result.append({"index": index, "name": str(track.get("name") or info.get("name") or f"Faixa {index + 1}"),
                       "instrument": str(track.get("instrument") or info.get("instrument") or ""),
                       "tuning": tuning})
    return result


class Source:
    """O que a importação busca na rede; os testes trocam por um falso."""

    def fetch(self, ident: int) -> tuple[dict, list[dict]]:
        from .vendor import gen_gp

        with _quiet():
            return gen_gp.fetch_all_tracks(ident)

    def generate(self, tracks: list[dict], path: Path, meta: dict) -> None:
        from .vendor import gen_gp

        with _quiet():
            gen_gp.generate_gp(tracks, path, meta)

    def video_points(self, ident: int, revision: int) -> list[dict]:
        from .vendor import sync

        with _quiet():
            return sync.fetch_video_points(ident, revision)

    def download(self, video_id: str, folder: Path) -> tuple[Path, dict]:
        return download_audio(video_id, folder)


def import_song(url: str, *, source: Source | None = None, root: Path | None = None, mute_vocals: bool = True,
                progress: Progress | None = None, cancel=None) -> SongPackage:
    """Busca a música e publica o pacote; sem vídeo utilizável, o pacote sai só com a partitura e um aviso."""
    source = source or Source()
    ident = song_id(url)
    say = _say(progress, cancel)
    say("Buscando a partitura no Songsterr…", 0.02)
    try:
        meta, tracks = source.fetch(ident)
    except requests.RequestException as error:
        raise SongsterrError(f"O Songsterr não respondeu ({error.__class__.__name__}).") from None
    if not tracks or not tracks[0].get("measures"):
        raise SongsterrError("O Songsterr não retornou faixas e compassos utilizáveis.")
    bars = signatures(tracks)
    origin = {"kind": "songsterr", "songId": ident, "revisionId": meta.get("revisionId"),
              "url": url.strip() if not url.strip().isdigit() else None}
    draft = Draft(str(meta.get("title") or "Sem título"), meta.get("artist"), origin, root=root)
    try:
        say("Montando a TAB…", 0.1)
        with tempfile.TemporaryDirectory(prefix="tracklab-gp-") as temp:
            raw = Path(temp) / "raw.gp"
            source.generate(tracks, raw, meta)
            gp = draft.file("score/original.gp")
            score.replace_zip(raw, gp, lambda xml: score.improve_score(xml, tracks, mute_vocals))
        draft.manifest["score"] = {"file": "score/original.gp", "sha256": sha256_file(gp), "measures": len(bars),
                                   "tracks": track_summary(meta, tracks)}
        _check(cancel)
        try:
            _add_audio(draft, source, ident, meta, bars, say)
        except TrackLabError as error:
            draft.manifest["warnings"].append(f"Áudio não incluído: {error}")
        _check(cancel)
        say("Guardando no repertório…", 0.98)
        return draft.publish()
    except BaseException:
        draft.discard()
        raise


def _add_audio(draft: Draft, source: Source, ident: int, meta: dict, bars: list[tuple[int, int]], say) -> None:
    say("Procurando o vídeo vinculado…", 0.15)
    try:
        entries = source.video_points(ident, meta["revisionId"])
    except (requests.RequestException, KeyError) as error:
        raise SongsterrError(f"não consegui ler os pontos de sincronização ({error.__class__.__name__}).") from None
    candidates = [e for e in entries or [] if isinstance(e, dict) and e.get("feature") is None and e.get("status") == "done"]
    if not candidates:
        raise SongsterrError("não há vídeo principal vinculado e pronto no Songsterr.")
    entry = candidates[0]
    video = str(entry.get("videoId", ""))
    points = entry.get("points") or []
    if not VIDEO_ID.fullmatch(video):
        raise SongsterrError("a identificação do vídeo vinculado é inválida.")
    if len(points) < len(bars):
        raise SongsterrError("os pontos de sincronização são insuficientes para a partitura.")
    if any(isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x) or x < 0 for x in points):
        raise SongsterrError("os pontos de sincronização são inválidos.")
    try:
        tempo = tempomap.from_bar_starts(points, bars)
    except tempomap.RhythmError as error:
        raise SongsterrError(str(error)) from None
    say("Baixando o áudio do vídeo…", 0.2)
    with tempfile.TemporaryDirectory(prefix="tracklab-audio-") as temp:
        downloaded, video_meta = source.download(video, Path(temp))
        say("Convertendo o áudio…", 0.8)
        info = to_source(downloaded, draft.file("audio/source.flac"))
    atomic_json(draft.file("score/tempo-map.json"), tempo)
    draft.manifest["audio"] = {"file": "audio/source.flac", "sha256": info.sha256, "duration": info.duration,
                               "sampleRate": info.sample_rate, "channels": info.channels}
    draft.manifest["tempoMap"] = {"file": "score/tempo-map.json", "source": "songsterr", "points": len(tempo["points"])}
    draft.manifest["origin"].update({"videoId": video, "video": video_meta})
    if len(points) == len(bars):
        draft.manifest["warnings"].append("O último compasso usa andamento estimado; confira o fim da música.")


def download_audio(video_id: str, folder: Path) -> tuple[Path, dict]:
    """O melhor áudio do vídeo, no formato original (a conversão para FLAC é uma só, depois), mais título e duração.

    Tenta primeiro sem runtime JavaScript e, se o YouTube exigir, com o node do Homebrew; nunca usa cookies.
    """
    import yt_dlp

    url = f"https://www.youtube.com/watch?v={video_id}"
    node = shutil.which("node") or shutil.which("node", path=":".join(TOOL_FOLDERS))
    variants = [{}] + ([{"node": {"path": node}}] if node else [])
    failures = []
    for runtimes in variants:
        options = {"format": "bestaudio/best", "outtmpl": str(folder / "audio.%(ext)s"), "quiet": True,
                   "no_warnings": True, "noplaylist": True, "socket_timeout": 30, "retries": 2,
                   "js_runtimes": runtimes}
        try:
            with _quiet(), yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(url, download=True) or {}
        except Exception as error:  # noqa: BLE001 — o yt-dlp levanta de tudo; a mensagem vai para o aviso
            failures.append(str(error).splitlines()[0][:300])
            for partial in folder.glob("audio.*"):
                partial.unlink(missing_ok=True)
            continue
        files = [p for p in folder.glob("audio.*") if p.suffix != ".part" and p.stat().st_size >= 1024]
        if files:
            keep = {k: info[k] for k in ("title", "uploader", "channel", "duration") if isinstance(info.get(k), (str, int, float))}
            return files[0], keep
        failures.append("download sem áudio")
    raise SongsterrError("falha ao baixar o áudio do vídeo: " + (failures[-1] if failures else "sem detalhes"))


@contextlib.contextmanager
def _quiet():
    """O conversor e o yt-dlp falam muito no stdout; o motor usa o stdout para avisar a porta ao app."""
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        yield


def _say(progress: Progress | None, cancel):
    def say(message: str, fraction: float | None = None) -> None:
        _check(cancel)
        if progress is not None:
            progress(STAGE, message, fraction)
    return say


def _check(cancel) -> None:
    if cancel is not None:
        cancel.check()


__all__ = ["Source", "download_audio", "import_song", "search", "signatures", "song_id"]
