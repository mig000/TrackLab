"""Achar onde uma gravação cai sobre outra: a multitrack da biblioteca sobre o áudio do vídeo da música.

As duas costumam ser a mesma gravação com começos diferentes (um silêncio, a introdução do álbum que o single não tem)
e com outra transferência da fita: masterização diferente e uma velocidade um pouco diferente (medido em 28/10: 0,4 % no
Highway Star, 0,8 % no Purple Haze, o que também muda o tom). A correlação cruzada com a fase transformada (GCC-PHAT)
ignora a equalização e acha o deslocamento de cada trecho; na mesma gravação, os deslocamentos dos trechos caem numa
reta (a inclinação é a diferença de velocidade), e o consenso dos trechos (RANSAC) separa a reta dos trechos que não
dizem nada. Sem reta, é outra gravação: um cover, uma versão ao vivo. Depois de corrigida a velocidade, uma segunda
passada afina o deslocamento. Entre transferências diferentes sobra uma oscilação de poucos milissegundos (a fita não
corre perfeitamente constante), inaudível para estudar: as faixas tocam no lugar do vídeo, nunca junto com ele.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np

from ..errors import MediaError
from .probe import media_input, probe, tool

ANALYSIS_RATE = 8000
BAND = (100.0, 3500.0)    # Hz: onde as duas gravações têm música de verdade
WINDOW = 8.0              # s: cada trecho conferido (curto, para a diferença de velocidade não borrar o pico)
WINDOWS = 24
SEARCH = 2.0              # s: folga em volta do deslocamento geral, mais o que a velocidade pode ter deslocado
AGREE = 0.02              # s: trechos que caem a menos disso da reta concordam
MIN_AGREED = 5
MIN_AGREEMENT = 0.5       # dos trechos com música
MIN_STRENGTH = 5.0        # pico da correlação em desvios-padrão: abaixo disso o trecho é silêncio ou ruído
MAX_DRIFT = 0.02          # 2 %: mais que isso já é outra gravação (ou outro tom)


def decode(path: Path, rate: int, *, channels: int = 2, speed: float = 1.0) -> np.ndarray:
    """O áudio de `path` em float32 (quadros, canais) na taxa `rate`, pelo ffmpeg (ogg, opus, mp3, wav, flac…).

    `speed` > 1 estica a gravação (ela dura `speed` vezes mais): é a correção de velocidade do alinhamento. O ffmpeg
    só aceita a taxa declarada inteira; o erro do arredondamento fica abaixo de 1/44 100 (7 ms em 5 minutos)."""
    path = Path(path)
    filters = []
    if abs(speed - 1.0) > 1e-9:
        source_rate = probe(path).sample_rate
        if not source_rate:
            raise MediaError(f"Não sei a taxa de {path.name} para corrigir a velocidade.")
        filters = ["-af", f"asetrate={round(source_rate / speed)},aresample={rate}"]
    command = [tool("ffmpeg"), "-nostdin", "-v", "error", *media_input(path), "-map", "0:a:0", "-vn", "-sn", "-dn",
               *filters, "-ac", str(channels), "-ar", str(rate), "-f", "f32le", "pipe:1"]
    try:
        done = subprocess.run(command, capture_output=True, check=False)
    except OSError as error:
        raise MediaError(f"Não consegui executar o ffmpeg: {error}") from None
    if done.returncode != 0:
        tail = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [f"código {done.returncode}"]
        raise MediaError(f"Não consegui ler {path.name}: {tail[0][:200]}")
    data = np.frombuffer(done.stdout, dtype="<f4")
    if data.size == 0:
        raise MediaError(f"{path.name} não tem áudio.")
    return data[: data.size - data.size % channels].reshape(-1, channels).astype(np.float32, copy=False)


def place(data: np.ndarray, lag: int, frames: int) -> np.ndarray:
    """`data` deslocado `lag` quadros (positivo: começa depois) num trecho de `frames` quadros, com silêncio em volta."""
    out = np.zeros((frames,) + data.shape[1:], dtype=np.float32)
    first, last = max(0, lag), min(frames, lag + len(data))
    if last > first:
        out[first:last] = data[first - lag:last - lag]
    return out


def gcc_phat(a: np.ndarray, b: np.ndarray, rate: int = ANALYSIS_RATE) -> tuple[int, float]:
    """Quantas amostras `a` está atrasado em relação a `b` (a[t] ≈ b[t − lag]) e a força do pico (em desvios)."""
    size = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    spectrum = np.fft.rfft(a, size) * np.conj(np.fft.rfft(b, size))
    spectrum /= np.abs(spectrum) + 1e-12
    frequencies = np.fft.rfftfreq(size, 1 / rate)
    spectrum[(frequencies < BAND[0]) | (frequencies > BAND[1])] = 0
    correlation = np.fft.irfft(spectrum, size)
    # Só os atrasos possíveis: de −(len(b) − 1) a len(a) − 1.
    valid = np.concatenate([correlation[:len(a)], correlation[size - len(b) + 1:]])
    lags = np.concatenate([np.arange(len(a)), np.arange(-len(b) + 1, 0)])
    best = int(np.argmax(valid))
    noise = float(np.std(valid)) or 1e-12
    return int(lags[best]), float(valid[best] / noise)


def align(source: np.ndarray, other: np.ndarray, rate: int = ANALYSIS_RATE) -> dict:
    """Onde `other` (mono) cai sobre `source` (mono): tempo na fonte = velocidade × tempo em `other` + deslocamento.

    Devolve o deslocamento e a velocidade, quantos trechos concordaram de quantos tinham música, a força do pico geral
    e o ganho que iguala os volumes (pela energia, que não depende de as formas de onda coincidirem)."""
    lag, strength = gcc_phat(source, other, rate)
    points = _windows(source, other, lambda t: t + lag / rate, rate)
    speed, offset, agreed = _consensus(points)
    if agreed >= 2 and abs(speed - 1) > 1e-4:
        # Segunda passada com a velocidade corrigida: trechos sem borrão, deslocamento mais fino.
        stretched = _stretch(other, speed)
        points = _windows(source, stretched, lambda t: t + offset, rate)
        refined, offset, agreed = _consensus(points)
        speed *= refined
    counted = max(len(points), 1)
    confident = (agreed >= MIN_AGREED and agreed / counted >= MIN_AGREEMENT and abs(speed - 1) <= MAX_DRIFT)
    return {"offset": round(float(offset), 5), "speed": round(float(speed), 7), "windows": len(points),
            "agreed": agreed, "agreement": round(agreed / counted, 3), "strength": round(strength, 1),
            "gain": _gain(source, other, offset, speed, rate), "confident": bool(confident)}


def _windows(source: np.ndarray, other: np.ndarray, guess, rate: int) -> list[tuple[float, float, float]]:
    """(tempo em `other`, tempo na fonte, força) de cada trecho com música; `guess(t)` diz onde procurar."""
    window = int(min(WINDOW * rate, len(other) / 4))
    if window < 2 * rate:
        return []
    margin = int((SEARCH + MAX_DRIFT * len(other) / rate) * rate)
    points = []
    for start in np.linspace(0, len(other) - window, WINDOWS).astype(int):
        piece = other[start:start + window]
        if float(np.sqrt(np.mean(piece ** 2))) < 1e-3:
            continue    # silêncio não diz nada
        center = int(guess(start / rate) * rate)
        low, high = max(0, center - margin), min(len(source), center + window + margin)
        if high - low < window:
            continue    # este trecho cai fora do áudio da fonte
        local, local_strength = gcc_phat(source[low:high], piece, rate)
        if local_strength >= MIN_STRENGTH:
            points.append((start / rate, (low + local) / rate, local_strength))
    return points


def _consensus(points: list[tuple[float, float, float]]) -> tuple[float, float, int]:
    """A reta tempo na fonte = velocidade × t + deslocamento que mais trechos aceitam (a AGREE segundos), refeita
    pelos mínimos quadrados sobre eles: (velocidade, deslocamento, quantos concordaram)."""
    if not points:
        return 1.0, 0.0, 0
    times = np.array([p[0] for p in points])
    found = np.array([p[1] for p in points])
    if len(points) == 1:
        return 1.0, float(found[0] - times[0]), 1
    best = np.zeros(len(points), dtype=bool)
    for i in range(len(points)):
        for j in range(i + 1, len(points)):
            if times[j] - times[i] < 1e-6:
                continue
            slope = (found[j] - found[i]) / (times[j] - times[i])
            if abs(slope - 1) > MAX_DRIFT * 1.5:
                continue
            keep = np.abs(found - (found[i] + slope * (times - times[i]))) < AGREE
            if keep.sum() > best.sum():
                best = keep
    if best.sum() < 2:
        # Nenhum par plausível: o deslocamento mais comum, sem velocidade.
        return 1.0, float(np.median(found - times)), 1
    speed, offset = np.polyfit(times[best], found[best], 1)
    keep = np.abs(found - (speed * times + offset)) < AGREE
    if keep.sum() >= 2:
        speed, offset = np.polyfit(times[keep], found[keep], 1)
    return float(speed), float(offset), int(keep.sum())


def _stretch(signal: np.ndarray, speed: float) -> np.ndarray:
    """`signal` tocado `speed` vezes mais devagar (dura `speed` vezes mais), por interpolação: só para a análise."""
    count = int(len(signal) * speed)
    return np.interp(np.arange(count) / speed, np.arange(len(signal)), signal).astype(np.float32)


def _gain(source: np.ndarray, other: np.ndarray, offset: float, speed: float, rate: int) -> float:
    """O ganho que leva `other` ao volume da fonte, pela energia onde as duas tocam juntas."""
    times = (np.arange(len(source)) / rate - offset) / speed
    inside = (times >= 0) & (times * rate < len(other) - 1)
    if inside.sum() < rate:
        return 1.0
    placed = np.interp(times[inside] * rate, np.arange(len(other)), other)
    energy = float(np.sqrt(np.mean(placed ** 2)))
    if energy <= 1e-6:
        return 1.0
    return round(float(np.clip(np.sqrt(np.mean(source[inside] ** 2)) / energy, 0.1, 10.0)), 4)


__all__ = ["ANALYSIS_RATE", "align", "decode", "gcc_phat", "place"]
