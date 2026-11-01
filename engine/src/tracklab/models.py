"""Pesos dos modelos (separação e acordes pelo som): baixados uma vez de uma revisão fixa e conferidos por SHA-256.

O hash é o contrato: o mesmo arquivo dá as mesmas faixas no Intel e no Apple Silicon, e um download truncado ou
trocado nunca chega ao modelo. Nada é buscado se o arquivo certo já está na pasta.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from . import home
from .errors import ModelError
from .util import new_id, sha256_file

CHUNK = 1 << 20
TIMEOUT_S = 60


CHORDNET_URL = ("https://raw.githubusercontent.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition/"
                "481f4ce703f8822b99f4037e9104ba1760e21ea3/cache_data/")


@dataclass(frozen=True)
class Weights:
    file: str
    url: str
    sha256: str
    size_hint: str


# htdemucs_6s: huggingface.co/adefossez/HTDemucs-6s na revisão 3c5ee475 (MIT); é o mesmo arquivo que o TabLab confere.
CATALOG = {
    "htdemucs_6s": Weights(
        file="demucs/htdemucs_6s-5c90dfd2.safetensors",
        url="https://huggingface.co/adefossez/HTDemucs-6s/resolve/3c5ee475be622df764938de97e4281a7b07ffa58/"
            "5c90dfd2.safetensors",
        sha256="d2a1745f0744721f6b8ca5bf469b67c651ea5ed1b52998cab033b2158609d411",
        size_hint="~110 MB",
    ),
    # As cinco redes do Chord-CNN-LSTM (media/chordsound.py): github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-
    # Recognition no commit 481f4ce7 (MIT), as mesmas que o ChordMiniApp usa.
    "chordnet_s0": Weights(
        file="chordnet/joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s0.best.sdict",
        url=CHORDNET_URL + "joint_chord_net_ismir_naive_v1.0_reweight%280.0%2C10.0%29_s0.best.sdict",
        sha256="921b42d5d1cf9ce1c0c0e45a74d409b8066e0acec46058ef74e24ee0fb540761",
        size_hint="~5,5 MB",
    ),
    "chordnet_s1": Weights(
        file="chordnet/joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s1.best.sdict",
        url=CHORDNET_URL + "joint_chord_net_ismir_naive_v1.0_reweight%280.0%2C10.0%29_s1.best.sdict",
        sha256="bcb75859e0efa256696cf5da396b320093317b9b1d9560c304f46c25fe1f8b17",
        size_hint="~5,5 MB",
    ),
    "chordnet_s2": Weights(
        file="chordnet/joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s2.best.sdict",
        url=CHORDNET_URL + "joint_chord_net_ismir_naive_v1.0_reweight%280.0%2C10.0%29_s2.best.sdict",
        sha256="acddf85c3fff29954c4877021177d72e2cba9f729ce80c1010f054c477bf3f61",
        size_hint="~5,5 MB",
    ),
    "chordnet_s3": Weights(
        file="chordnet/joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s3.best.sdict",
        url=CHORDNET_URL + "joint_chord_net_ismir_naive_v1.0_reweight%280.0%2C10.0%29_s3.best.sdict",
        sha256="65d81a3ab73435aaaade586981b4cabdf57b8953d76052703e6968c32ef8421c",
        size_hint="~5,5 MB",
    ),
    "chordnet_s4": Weights(
        file="chordnet/joint_chord_net_ismir_naive_v1.0_reweight(0.0,10.0)_s4.best.sdict",
        url=CHORDNET_URL + "joint_chord_net_ismir_naive_v1.0_reweight%280.0%2C10.0%29_s4.best.sdict",
        sha256="5ff6b0ec85640e17a09a9b3de68c93fdd45adc24488e8fa9be5715c28d561122",
        size_hint="~5,5 MB",
    ),
}

# As redes dos acordes pelo som, na ordem.
CHORDNET = [f"chordnet_s{i}" for i in range(5)]


def path_of(model: str) -> Path:
    if model not in CATALOG:
        raise ModelError(f"Modelo desconhecido: {model}.")
    return home.models() / CATALOG[model].file


def ensure(model: str, *, download=None) -> Path:
    """O arquivo de pesos, conferido; baixa se faltar. `download(url, destino)` é trocável nos testes."""
    weights = CATALOG.get(model)
    if weights is None:
        raise ModelError(f"Modelo desconhecido: {model}.")
    path = path_of(model)
    if path.is_file() and sha256_file(path) == weights.sha256:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{new_id()}.part")
    try:
        (download or _download)(weights.url, temp)
        got = sha256_file(temp)
        if got != weights.sha256:
            raise ModelError(f"Os pesos de {model} baixados não conferem com o hash esperado; nada foi gravado.")
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)
    return path


def _download(url: str, target: Path) -> None:
    import requests

    try:
        with requests.get(url, stream=True, timeout=TIMEOUT_S) as response:
            response.raise_for_status()
            with target.open("wb") as out:
                for block in response.iter_content(CHUNK):
                    out.write(block)
    except requests.RequestException as error:
        raise ModelError(f"Não consegui baixar os pesos ({error.__class__.__name__}). Confira a internet e tente de novo.") from None
