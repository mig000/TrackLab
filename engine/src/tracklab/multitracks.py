"""O índice da biblioteca de multitracks: as músicas com as faixas da gravação, para achar pelo nome em milissegundos.

A biblioteca é uma pasta (`TRACKLAB_MULTITRACKS`, ou `~/TrackLab/config.json` → `multitracks`, ou o HD externo de
sempre) com três jeitos de guardar uma música:

    pasta com song.ini        Clone Hero / Rock Band: nome e artista no song.ini; guitar, rhythm, drums*, vocals*,
                              keys e song (o resto da banda) em .ogg
    arquivo .mogg             Rock Band em um arquivo só (todas as faixas juntas); o nome vem do arquivo
    pasta com faixas soltas   multitracks de estúdio (wav, flac, mp3…): o nome vem da pasta, o instrumento do arquivo

O índice é um SQLite em `~/TrackLab/multitracks.sqlite` com uma tabela FTS5 (sem acentos, por começo de palavra). A
varredura é refeita inteira (o HD externo pode ter mudado); com 3.800 músicas leva dezenas de segundos, na fila.

As escondidas (uma regravação que não serve, uma cópia repetida) ficam numa lista à parte, pelo caminho, em
`~/TrackLab/multitracks-hidden.json`: os arquivos da biblioteca não mudam, a varredura continua indexando-as e só a
busca e o casamento com o Songsterr as deixam de fora.
"""

from __future__ import annotations

import configparser
import json
import os
import re
import sqlite3
import unicodedata
from pathlib import Path

from . import home
from .errors import TrackLabError
from .util import atomic_json, now_iso

DEFAULT_ROOT = Path("/Volumes/HD Externo WD/Multitracks")
AUDIO = {".wav", ".flac", ".mp3", ".ogg", ".opus", ".aif", ".aiff", ".m4a"}
SEARCH_LIMIT = 50

# O instrumento de uma faixa pelo nome do arquivo. O nome exato do Clone Hero vale primeiro (`song` é o resto da banda,
# `rhythm` o baixo ou a guitarra base). Depois, numa pasta de faixas soltas, o começo comum dos nomes (o artista e o
# título) não conta: "While My Guitar Gently Weeps Vocals" é a voz. Uma faixa que mistura a guitarra com outra coisa
# ("guitar+synths", "Backing Guitar-Backing Vocals") é guitarra, para o "Sem guitarra" calar toda a guitarra; fora isso,
# vale a palavra de instrumento mais perto do fim, onde as faixas soltas põem o instrumento ("Tom Petty - American Girl
# (06 - Vocals)" é a voz, não os tons da bateria). Os nomes compostos contam inteiros ("Bass Drum" é bateria, "Bass
# Guitar" e "Synth Bass" baixo).
EXACT = {"song": "backing", "rhythm": "rhythm"}
KINDS = [
    ("drums", r"bass ?drum|kick ?drum"),
    ("bass", r"bass ?guitar|synth ?bass|bass ?synth"),
    ("bass", r"\bbass\b|\bbaixo\b"),
    ("guitar", r"guitar|gtr|\bguitarra"),
    ("drums", r"drum|kick|snare|hi.?hat|\btoms?\b|overhead|cymbal|percussion|tambourine|conga"),
    ("vocals", r"vocal|voice|vox|\bsing|choir|\bbv\b|backing v"),
    ("keys", r"keys|piano|organ|synth|keyboard|rhodes|hammond"),
]


class MultitrackError(TrackLabError):
    """A biblioteca de multitracks não está onde deveria, ou o índice não abre."""


def root() -> Path:
    """A pasta da biblioteca: a variável de ambiente, o config.json do TrackLab ou o HD externo de sempre."""
    if os.environ.get("TRACKLAB_MULTITRACKS"):
        return Path(os.environ["TRACKLAB_MULTITRACKS"]).expanduser()
    config = home.home() / "config.json"
    if config.is_file():
        try:
            chosen = json.loads(config.read_text(encoding="utf-8")).get("multitracks")
        except (OSError, ValueError):
            chosen = None
        if isinstance(chosen, str) and chosen:
            return Path(chosen).expanduser()
    return DEFAULT_ROOT


def database() -> Path:
    return home.home() / "multitracks.sqlite"


def hidden_file() -> Path:
    return home.home() / "multitracks-hidden.json"


