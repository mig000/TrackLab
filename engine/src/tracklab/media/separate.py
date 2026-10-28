"""Separação de instrumentos com o Demucs local: um FLAC por stem, com recibo, para virar faixas do projeto."""

from __future__ import annotations

import math
import time
from importlib import metadata
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile

from ..errors import MediaError
from ..models import CATALOG
from ..util import atomic_json, new_id, now_iso, sha256_file

Progress = Callable[[str, str, float | None], None]

STAGE = "separate"
MODEL = "htdemucs_6s"
STEMS = ("guitar", "bass", "drums", "vocals", "piano", "other")
# Versão do nosso uso do Demucs (normalização, deslocamentos, sobreposição, formato de saída).
PROCEDURE = "separate.v1"
OVERLAP = 0.25
DEVICES = ("mps", "cpu")
INSTALL_HINT = "Instale com `cd engine && uv sync --extra separate`."


def separator_version(model: str = MODEL) -> str:
    """Versão que entra na chave do cache: o procedimento, o Demucs instalado e o modelo."""
    try:
        demucs = metadata.version("demucs")
    except metadata.PackageNotFoundError:
        raise MediaError(f"A separação de instrumentos precisa do Demucs (grupo engine). {INSTALL_HINT}") from None
    return f"{PROCEDURE}/demucs-{demucs}/{model}"


def default_device() -> str:
    """MPS quando houver, senão CPU; a separação é só inferência e cabe na GPU do Mac."""
    import torch

    return "mps" if torch.backends.mps.is_available() else "cpu"


def separate(source: Path, output: Path, *, model: str = MODEL, progress: Progress | None = None,
             cancel=None, device: str | None = None) -> dict:
    """Separa `source` em `output/<stem>.flac` (mesma taxa e mesmo número de quadros da fonte) e grava `receipt.json`."""
    source, output = Path(source), Path(output)
    version = separator_version(model)
    if device is not None and device not in DEVICES:
        raise MediaError(f"Dispositivo desconhecido para a separação: {device}. Use mps ou cpu.")
    _check(cancel)
    started = time.monotonic()
    audio_sha = sha256_file(source)
    mix, rate = _read(source)
    _emit(progress, "Carregando o modelo de separação…", 0.0)
    network = _load_model(model)
    missing = [stem for stem in STEMS if stem not in network.sources]
    if missing:
        raise MediaError(f"O modelo {model} não separa {', '.join(missing)}; use {MODEL}.")
    device = device or default_device()
    fallback = None
    try:
        stems = _run(network, mix, rate, device, progress, cancel)
    except RuntimeError as error:
        # O MPS da GPU AMD do iMac depende da versão do torch; se uma operação falhar lá, a CPU termina o trabalho.
        if device != "mps":
            raise MediaError(f"A separação falhou: {error}") from None
        fallback = f"GPU recusou ({str(error).splitlines()[0][:200]}); separado na CPU."
        _emit(progress, "A GPU recusou; separando na CPU…", 0.0)
        device = "cpu"
        stems = _run(network, mix, rate, device, progress, cancel)
    _check(cancel)
    output.mkdir(parents=True, exist_ok=True)
    files = {}
    for stem in STEMS:
        files[stem] = _write_stem(output / f"{stem}.flac", stems[stem], rate)
    receipt = {"model": model, "version": version, "demucs": metadata.version("demucs"), "audioSHA256": audio_sha,
               "modelSHA256": CATALOG[model].sha256,
               "sampleRate": rate, "frames": int(mix.shape[1]), "duration": mix.shape[1] / rate, "device": device,
               "overlap": OVERLAP, "shifts": 0, "seconds": round(time.monotonic() - started, 3),
               "created": now_iso(), "stems": files}
    if fallback:
        receipt["fallback"] = fallback
    atomic_json(output / "receipt.json", receipt)
    _emit(progress, "Instrumentos separados.", 1.0)
    return receipt


