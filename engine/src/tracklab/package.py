"""O pacote de uma música: uma pasta `<nome>.tracklab` que leva partitura, áudio, mapa de tempo e faixas juntos.

    manifest.json          esquema, origem, hashes e o que existe dentro
    score/original.gp      a partitura como veio do Songsterr (sem áudio embutido)
    score/tempo-map.json   tique ↔ segundo, o contrato do TabLab; os ajustes manuais mudam só este arquivo
    score/tempo-map-history/  as versões anteriores do mapa, uma por ajuste (as últimas `TEMPO_HISTORY`)
    score/tempo-map-original.json  o mapa como veio do Songsterr, guardado antes do primeiro ajuste
    audio/source.flac      o áudio do vídeo vinculado, convertido uma vez
    stems/<chave>/         uma pasta por separação (provedor, modelo e hash do áudio na chave) com `receipt.json`
    peaks/                 caches da Fita, refazíveis

Nada aparece pela metade: um pacote novo nasce numa pasta oculta ao lado e só ganha o nome final quando está
inteiro, e cada separação faz o mesmo dentro de `stems/`. Copiar a pasta para outro Mac leva tudo junto.
"""

from __future__ import annotations

import os
import re
import shutil
import threading
from pathlib import Path

from . import home, repertoire
from .errors import PackageError
from .util import atomic_json, new_id, now_iso, read_json, slugify

SCHEMA = 1
SUFFIX = ".tracklab"
MANIFEST = "manifest.json"
TEMPO_MAP = "score/tempo-map.json"
TEMPO_ORIGINAL = "score/tempo-map-original.json"
TEMPO_HISTORY = 200
_LOCK = threading.RLock()   # o manifesto de um pacote é lido e regravado inteiro; um escritor por vez


class SongPackage:
    """Um pacote publicado. O manifesto é lido do disco a cada acesso: o app e o motor podem tê-lo mudado."""

    def __init__(self, path: Path):
        self.path = Path(path)

    @property
    def manifest(self) -> dict:
        try:
            data = read_json(self.path / MANIFEST)
        except (OSError, ValueError) as error:
            raise PackageError(f"Não consegui ler o pacote {self.path.name}: {error}") from None
        if not isinstance(data, dict) or data.get("schema") != SCHEMA or not isinstance(data.get("id"), str):
            raise PackageError(f"{self.path.name} não é um pacote do TrackLab que este motor conheça.")
        return data

    @property
    def id(self) -> str:
        return self.manifest["id"]

    def file(self, relative: str) -> Path:
        """Um arquivo de dentro do pacote; caminhos que saem dele são recusados."""
        target = (self.path / relative).resolve()
        if not str(relative) or target != self.path.resolve() and self.path.resolve() not in target.parents:
            raise PackageError("Caminho fora do pacote.")
        return target

    def update(self, change) -> dict:
        """Aplica `change(manifest)` (que muda o dicionário no lugar) e regrava o manifesto de forma atômica."""
        with _LOCK:
            data = self.manifest
            change(data)
            data["updated"] = now_iso()
            atomic_json(self.path / MANIFEST, data)
            return data

    def add_stems(self, key: str, build) -> dict:
        """Separação publicada de uma vez: `build(pasta)` grava as faixas e devolve o recibo; só então a pasta entra."""
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,63}", key):
            raise PackageError(f"Chave de faixas inválida: {key}.")
        stems = self.path / "stems"
        stems.mkdir(exist_ok=True)
        final = stems / key
        temp = stems / f".{key}.{new_id()}.partial"
        temp.mkdir()
        try:
            receipt = build(temp)
            if final.exists():
                shutil.rmtree(final)
            temp.rename(final)
        finally:
            if temp.exists():
                shutil.rmtree(temp, ignore_errors=True)
        files = {name: f"stems/{key}/{info['file']}" for name, info in receipt.get("stems", {}).items()}

        def record(data: dict) -> None:
            data.setdefault("stems", {})[key] = {
                "provider": receipt.get("provider", "demucs"), "model": receipt.get("model"),
                "device": receipt.get("device"), "seconds": receipt.get("seconds"),
                "created": receipt.get("created", now_iso()), "files": files,
                **({"fallback": receipt["fallback"]} if receipt.get("fallback") else {})}
            data["activeStems"] = key

        return self.update(record)

    def save_tempo_map(self, tempo_map: dict) -> dict:
        """Grava o mapa (já conferido) como o atual; o anterior vai para `score/tempo-map-history/`, numerado, e
        só as últimas `TEMPO_HISTORY` versões ficam. O manifesto conta pontos e âncoras e marca o ajuste."""
        with _LOCK:
            current = self.file(TEMPO_MAP)
            original = self.file(TEMPO_ORIGINAL)
            if current.is_file() and not original.is_file():
                shutil.copy2(current, original)
            if current.is_file():
                history = self.file("score/tempo-map-history")
                history.mkdir(exist_ok=True)
                versions = sorted(history.glob("*.json"))
                number = int(versions[-1].stem.split("-")[0]) + 1 if versions else 1
                shutil.copy2(current, history / f"{number:06d}-{now_iso().replace(':', '')}.json")
                for old in sorted(history.glob("*.json"))[:-TEMPO_HISTORY]:
                    old.unlink()
            atomic_json(current, tempo_map)

            def record(data: dict) -> None:
                entry = data.get("tempoMap") or {"file": TEMPO_MAP, "source": tempo_map.get("source")}
                entry["points"] = len(tempo_map["points"])
                entry["anchors"] = sum(1 for point in tempo_map["points"] if point.get("kind") == "anchor")
                entry["edited"] = now_iso()
                data["tempoMap"] = entry

            self.update(record)
            return tempo_map

    def set_checked_bars(self, bars: list[int]) -> list[int]:
        """Os compassos (números a partir de 1) que a pessoa conferiu no Ajuste, guardados no manifesto."""
        clean = sorted({int(bar) for bar in bars if isinstance(bar, int) and not isinstance(bar, bool) and bar >= 1})

        def record(data: dict) -> None:
            data["checkedBars"] = clean

        self.update(record)
        return clean

    def set_status(self, status) -> str:
        """O estado de estudo da música (Quero aprender, Aprendendo, Polindo, No repertório, Arquivo)."""
        status = repertoire.check_status(status)
        self.update(lambda data: data.__setitem__("status", status))
        return status

    def set_sections(self, sections) -> list[dict]:
        """Os trechos como o app os mandou (nome, compassos, meta); o treino de cada um continua."""
        merged = []

        def record(data: dict) -> None:
            merged[:] = repertoire.merge_sections(data.get("sections") or [], sections)
            data["sections"] = merged

        self.update(record)
        return merged

    def practice(self, section_id: str, rate, clean: bool) -> dict:
        """Uma passada pelo trecho: a hora, a velocidade e se foi limpa (o recorde sobe com as limpas)."""
        done = {}

        def record(data: dict) -> None:
            sections = data.get("sections") or []
            index = next((k for k, s in enumerate(sections) if s.get("id") == section_id), None)
            if index is None:
                raise repertoire.RepertoireError(f"Trecho não encontrado: {section_id}.")
            sections[index] = repertoire.record_practice(sections[index], rate, clean)
            done.update(sections[index])

        self.update(record)
        return done

    def original_tempo_map(self) -> dict | None:
        """O mapa como veio do Songsterr: o guardado antes do primeiro ajuste, ou o atual se nunca houve ajuste."""
        for relative in (TEMPO_ORIGINAL, TEMPO_MAP):
            if self.file(relative).is_file():
                return read_json(self.file(relative))
        return None

    def summary(self) -> dict:
        data = self.manifest
        return {"id": data["id"], "title": data.get("title"), "artist": data.get("artist"),
                "folder": self.path.name, "hasAudio": bool(data.get("audio")),
                "stems": sorted(data.get("stems", {})), "activeStems": data.get("activeStems"),
                "created": data.get("created"), "updated": data.get("updated"), **repertoire.study_summary(data)}


