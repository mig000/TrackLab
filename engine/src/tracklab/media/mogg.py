"""Os .mogg do Rock Band: todas as faixas da gravação num Ogg de muitos canais, sem o mapa de quem é quem.

O mapa dos canais (bateria, baixo, guitarra, voz, teclado, o público) fica no `songs.dta` do jogo, que a biblioteca
não tem: os .mogg vieram soltos (e, com até 8 canais, o ffmpeg ainda reordena os canais do Vorbis ao ler). Então cada canal é reconhecido pelo som, contra as faixas do Demucs da própria música
(já alinhadas ao vídeo): depois de a soma dos canais ser alinhada ao vídeo (`align`), o espectro de cada canal ao longo
do tempo (bandas de energia a cada 0,1 s) é comparado com o de cada faixa do Demucs, e o canal vai para a faixa mais
parecida; o que não se parece com nenhuma (o público, um canal mudo) fica de fora. Dois canais da mesma faixa que andam
juntos são um par estéreo (esquerdo e direito); os outros entram no centro.

O cabeçalho aberto do Rock Band (versão 10) diz em que byte o Ogg começa; alguns .mogg são um Ogg comum com outra
extensão. Os de cabeçalho criptografado (versões 11 a 16, dos discos e da loja) são recusados: medido em 30/10, nenhum
dos 631 da biblioteca era.
"""

from __future__ import annotations

import struct
import subprocess
import time
from pathlib import Path

import numpy as np
import soundfile

from ..errors import MediaError
from ..util import atomic_json, now_iso, sha256_file
from . import align
from .multitrack import Progress, _check, _emit
from .probe import probe, tool
from .separate import _write_stem

PROCEDURE = "mogg.v1"
OPEN_HEADER = 10
FRAME = 0.1               # s por quadro das bandas
BANDS = 24                # bandas de energia, de 40 Hz até perto da metade da taxa de análise
MIN_SCORE = 0.3           # semelhança mínima com uma faixa do Demucs; abaixo disso o canal fica de fora
PAIR = 0.5                # correlação entre dois canais vizinhos da mesma faixa para serem um par estéreo


def ogg_start(path: Path) -> int:
    """Em que byte o Ogg começa dentro do .mogg; recusa o cabeçalho criptografado."""
    with open(path, "rb") as handle:
        head = handle.read(8)
    if head[:4] == b"OggS":
        return 0
    if len(head) < 8:
        raise MediaError(f"{Path(path).name} não é um .mogg.")
    version, start = struct.unpack("<II", head)
    if version != OPEN_HEADER:
        raise MediaError(f"{Path(path).name} é um .mogg criptografado (versão {version}): só os abertos entram.")
    return start


def extract(path: Path, folder: Path) -> Path:
    """O Ogg de dentro do .mogg, num arquivo que o ffmpeg lê."""
    start = ogg_start(path)
    target = Path(folder) / "mogg.ogg"
    with open(path, "rb") as source, open(target, "wb") as out:
        source.seek(start)
        while chunk := source.read(1 << 20):
            out.write(chunk)
    return target


def _ffmpeg(path: Path, rate: int, channels: int, filters: list[str]) -> np.ndarray:
    command = [tool("ffmpeg"), "-nostdin", "-v", "error", "-i", str(path), "-map", "0:a:0", "-vn",
               *(["-af", ",".join(filters)] if filters else []), "-ar", str(rate), "-ac", str(channels),
               "-f", "f32le", "pipe:1"]
    try:
        done = subprocess.run(command, capture_output=True, check=False)
    except OSError as error:
        raise MediaError(f"Não consegui executar o ffmpeg: {error}") from None
    if done.returncode != 0:
        tail = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [f"código {done.returncode}"]
        raise MediaError(f"Não consegui ler o .mogg: {tail[0][:200]}")
    data = np.frombuffer(done.stdout, dtype="<f4")
    return data[: data.size - data.size % channels].reshape(-1, channels).astype(np.float32, copy=False)


def _speed(path: Path, rate: int, speed: float) -> list[str]:
    if abs(speed - 1.0) <= 1e-9:
        return []
    source_rate = probe(path).sample_rate
    if not source_rate:
        raise MediaError("Não sei a taxa do .mogg para corrigir a velocidade.")
    return [f"asetrate={round(source_rate / speed)}", f"aresample={rate}"]


def channels_of(path: Path, rate: int, count: int, speed: float = 1.0) -> np.ndarray:
    """Todos os canais, separados (quadros, canais), na taxa `rate` e com a velocidade corrigida."""
    return _ffmpeg(path, rate, count, _speed(path, rate, speed))


