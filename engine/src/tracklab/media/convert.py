"""Conversão única para a fonte canônica: MP3 a 320 kbps (`encode`), mono ou estéreo, a 44,1 ou 48 kHz.

Toda etapa seguinte decodifica as mesmas amostras. O atraso do codificador, que costuma deslocar um MP3, vai no
cabeçalho LAME que o ffmpeg grava, e os três leitores do TrackLab o descontam (conferido em 3/11/2026; até então a fonte
era FLAC de 24 bits). A taxa só muda quando não é 44,1 nem 48 kHz.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

import soundfile

from tracklab.errors import MediaError
from tracklab.media import encode
from tracklab.media.probe import media_input, probe, tool
from tracklab.util import new_id, sha256_file

if TYPE_CHECKING:
    from tracklab.jobs import Cancel, Progress

KEPT_RATES = (44_100, 48_000)
DEFAULT_RATE = 48_000
STAGE = "import"


@dataclass(frozen=True)
class SourceInfo:
    path: Path
    duration: float
    sample_rate: int
    channels: int
    frames: int
    sha256: str


def channel_count(path: Path) -> int:
    """Quantos canais tem a primeira faixa de áudio; é o que decide se a importação pede escolha."""
    info = probe(Path(path))
    if not info.has_audio or info.channels is None:
        raise MediaError(f"{Path(path).name} não tem áudio.")
    return info.channels


def to_source(src: Path, dst: Path, *, channels: list[int] | None = None,
              progress: Progress | None = None, cancel: Cancel | None = None) -> SourceInfo:
    """Primeira faixa de áudio de `src` (ou os canais escolhidos) como o MP3 canônico em `dst` (o sufixo vira .mp3),
    gravado de forma atômica."""
    src, dst = Path(src), Path(dst).with_suffix(encode.SUFFIX)
    info = probe(src)
    if not info.has_audio:
        raise MediaError(f"{src.name} não tem áudio para converter.")
    if info.channels is None:
        raise MediaError(f"Não consegui contar os canais de {src.name}.")
    picked = _picked_channels(channels, info.channels)
    rate = info.sample_rate if info.sample_rate in KEPT_RATES else DEFAULT_RATE
    dst.parent.mkdir(parents=True, exist_ok=True)
    temp = dst.with_name(f".{dst.stem}.{new_id()}{encode.SUFFIX}")
    try:
        _run_ffmpeg(_command(src, temp, picked, rate), info.duration, progress, cancel)
        _check_output(temp)
        os.replace(temp, dst)
    finally:
        temp.unlink(missing_ok=True)
    final = soundfile.info(str(dst))
    return SourceInfo(path=dst, duration=final.frames / final.samplerate, sample_rate=final.samplerate,
                      channels=final.channels, frames=final.frames, sha256=sha256_file(dst))


def _picked_channels(channels: list[int] | None, total: int) -> list[int] | None:
    """Mono e estéreo passam inteiros; com mais canais o usuário escolhe um ou dois, nunca uma média."""
    if channels is None:
        if total > 2:
            raise MediaError(f"O arquivo tem {total} canais; escolha um (mono) ou dois (estéreo) para importar.")
        return None
    picked = list(channels)
    if not 1 <= len(picked) <= 2:
        raise MediaError("Escolha um canal (mono) ou dois (estéreo).")
    for index in picked:
        if type(index) is not int or not 0 <= index < total:
            raise MediaError(f"O canal {index} não existe: o arquivo tem {total} canais (0 a {total - 1}).")
    if len(set(picked)) != len(picked):
        raise MediaError("Escolha dois canais diferentes para o estéreo.")
    return picked


def _command(src: Path, temp: Path, picked: list[int] | None, rate: int) -> list[str]:
    command = [tool("ffmpeg"), "-nostdin", "-v", "error", "-y", *media_input(src), "-map", "0:a:0", "-vn", "-sn", "-dn"]
    if picked is not None:
        layout = "mono" if len(picked) == 1 else "stereo"
        routes = "|".join(f"c{out}=c{index}" for out, index in enumerate(picked))
        command += ["-af", f"pan={layout}|{routes}"]
    command += ["-ar", str(rate), *encode.codec_args(), "-progress", "pipe:1", "-nostats", str(temp)]
    return command


def _run_ffmpeg(command: list[str], duration: float | None, progress: Progress | None, cancel: Cancel | None) -> None:
    """Roda o ffmpeg lendo o progresso que ele escreve no stdout; cancelar mata o processo."""
    if cancel is not None:
        cancel.check()
    if progress is not None:
        progress(STAGE, "Convertendo o áudio…", 0.0)
    # stderr vai para um arquivo: um pipe cheio de avisos travaria o ffmpeg enquanto lemos o stdout.
    with tempfile.TemporaryFile() as errors:
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, text=True)
        except OSError as exc:
            raise MediaError(f"Não consegui executar o ffmpeg: {exc}") from exc
        with process:
            try:
                for line in process.stdout:
                    if cancel is not None:
                        cancel.check()
                    fraction = _fraction(line, duration)
                    if fraction is not None and progress is not None:
                        progress(STAGE, "Convertendo o áudio…", fraction)
            finally:
                _stop(process)
        code = process.returncode
        if code != 0:
            errors.seek(0)
            tail = errors.read().decode("utf-8", errors="replace").strip()[-300:]
            raise MediaError(f"Não consegui converter o áudio: {tail or f'ffmpeg terminou com código {code}'}")
    if progress is not None:
        progress(STAGE, "Áudio convertido.", 1.0)


def _fraction(line: str, duration: float | None) -> float | None:
    key, _, value = line.strip().partition("=")
    if key != "out_time_us" or not duration:
        return None
    try:
        seconds = int(value) / 1_000_000
    except ValueError:
        return None
    return min(max(seconds / duration, 0.0), 1.0)


def _stop(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _check_output(temp: Path) -> None:
    """Confere o MP3 antes de colocá-lo no lugar: nunca um arquivo vazio ou ilegível como fonte."""
    encode.check(temp)
