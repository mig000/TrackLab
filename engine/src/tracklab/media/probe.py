"""O que um arquivo importado é: partitura, áudio, vídeo ou desconhecido, com os limites de importação.

Só ffprobe, sem decodificar: a API chama isto a cada arquivo solto na janela.
"""

from __future__ import annotations

import json
import math
import shutil
import subprocess
import zipfile
from dataclasses import dataclass
from pathlib import Path

from tracklab.errors import MediaError

SCORE_EXTENSIONS = frozenset({".gp", ".gp3", ".gp4", ".gp5", ".gpx"})
MAX_DURATION_S = 1800.0
MAX_SIZE_BYTES = 400 * 1024 * 1024
PROBE_TIMEOUT_S = 60
# Capa embutida e imagem solta aparecem como "vídeo" para o ffprobe; não são vídeo de verdade.
IMAGE_CODECS = frozenset({"mjpeg", "png", "bmp", "gif", "webp", "tiff"})
STREAM_ENTRIES = "stream=index,codec_type,codec_name,sample_rate,channels,duration:stream_disposition=attached_pic:format=duration"
TAG_FIELDS = {"title": "title", "artist": "artist", "album_artist": "artist", "album": "album"}
MISSING_FFMPEG = "Instale o ffmpeg (brew install ffmpeg) para importar áudio."


@dataclass(frozen=True)
class Probe:
    kind: str            # audio | video | score | unknown
    duration: float | None
    sample_rate: int | None
    channels: int | None
    codec: str | None
    size: int
    has_audio: bool


# Onde o Homebrew instala no Apple silicon e no Intel. Um app aberto pelo Finder herda um PATH sem essas pastas.
TOOL_FOLDERS = ("/opt/homebrew/bin", "/usr/local/bin")


def tool(name: str) -> str:
    """Caminho do ffmpeg ou do ffprobe: no PATH, senão nas pastas do Homebrew; a mensagem diz como instalar."""
    found = shutil.which(name) or shutil.which(name, path=":".join(TOOL_FOLDERS))
    if found is None:
        raise MediaError(MISSING_FFMPEG)
    return found


def media_input(path: Path) -> list[str]:
    """Entrada do ffmpeg só como arquivo local: sem rede, e um nome começando por '-' não vira opção."""
    return ["-protocol_whitelist", "file", "-i", "file:" + str(Path(path).resolve())]


def probe(path: Path) -> Probe:
    """Classifica o arquivo e recusa o que não pode virar faixa (ilegível, longo, grande, vídeo sem som)."""
    path = Path(path)
    size = _checked_size(path)
    if is_score(path):
        return Probe(kind="score", duration=None, sample_rate=None, channels=None, codec=None, size=size, has_audio=False)
    info = _ffprobe(path, STREAM_ENTRIES)
    if info is None:
        raise MediaError(f"Não consegui ler {path.name} como áudio ou vídeo.")
    streams = info.get("streams", [])
    audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
    video = [stream for stream in streams if _is_real_video(stream)]
    if not audio:
        if video:
            raise MediaError(f"O vídeo {path.name} não tem faixa de áudio.")
        return Probe(kind="unknown", duration=None, sample_rate=None, channels=None, codec=None, size=size, has_audio=False)
    first = audio[0]
    duration = _duration(info, first)
    if duration is None:
        raise MediaError(f"Não consegui medir a duração de {path.name}.")
    if duration > MAX_DURATION_S:
        raise MediaError(f"{path.name} dura {duration / 60:.1f} min ({duration:.0f} s); o limite é {MAX_DURATION_S / 60:.0f} min.")
    return Probe(
        kind="video" if video else "audio",
        duration=duration,
        sample_rate=_int_or_none(first.get("sample_rate")),
        channels=_int_or_none(first.get("channels")),
        codec=first.get("codec_name"),
        size=size,
        has_audio=True,
    )


def is_score(path: Path) -> bool:
    """Guitar Pro pela extensão ou pela assinatura dos primeiros bytes; nunca passa pelo ffprobe."""
    path = Path(path)
    if path.suffix.lower() in SCORE_EXTENSIONS:
        return True
    try:
        with path.open("rb") as stream:
            head = stream.read(64)
    except OSError:
        return False
    if b"FICHIER GUITAR PRO" in head[:32]:   # gp3–gp5: um byte de comprimento e o texto da versão
        return True
    if head.startswith(b"BCFZ"):             # gpx: sistema de arquivos comprimido do Guitar Pro 6
        return True
    if head.startswith(b"PK"):               # gp7 em diante: ZIP; só conta se tiver a partitura dentro
        return _zip_has_gpif(path)
    return False


def tags(path: Path) -> dict[str, str]:
    """Título, artista e álbum gravados no próprio arquivo, para sugerir o nome do projeto; vazio se não houver."""
    path = Path(path)
    if is_score(path):
        return {}
    info = _ffprobe(path, "format_tags:stream_tags")
    if info is None:
        return {}
    raw: dict[str, str] = {}
    sources = [info.get("format", {}).get("tags", {})] + [stream.get("tags", {}) for stream in info.get("streams", [])]
    for source in sources:
        for key, value in source.items():
            raw.setdefault(str(key).lower(), str(value).strip())
    found: dict[str, str] = {}
    for key, field in TAG_FIELDS.items():
        if raw.get(key) and field not in found:
            found[field] = raw[key]
    return found


def _checked_size(path: Path) -> int:
    if not path.is_file():
        raise MediaError(f"Arquivo não encontrado: {path.name}.")
    size = path.stat().st_size
    if size > MAX_SIZE_BYTES:
        raise MediaError(f"{path.name} tem {size / 2**20:.0f} MB; o limite é {MAX_SIZE_BYTES // 2**20} MB.")
    return size


def _ffprobe(path: Path, entries: str) -> dict | None:
    """JSON do ffprobe, ou None quando ele não consegue ler o arquivo."""
    command = [tool("ffprobe"), "-v", "error", *media_input(path), "-show_entries", entries, "-of", "json"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=PROBE_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0:
        return None
    try:
        info = json.loads(result.stdout or "{}")
    except ValueError:
        return None
    return info if isinstance(info, dict) else None


def _is_real_video(stream: dict) -> bool:
    if stream.get("codec_type") != "video":
        return False
    if stream.get("disposition", {}).get("attached_pic"):
        return False
    return stream.get("codec_name") not in IMAGE_CODECS


def _duration(info: dict, stream: dict) -> float | None:
    """Duração do contêiner, ou a da faixa de áudio quando o contêiner não diz."""
    for raw in (info.get("format", {}).get("duration"), stream.get("duration")):
        try:
            value = float(raw)
        except (TypeError, ValueError):
            continue
        if math.isfinite(value) and value > 0:
            return value
    return None


def _int_or_none(raw: object) -> int | None:
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def _zip_has_gpif(path: Path) -> bool:
    try:
        with zipfile.ZipFile(path) as archive:
            return any(name.endswith("score.gpif") for name in archive.namelist())
    except (OSError, zipfile.BadZipFile):
        return False
