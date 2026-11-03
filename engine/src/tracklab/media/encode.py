"""O formato de todo áudio que o TrackLab grava: MP3 a 320 kbps (CBR), pelo LAME do ffmpeg.

Decidido em 3/11/2026 (antes era FLAC de 24 bits: 6,6 GB para 16 músicas, quase tudo áudio que o próprio TrackLab
gerou). O MP3 do ffmpeg leva o cabeçalho LAME com o atraso e o enchimento do codificador, e os três leitores do
TrackLab o respeitam: o AVAudioFile do app, o soundfile (libsndfile 1.2 com o mpg123) e o ffmpeg dão o mesmo número de
quadros do original e as amostras no mesmo lugar (medido numa faixa de 5:46: desvio zero, diferença de 0,01 % da
energia). No app a busca no meio do arquivo leva 3 a 6 ms (no FLAC, 24 a 100 ms: o decodificador da Apple percorria o
arquivo até o ponto). Uma faixa de 6 minutos fica com 14 MB (68 MB em FLAC).
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import numpy as np
import soundfile

from ..errors import MediaError
from ..util import new_id
from .probe import tool

SUFFIX = ".mp3"
BITRATE = "320k"
FRAME = 1152   # amostras num quadro de MP3


def codec_args() -> list[str]:
    """Os argumentos do ffmpeg para gravar o MP3 do TrackLab (depois da entrada, antes do arquivo de saída)."""
    return ["-c:a", "libmp3lame", "-b:a", BITRATE, "-f", "mp3"]


def write_mp3(path: Path, data: np.ndarray, rate: int) -> Path:
    """Grava `data` (quadros, canais) em float, de −1 a 1, como MP3 em `path` (com o sufixo trocado para .mp3), de
    forma atômica; devolve o caminho gravado."""
    path = Path(path).with_suffix(SUFFIX)
    data = np.ascontiguousarray(np.asarray(data, dtype="<f4"))
    if data.ndim == 1:
        data = data[:, None]
    frames, channels = data.shape
    if frames == 0:
        raise MediaError(f"Nada para gravar em {path.name}.")
    temp = path.with_name(f".{path.stem}.{new_id()}{SUFFIX}")
    command = [tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-f", "f32le", "-ar", str(rate), "-ac", str(channels),
               "-i", "pipe:0", *codec_args(), str(temp)]
    try:
        done = subprocess.run(command, input=data.tobytes(), capture_output=True, check=False)
        if done.returncode != 0:
            tail = done.stderr.decode("utf-8", "replace").strip()[-300:]
            raise MediaError(f"Não consegui gravar {path.name}: {tail or f'ffmpeg terminou com código {done.returncode}'}")
        check(temp, frames)
        os.replace(temp, path)
    except OSError as error:
        raise MediaError(f"Não consegui gravar {path.name}: {error}") from None
    finally:
        temp.unlink(missing_ok=True)
    return path


def check(path: Path, frames: int | None = None) -> int:
    """Confere um MP3 antes de pô-lo no lugar: legível, com amostras e, se `frames` vier, com esse número de quadros
    (o atraso do codificador descontado, até um quadro de MP3 a mais ou a menos no fim). Devolve os quadros."""
    try:
        written = soundfile.info(str(path))
    except RuntimeError as exc:   # soundfile.LibsndfileError herda de RuntimeError
        raise MediaError(f"O MP3 gravado não abre: {exc}") from exc
    if written.frames <= 0:
        raise MediaError("O MP3 gravado não tem amostras.")
    # O começo é o que alinha as faixas (o atraso do codificador, descontado pelo cabeçalho LAME); no fim o ffmpeg às
    # vezes deixa umas amostras a mais (1.102.500 viram 1.102.511, igual nos três leitores). Mais de um quadro de MP3
    # de diferença é o cabeçalho faltando.
    if frames is not None and abs(written.frames - frames) > FRAME:
        raise MediaError(f"O MP3 gravado tem {written.frames} quadros, e não {frames}: o atraso do codificador não foi "
                         "descontado e as faixas sairiam do lugar.")
    return int(written.frames)


__all__ = ["BITRATE", "SUFFIX", "check", "codec_args", "write_mp3"]