def hidden() -> set[str]:
    """Os caminhos (relativos à biblioteca) das músicas escondidas."""
    target = hidden_file()
    if not target.is_file():
        return set()
    try:
        paths = json.loads(target.read_text(encoding="utf-8")).get("hidden")
    except (OSError, ValueError, AttributeError):
        return set()
    return {path for path in paths if isinstance(path, str)} if isinstance(paths, list) else set()


def set_hidden(relative: str, hide: bool, path: Path | None = None) -> list[str]:
    """Esconde ou mostra de novo a música do índice com este caminho; devolve a lista das escondidas."""
    paths = hidden()
    if hide:
        if by_path(relative, path=path) is None:
            raise MultitrackError(f"{relative} não está no índice das multitracks.")
        paths.add(relative)
    else:
        paths.discard(relative)
    atomic_json(hidden_file(), {"hidden": sorted(paths)})
    return sorted(paths)


def _plain(filename: str) -> str:
    stem = re.sub(r"^[\d\s._-]+", "", Path(filename).stem.lower())
    return re.sub(r"_\d+$", "", stem)


def _kind(label: str) -> str | None:
    if label in EXACT:
        return EXACT[label]
    found = [(kind, m.start(), m.end()) for kind, pattern in KINDS for m in re.finditer(pattern, label)]
    if not found:
        return None
    compounds = [(start, end) for kind, start, end in found if end - start > 6 and kind in ("bass", "drums")]
    if any(kind == "guitar" and not any(a <= start and end <= b for a, b in compounds) for kind, start, end in found):
        return "guitar"
    # Mais perto do fim; empatado, o nome composto.
    return max(found, key=lambda item: (item[2], item[2] - item[1]))[0]


def kind_of(filename: str, shared: str = "") -> str:
    """O instrumento de uma faixa pelo nome do arquivo (sem extensão, sem número na frente); `shared`, o começo comum
    dos nomes da pasta (`kinds_of`), não conta se o resto do nome diz o instrumento."""
    stem = _plain(filename)
    if shared and stem.startswith(shared):
        found = _kind(stem[len(shared):].strip(" -_.()[]"))
        if found:
            return found
    return _kind(stem) or "other"


def kinds_of(files: list[str]) -> list[str]:
    """O instrumento de cada faixa de uma pasta: o começo comum dos nomes (até o fim de uma palavra) é o artista e o
    título, e só o resto diz o instrumento."""
    plain = [_plain(f) for f in files]
    shared = re.sub(r"\w*$", "", os.path.commonprefix(plain)) if len(plain) >= 2 else ""
    return [kind_of(f, shared) for f in files]


_NOISE = re.compile(r"\s*[\(\[][^\)\]]*(multi.?track|stems?|wav|mp3|flac|cover|isolated|tracks?|remaster\w*)"
                    r"[^\)\]]*[\)\]]\s*", re.IGNORECASE)

def clean_name(text: str) -> str:
    """O nome de uma pasta ou arquivo sem o número da faixa e sem "(Multitrack)", "[WAV]" e parecidos."""
    text = _NOISE.sub(" ", text)
    text = re.sub(r"\b(multi.?tracks?|stems)\b", " ", text, flags=re.IGNORECASE)
    text = re.sub(r"^\s*\d+\s*[-.]?\s+", "", text)
    return re.sub(r"\s+", " ", text).strip(" -_")


def split_name(text: str, artist_hint: str | None = None) -> tuple[str | None, str]:
    """"Artista - Título" em (artista, título); sem o traço, o título e a dica de artista (a pasta de cima)."""
    text = clean_name(text)
    if " - " in text:
        artist, title = text.split(" - ", 1)
        return artist.strip() or artist_hint, title.strip()
    return artist_hint, text


def _read_ini(path: Path) -> dict:
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        parser.read_string(path.read_text(encoding="utf-8-sig", errors="replace"))
    except (OSError, configparser.Error):
        return {}
    section = next((s for s in parser.sections() if s.lower() == "song"), None)
    return dict(parser[section]) if section else {}


