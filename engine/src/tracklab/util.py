"""Utilitários compartilhados: hashes, JSON canônico, escrita atômica, identificadores e tempo."""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    """SHA-256 em hexadecimal, lido em blocos para não carregar o arquivo inteiro."""
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def canonical_json(value: Any) -> str:
    """Forma única de um valor JSON, para hash e comparação: chaves ordenadas, sem espaços, sem NaN."""
    return json.dumps(value, sort_keys=True, ensure_ascii=False, allow_nan=False, separators=(",", ":"))


def sha256_json(value: Any) -> str:
    return sha256_text(canonical_json(value))


def read_json(path: Path) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def atomic_json(path: Path, value: Any) -> None:
    """Grava JSON legível de forma atômica: um arquivo temporário ao lado, depois `os.replace`."""
    atomic_bytes(path, (json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8"))


def atomic_bytes(path: Path, data: bytes) -> None:
    """O temporário tem nome único: duas gravações do mesmo arquivo, em threads ou processos, não se pisam."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
    try:
        temp.write_bytes(data)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def slugify(text: str, limit: int = 40) -> str:
    """Nome de pasta seguro e legível a partir de um título; vazio vira "projeto"."""
    ascii_text = text.encode("ascii", "ignore").decode("ascii") if text.isascii() else _strip_accents(text)
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")
    return slug[:limit].strip("-") or "projeto"


def _strip_accents(text: str) -> str:
    import unicodedata

    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch)).encode("ascii", "ignore").decode("ascii")


def new_id(prefix: str = "") -> str:
    """Identificador curto e único: prefixo opcional mais seis bytes aleatórios em hexadecimal."""
    token = secrets.token_hex(6)
    return f"{prefix}-{token}" if prefix else token


def now_iso() -> str:
    """Instante atual em UTC, ISO 8601 com segundos; é o formato de todas as datas gravadas."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def confined(root: Path, relative: str) -> Path:
    """Caminho dentro de `root`; recusa `..`, absolutos e links que saiam da pasta."""
    root = Path(root).resolve()
    target = (root / relative).resolve()
    if target == root or not target.is_relative_to(root):
        raise ValueError(f"Caminho fora da pasta permitida: {relative}")
    return target
