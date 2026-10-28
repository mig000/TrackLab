"""Faixas separadas de uma música do repertório: a chave junta provedor, modelo, versão e o hash do áudio.

A mesma música com o mesmo modelo nunca separa duas vezes; outro modelo (o MVSEP, mais adiante) é outra pasta em
`stems/`, e o A/B escolhe qual fica ativa.
"""

from __future__ import annotations

from typing import Callable

from .errors import PackageError
from .media import separate as demucs
from .package import SongPackage
from .util import sha256_text

Progress = Callable[[str, str, float | None], None]


def demucs_key(audio_sha: str, version: str) -> str:
    return f"demucs6s-{sha256_text(audio_sha + '|' + version)[:8]}"


def separate_song(package: SongPackage, *, progress: Progress | None = None, cancel=None, device: str | None = None,
                  run=None) -> dict:
    """Separa o áudio do pacote com o Demucs 6s (GPU quando houver) e publica as seis faixas; devolve o registro."""
    manifest = package.manifest
    audio = manifest.get("audio")
    if not audio:
        raise PackageError("Esta música não tem áudio para separar.")
    version = demucs.separator_version()
    key = demucs_key(audio["sha256"], version)
    done = manifest.get("stems", {}).get(key)
    if done and all(package.file(path).is_file() for path in done.get("files", {}).values()):
        if progress is not None:
            progress(demucs.STAGE, "As faixas desta versão já estavam prontas.", 1.0)
        return {"key": key, **done, "reused": True}

    def build(folder):
        receipt = (run or demucs.separate)(package.file(audio["file"]), folder, progress=progress, cancel=cancel,
                                           device=device)
        receipt["provider"] = "demucs"
        return receipt

    updated = package.add_stems(key, build)
    return {"key": key, **updated["stems"][key], "reused": False}