def _read(source: Path) -> tuple[np.ndarray, int]:
    """Fonte como (canais, quadros) em float32; mono vira estéreo repetido, porque o modelo espera dois canais."""
    try:
        data, rate = soundfile.read(str(source), dtype="float32", always_2d=True)
    except (RuntimeError, soundfile.LibsndfileError) as error:
        raise MediaError(f"Não consegui ler {source.name} para separar: {error}") from None
    if data.shape[0] == 0:
        raise MediaError(f"{source.name} está vazio; não há o que separar.")
    mix = data.T
    if mix.shape[0] == 1:
        mix = np.concatenate([mix, mix])
    return np.ascontiguousarray(mix[:2]), int(rate)


def weights_path(model: str = MODEL) -> Path:
    """O arquivo de pesos do modelo na pasta de modelos, baixado uma vez e conferido pelo hash."""
    from ..models import ensure

    return ensure(model)


def _load_model(model: str):
    """Modelo pré-treinado do Demucs a partir dos pesos locais, sem o HuggingFace Hub."""
    from demucs.apply import BagOfModels
    from demucs.hf import load_safetensors_model

    path = weights_path(model)
    try:
        return BagOfModels([load_safetensors_model(path)])
    except Exception as error:
        raise MediaError(f"Não consegui carregar o modelo {model} do Demucs: {error}") from None


def _run(network, mix: np.ndarray, rate: int, device: str, progress: Progress | None, cancel) -> dict[str, np.ndarray]:
    """Reamostra para a taxa do modelo, separa bloco a bloco e devolve cada stem na taxa e no tamanho da fonte."""
    import julius
    import torch
    from demucs.apply import BagOfModels, apply_model

    frames = mix.shape[1]
    wav = torch.from_numpy(mix)
    if rate != network.samplerate:
        wav = julius.resample_frac(wav, rate, network.samplerate)
    # A mesma normalização do `demucs.api`: média e desvio do sinal mono.
    reference = wav.mean(0)
    mean = reference.mean()
    std = reference.std() + 1e-8
    models = list(network.models) if isinstance(network, BagOfModels) else [network]
    total = sum(_blocks(wav.shape[1], member) for member in models)
    done = [0]

    def callback(info: dict) -> None:
        # O cancelamento sobe pela execução do Demucs, que interrompe os blocos restantes.
        if info.get("state") == "start":
            _check(cancel)
            return
        done[0] += 1
        _emit(progress, f"Separando instrumentos (bloco {done[0]} de {total})…", min(done[0] / total, 1.0) * 0.95)

    with torch.no_grad():
        out = apply_model(network, ((wav - mean) / std)[None], shifts=0, split=True, overlap=OVERLAP,
                          device=device, callback=callback)
    out = (out[0] * std + mean).cpu()
    stems = {}
    for index, name in enumerate(network.sources):
        stem = out[index]
        if rate != network.samplerate:
            stem = julius.resample_frac(stem, network.samplerate, rate, output_length=frames)
        stems[name] = stem.numpy()[:, :frames]
    return stems


def _blocks(length: int, member) -> int:
    """Quantos blocos o `apply_model` processa para um modelo, para o progresso ser por bloco."""
    segment = int(member.samplerate * float(member.segment))
    stride = int((1 - OVERLAP) * segment)
    return max(1, math.ceil(length / stride))


def _write_stem(path: Path, stem: np.ndarray, rate: int) -> dict:
    """Grava um stem em FLAC de 24 bits de forma atômica; o que passar do fundo de escala é cortado e contado."""
    clipped = int(np.count_nonzero(np.abs(stem) > 1.0))
    data = np.clip(stem, -1.0, 1.0).T
    temp = path.with_name(f".{path.stem}.{new_id()}.flac")
    try:
        soundfile.write(str(temp), data, rate, subtype="PCM_24", format="FLAC")
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)
    return {"file": path.name, "sha256": sha256_file(path), "peak": float(np.max(np.abs(stem))) if stem.size else 0.0,
            "clippedSamples": clipped}


def _check(cancel) -> None:
    if cancel is not None:
        cancel.check()


def _emit(progress: Progress | None, message: str, fraction: float | None) -> None:
    if progress is not None:
        progress(STAGE, message, fraction)


__all__ = ["MODEL", "STEMS", "default_device", "separate", "separator_version"]