class Draft:
    """Um pacote em construção numa pasta oculta; `publish` dá o nome final, `discard` apaga."""

    def __init__(self, title: str, artist: str | None, origin: dict, *, root: Path | None = None):
        self.root = Path(root or home.songs())
        self.root.mkdir(parents=True, exist_ok=True)
        self.name = slugify(" ".join(part for part in (artist, title) if part), limit=60)
        self.path = self.root / f".{self.name}.{new_id()}.partial"
        self.path.mkdir()
        for folder in ("score", "audio", "stems", "peaks"):
            (self.path / folder).mkdir()
        self.manifest = {"schema": SCHEMA, "id": new_id("song"), "title": title, "artist": artist,
                         "created": now_iso(), "updated": now_iso(), "origin": origin, "score": None,
                         "audio": None, "tempoMap": None, "stems": {}, "activeStems": None, "warnings": []}

    def file(self, relative: str) -> Path:
        target = self.path / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        return target

    def publish(self) -> SongPackage:
        atomic_json(self.path / MANIFEST, self.manifest)
        for index in range(1000):
            suffix = "" if index == 0 else f"-{index + 1}"
            final = self.root / f"{self.name}{suffix}{SUFFIX}"
            try:
                # mkdir reserva o nome; rename por cima de uma pasta vazia é atômico no mesmo volume.
                final.mkdir()
            except FileExistsError:
                continue
            os.replace(self.path, final)
            return SongPackage(final)
        raise PackageError("Não encontrei um nome livre para o pacote.")

    def discard(self) -> None:
        shutil.rmtree(self.path, ignore_errors=True)


def packages(root: Path | None = None) -> list[SongPackage]:
    """Os pacotes publicados do repertório; pastas pela metade e pacotes ilegíveis ficam de fora."""
    root = Path(root or home.songs())
    found = []
    for path in sorted(root.glob(f"*{SUFFIX}")):
        if path.name.startswith(".") or not (path / MANIFEST).is_file():
            continue
        package = SongPackage(path)
        try:
            package.manifest
        except PackageError:
            continue
        found.append(package)
    return found


def find(song_id: str, root: Path | None = None) -> SongPackage:
    for package in packages(root):
        if package.id == song_id:
            return package
    raise PackageError(f"Música não encontrada: {song_id}.")