def mix(path: Path, rate: int, left: list[int], right: list[int], speed: float = 1.0) -> np.ndarray:
    """Os canais escolhidos somados em estéreo (quadros, 2): `left` à esquerda, `right` à direita."""
    pan = "pan=stereo|c0=" + "+".join(f"c{i}" for i in left) + "|c1=" + "+".join(f"c{i}" for i in right)
    return _ffmpeg(path, rate, 2, [pan, *_speed(path, rate, speed)])


def bands(signal: np.ndarray, rate: int) -> np.ndarray:
    """A energia (dB) em `BANDS` bandas de frequência espaçadas em escala log, a cada `FRAME` s: (quadros, bandas)."""
    hop = int(FRAME * rate)
    size = 1 << int(np.ceil(np.log2(2 * hop)))
    count = max(0, (len(signal) - size) // hop + 1)
    if count == 0:
        return np.zeros((0, BANDS), dtype=np.float32)
    frames = np.lib.stride_tricks.sliding_window_view(signal, size)[::hop][:count]
    power = np.abs(np.fft.rfft(frames * np.hanning(size), axis=1)) ** 2
    edges = np.geomspace(40, rate * 0.48, BANDS + 1) * size / rate
    out = np.stack([power[:, int(a):max(int(a) + 1, int(b))].sum(axis=1) for a, b in zip(edges[:-1], edges[1:])], 1)
    return (10 * np.log10(out + 1e-10)).astype(np.float32)


def similarity(channel: np.ndarray, stem: np.ndarray) -> float:
    """O quanto o espectro do canal anda com o da faixa: a correlação das bandas (cada uma sem a sua média), só nos
    quadros em que o canal toca (até 50 dB abaixo do mais forte)."""
    count = min(len(channel), len(stem))
    a, b = channel[:count], stem[:count]
    level = a.max(axis=1)
    active = level > level.max() - 50
    if active.sum() < 20:
        return 0.0
    a, b = a[active], b[active]
    a = a - a.mean(axis=0)
    b = b - b.mean(axis=0)
    norm = float(np.sqrt((a * a).sum() * (b * b).sum()))
    return float((a * b).sum() / norm) if norm > 0 else 0.0


# A ordem dos canais no Rock Band: bateria, baixo, guitarra, voz, depois o "backing" (o resto da banda, no fim, antes
# do público). O teclado, quando tem, vem em qualquer lugar depois da guitarra.
ORDER = {"drums": 0, "bass": 1, "guitar": 2, "vocals": 3, "other": 5}
ORDERED_FROM = 9          # com até 8 canais o ffmpeg reordena os canais do Vorbis e a ordem não diz nada


def classify(channels: np.ndarray, stems: dict[str, np.ndarray], rate: int) -> list[tuple[str | None, float]]:
    """A faixa de cada canal (ou nil, se não se parece com nenhuma) e a semelhança.

    Com 9 canais ou mais (58 de 60 numa amostra da biblioteca) a ordem do Rock Band desempata: a melhor sequência
    de faixas que respeita a ordem (programação dinâmica). Sem ela, o Demucs confundia o órgão do backing do Highway
    Star com a guitarra. Um canal do backing vale como "other" pelo que mais se parece (ele mistura o resto da banda);
    o público, que não se parece com nada, fica de fora."""
    references = {name: bands(signal, rate) for name, signal in stems.items()}
    scores = []
    for index in range(channels.shape[1]):
        mine = bands(channels[:, index], rate)
        scores.append({name: similarity(mine, theirs) for name, theirs in references.items()})
    if channels.shape[1] < ORDERED_FROM:
        result = []
        for row in scores:
            best = max(row, key=row.get) if row else None
            top = round(row[best], 3) if best else 0.0
            result.append((best, top) if best and row[best] >= MIN_SCORE else (None, top))
        return result
    return _ordered(scores)


def _ordered(scores: list[dict[str, float]]) -> list[tuple[str | None, float]]:
    def options(row):
        found = [(name, row[name]) for name in ORDER if name in row and name != "other"]
        found.append(("other", 0.9 * max(row.values(), default=0.0)))
        if "piano" in row:
            found.append(("piano", row["piano"]))
        found.append((None, MIN_SCORE))
        return found

    # Estado: a posição na ordem a que já se chegou (o teclado e o "de fora" não avançam).
    best: dict[int, tuple[float, list[tuple[str | None, float]]]] = {-1: (0.0, [])}
    for row in scores:
        following: dict[int, tuple[float, list[tuple[str | None, float]]]] = {}
        for state, (total, labels) in best.items():
            for name, value in options(row):
                if name is None:
                    after = state
                elif name == "piano":
                    if state < ORDER["guitar"]:
                        continue
                    after = state
                else:
                    if ORDER[name] < state:
                        continue
                    after = ORDER[name]
                candidate = (total + value, labels + [(name, round(value, 3))])
                if after not in following or candidate[0] > following[after][0]:
                    following[after] = candidate
        best = following
    return max(best.values(), key=lambda item: item[0])[1]


def layout(channels: np.ndarray, kinds: list[str | None]) -> dict[str, tuple[list[int], list[int]]]:
    """Os canais de cada faixa à esquerda e à direita: dois canais da mesma faixa que andam juntos (a correlação mais
    alta, de `PAIR` para cima) são um par estéreo; os outros vão para os dois lados. Pela correlação e não pela
    vizinhança: com até 8 canais o Vorbis guarda na ordem de som surround e o ffmpeg reordena ao ler."""
    plan: dict[str, tuple[list[int], list[int]]] = {}
    for kind in dict.fromkeys(k for k in kinds if k is not None):
        members = [i for i, k in enumerate(kinds) if k == kind]
        left, right = plan.setdefault(kind, ([], []))
        pairs = []
        for x, a in enumerate(members):
            for b in members[x + 1:]:
                one, two = channels[:, a], channels[:, b]
                if one.std() > 0 and two.std() > 0:
                    pairs.append((float(np.corrcoef(one, two)[0, 1]), a, b))
        used: set[int] = set()
        for score, a, b in sorted(pairs, reverse=True):
            if score >= PAIR and a not in used and b not in used:
                left.append(min(a, b))
                right.append(max(a, b))
                used.update((a, b))
        for index in members:
            if index not in used:
                left.append(index)
                right.append(index)
    return plan


def assemble(source: Path, mogg: Path, stems: dict[str, Path], output: Path, *, progress: Progress | None = None,
             cancel=None, details: dict | None = None) -> dict:
    """Grava `output/<faixa>.flac` (na taxa e no tamanho do áudio do vídeo) a partir do .mogg: alinhado ao vídeo, cada
    canal reconhecido contra as faixas do Demucs (`stems`: nome → arquivo, no tempo do vídeo)."""
    source, mogg, output = Path(source), Path(mogg), Path(output)
    started = time.monotonic()
    output.mkdir(parents=True, exist_ok=True)
    info = soundfile.info(str(source))
    rate, frames = int(info.samplerate), int(info.frames)
    ogg = extract(mogg, output)
    try:
        count = int(probe(ogg).channels or 0)
        if count < 2:
            raise MediaError("Este .mogg tem um canal só: não há faixas para separar.")
        analysis = align.ANALYSIS_RATE
        _emit(progress, "Lendo o áudio do vídeo e o .mogg…", 0.05)
        reference = align.decode(source, analysis, channels=1)[:, 0]
        raw = channels_of(ogg, analysis, count)
        _check(cancel)
        _emit(progress, "Procurando onde o .mogg cai no vídeo…", 0.2)
        found = align.align(reference, raw.sum(axis=1))
        if not found["confident"]:
            raise MediaError(
                f"O .mogg não bate com o áudio do vídeo: só {found['agreed']} de {found['windows']} trechos concordaram "
                "num mesmo deslocamento. Deve ser outra gravação.")
        lag = round(found["offset"] * analysis)
        # Os canais no tempo do vídeo, para comparar com as faixas do Demucs quadro a quadro.
        placed = align.place(channels_of(ogg, analysis, count, speed=found["speed"]), lag, len(reference))
        _check(cancel)
        _emit(progress, "Reconhecendo os canais pelas faixas do Demucs…", 0.4)
        demucs = {name: align.decode(path, analysis, channels=1)[:, 0] for name, path in stems.items()}
        kinds = classify(placed, demucs, analysis)
        plan = layout(placed, [kind for kind, _ in kinds])
        if not plan:
            raise MediaError("Nenhum canal do .mogg se parece com as faixas da música.")
        files = {}
        full_lag = round(found["offset"] * rate)
        for step, (key, (left, right)) in enumerate(sorted(plan.items())):
            _check(cancel)
            _emit(progress, f"Montando as faixas ({step + 1} de {len(plan)})…", 0.55 + 0.4 * step / len(plan))
            data = align.place(mix(ogg, rate, left, right, speed=found["speed"]), full_lag, frames)
            files[key] = _write_stem(output / f"{key}.flac", (data * found["gain"]).T, rate)
    finally:
        ogg.unlink(missing_ok=True)
    receipt = {"model": "multitrack", "version": PROCEDURE, "audioSHA256": sha256_file(source), "sampleRate": rate,
               "frames": frames, "duration": frames / rate, "device": None,
               "alignment": {key: found[key] for key in ("offset", "speed", "agreed", "windows", "strength", "gain")},
               "channels": [{"channel": index, "stem": kind, "score": score} for index, (kind, score) in enumerate(kinds)],
               "seconds": round(time.monotonic() - started, 3), "created": now_iso(), "stems": files,
               **(details or {})}
    atomic_json(output / "receipt.json", receipt)
    _emit(progress, "Faixas do .mogg prontas.", 1.0)
    return receipt


__all__ = ["assemble", "bands", "classify", "extract", "layout", "ogg_start", "similarity"]
