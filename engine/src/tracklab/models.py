"""Pesos dos modelos de separação: baixados uma vez de uma revisão fixa e conferidos por SHA-256.

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
}


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
