"""Os pesos dos modelos: baixados uma vez e conferidos pelo hash; um arquivo errado nunca entra."""

import hashlib

import pytest

from tracklab import models
from tracklab.errors import ModelError


def catalog(monkeypatch, content: bytes):
    weights = models.Weights(file="demucs/x.safetensors", url="https://example.invalid/x",
                             sha256=hashlib.sha256(content).hexdigest(), size_hint="1 B")
    monkeypatch.setitem(models.CATALOG, "x", weights)


def test_download_once_and_check_the_hash(monkeypatch):
    catalog(monkeypatch, b"pesos")
    calls = []

    def download(url, target):
        calls.append(url)
        target.write_bytes(b"pesos")

    path = models.ensure("x", download=download)
    assert path.read_bytes() == b"pesos" and path.parent.name == "demucs"
    assert models.ensure("x", download=download) == path and len(calls) == 1


def test_a_wrong_file_is_never_kept(monkeypatch):
    catalog(monkeypatch, b"pesos")
    with pytest.raises(ModelError):
        models.ensure("x", download=lambda url, target: target.write_bytes(b"outra coisa"))
    assert not models.path_of("x").exists()
    assert list(models.path_of("x").parent.iterdir()) == []


def test_unknown_model():
    with pytest.raises(ModelError):
        models.ensure("nenhum")