def scan(folder: Path, *, progress=None, cancel=None) -> list[dict]:
    """As músicas da biblioteca: caminho, artista, título, álbum, ano, formato, coleção e faixas (arquivo e tipo)."""
    folder = Path(folder)
    if not folder.is_dir():
        raise MultitrackError(f"A biblioteca de multitracks não está em {folder} (o HD externo está ligado?).")
    found: list[dict] = []
    for current, dirs, files in os.walk(folder):
        if cancel:
            cancel.check()  # a fila para a varredura no meio, se pedirem
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d != "__MACOSX")
        here = Path(current)
        relative = here.relative_to(folder)
        collection = relative.parts[0] if relative.parts else ""
        audio = sorted(f for f in files if Path(f).suffix.lower() in AUDIO and not f.startswith("."))
        moggs = sorted(f for f in files if f.lower().endswith(".mogg") and not f.startswith("."))
        if "song.ini" in files:
            info = _read_ini(here / "song.ini")
            artist, title = split_name(here.name, _artist_hint(relative.parts, files_here=False))
            found.append(_song(here, folder, info.get("artist") or artist, info.get("name") or title,
                               info.get("album"), info.get("year"), "clonehero", collection, audio))
            dirs[:] = []
        elif moggs:
            for mogg in moggs:
                artist, title = split_name(Path(mogg).stem, _artist_hint(relative.parts, files_here=True))
                found.append(_song(here / mogg, folder, artist, title, None, None, "mogg", collection, []))
        elif len(audio) >= 2:
            name = here.name
            if " - " not in clean_name(name):
                # Faixas soltas na raiz de uma pasta com o nome da música: o nome comum dos arquivos diz quem toca.
                common = os.path.commonprefix([Path(f).stem for f in audio]).strip(" -_")
                if " - " in common:
                    name = common
            artist, title = split_name(name, _artist_hint(relative.parts, files_here=False))
            found.append(_song(here, folder, artist, title, None, None, "stems", collection, audio))
            dirs[:] = []
        if progress and found and len(found) % 100 == 0:
            progress("multitracks", f"{len(found)} músicas encontradas…", None)
    return found


def _artist_hint(parts: tuple[str, ...], *, files_here: bool) -> str | None:
    """Quem toca, quando o nome não diz: numa coleção "Banda - Rock Band…", a banda; num pack (pack/Artista/…), a
    pasta logo abaixo do pack. `files_here`: as músicas são arquivos desta pasta (os .mogg), não a própria pasta."""
    if not parts:
        return None
    if re.search(r"rock band", parts[0], re.IGNORECASE):
        band = clean_name(re.sub(r"rock band.*$", "", parts[0], flags=re.IGNORECASE))
        if band:
            return band
    return parts[1] if len(parts) >= (2 if files_here else 3) else None


def _song(path: Path, folder: Path, artist, title, album, year, kind: str, collection: str, audio: list[str]) -> dict:
    artist = (artist or "").strip() or None
    title = (title or path.stem).strip()
    if artist and title.lower().startswith(artist.lower() + " ") and len(title) > len(artist) + 1:
        title = title[len(artist):].strip(" -")
    return {"path": str(path.relative_to(folder)), "artist": artist, "title": title,
            "album": (album or "").strip() or None,
            "year": str(year).strip() if year else None, "format": kind, "collection": collection,
            "stems": [{"file": f, "kind": k} for f, k in zip(audio, kinds_of(audio))]}


# MARK: - O índice


def _connect(path: Path | None = None) -> sqlite3.Connection:
    connection = sqlite3.connect(str(path or database()))
    connection.row_factory = sqlite3.Row
    return connection


