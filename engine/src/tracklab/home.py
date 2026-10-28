"""Onde o TrackLab guarda as coisas: `~/TrackLab`, ou `TRACKLAB_HOME` (testes, uma segunda biblioteca)."""

from __future__ import annotations

import os
from pathlib import Path


def home() -> Path:
    root = Path(os.environ.get("TRACKLAB_HOME") or Path.home() / "TrackLab").expanduser()
    root.mkdir(parents=True, exist_ok=True)
    return root


def songs() -> Path:
    """O repertório: um pacote `.tracklab` por música."""
    folder = home() / "Repertorio"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def models() -> Path:
    """Os pesos dos modelos, fora do app e dos pacotes; conferidos por SHA-256."""
    folder = Path(os.environ.get("TRACKLAB_MODELS") or home() / "Modelos").expanduser()
    folder.mkdir(parents=True, exist_ok=True)
    return folder