def build(songs: list[dict], folder: Path, path: Path | None = None) -> dict:
    """Grava o índice inteiro de novo (num arquivo ao lado, trocado no fim): a busca nunca vê um índice pela metade."""
    target = Path(path or database())
    temp = target.with_name(f".{target.name}.partial")
    temp.unlink(missing_ok=True)
    connection = _connect(temp)
    try:
        connection.executescript("""
            CREATE TABLE songs (id INTEGER PRIMARY KEY, path TEXT UNIQUE, artist TEXT, title TEXT, album TEXT,
                                year TEXT, format TEXT, collection TEXT, stems TEXT);
            CREATE VIRTUAL TABLE search USING fts5(title, artist, album, content='songs', content_rowid='id',
                                                   tokenize='unicode61 remove_diacritics 2');
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        connection.executemany(
            "INSERT OR IGNORE INTO songs (path, artist, title, album, year, format, collection, stems) "
            "VALUES (:path, :artist, :title, :album, :year, :format, :collection, :stems)",
            [{**song, "stems": json.dumps(song["stems"], ensure_ascii=False)} for song in songs])
        connection.execute("INSERT INTO search(search) VALUES ('rebuild')")
        count = connection.execute("SELECT count(*) FROM songs").fetchone()[0]
        connection.executemany("INSERT INTO meta VALUES (?, ?)",
                               [("root", str(folder)), ("scanned", now_iso()), ("count", str(count))])
        connection.commit()
    finally:
        connection.close()
    os.replace(temp, target)
    return status(target)


def status(path: Path | None = None) -> dict:
    """Onde está a biblioteca, se o HD está ligado e o que o índice tem."""
    target = Path(path or database())
    folder = root()
    result = {"root": str(folder), "available": folder.is_dir(), "count": 0, "scanned": None, "hidden": len(hidden())}
    if target.is_file():
        with _connect(target) as connection:
            meta = dict(connection.execute("SELECT key, value FROM meta").fetchall())
        result.update(count=int(meta.get("count", 0)), scanned=meta.get("scanned"), indexedRoot=meta.get("root"))
    return result


def _fold(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKD", text.lower()) if not unicodedata.combining(c))


def _query(text: str) -> str | None:
    """A busca do app em FTS5: cada palavra pelo começo, todas obrigatórias."""
    words = re.findall(r"\w+", _fold(text))
    return " ".join(f'"{word}"*' for word in words) or None


def search(text: str, limit: int = SEARCH_LIMIT, path: Path | None = None, *,
           include_hidden: bool = False) -> list[dict]:
    """As músicas do índice que têm todas as palavras (título, artista, álbum), as do título primeiro (bm25); as
    escondidas só com `include_hidden`."""
    query = _query(text)
    target = Path(path or database())
    if not query or not target.is_file():
        return []
    skip = [] if include_hidden else sorted(hidden())
    with _connect(target) as connection:
        rows = connection.execute(
            "SELECT songs.* FROM search JOIN songs ON songs.id = search.rowid WHERE search MATCH ? "
            f"AND songs.path NOT IN ({','.join('?' * len(skip))}) "
            "ORDER BY bm25(search, 10.0, 5.0, 1.0) LIMIT ?", (query, *skip, limit)).fetchall()
    return _rows(rows)


def hidden_songs(path: Path | None = None) -> list[dict]:
    """As escondidas que estão no índice, por artista e título."""
    target = Path(path or database())
    paths = sorted(hidden())
    if not paths or not target.is_file():
        return []
    with _connect(target) as connection:
        rows = connection.execute(f"SELECT * FROM songs WHERE path IN ({','.join('?' * len(paths))}) "
                                  "ORDER BY artist, title, path", paths).fetchall()
    return _rows(rows)


def by_path(relative: str, path: Path | None = None) -> dict | None:
    """A música do índice com este caminho (relativo à biblioteca), ou None. Pedida pelo caminho, uma escondida vale."""
    target = Path(path or database())
    if not target.is_file():
        return None
    with _connect(target) as connection:
        row = connection.execute("SELECT * FROM songs WHERE path = ?", (relative,)).fetchone()
    return _rows([row])[0] if row else None


def match(artist: str, title: str, path: Path | None = None) -> dict | None:
    """A música da biblioteca que é esta (o resultado do Songsterr): o mesmo título e o mesmo artista, sem acentos,
    pontuação nem "(Live)" e parecidos."""
    want_title, want_artist = _key(title), _key(artist)
    if not want_title:
        return None
    candidates = [found for found in (search(f"{want_title} {want_artist}", limit=20, path=path)
                                      or search(want_title, limit=20, path=path))
                  if _key(found["title"]) == want_title
                  and (not want_artist or _key(found["artist"] or "") == want_artist)]
    # Repetida na biblioteca, vale a que o TrackLab sabe importar: faixas separadas antes do .mogg.
    candidates.sort(key=lambda found: found["format"] == "mogg")
    return candidates[0] if candidates else None


def _key(text: str) -> str:
    text = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", _fold(text))
    return " ".join(re.findall(r"\w+", re.sub(r"^the\s+", "", text)))


def _rows(rows: list[sqlite3.Row]) -> list[dict]:
    paths = hidden()
    return [_row(row, row["path"] in paths) for row in rows]


def _row(row: sqlite3.Row, is_hidden: bool = False) -> dict:
    stems = json.loads(row["stems"] or "[]")
    return {"id": row["id"], "path": row["path"], "artist": row["artist"], "title": row["title"], "album": row["album"],
            "year": row["year"], "format": row["format"], "collection": row["collection"], "stems": stems,
            "kinds": sorted({stem["kind"] for stem in stems}), "hidden": is_hidden}


__all__ = ["MultitrackError", "root", "scan", "build", "status", "search", "match", "by_path", "hidden", "set_hidden",
           "hidden_songs", "kind_of", "kinds_of", "clean_name", "split_name"]
