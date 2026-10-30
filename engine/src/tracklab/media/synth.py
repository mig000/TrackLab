"""A TAB sintetizada: cada pista do Guitar Pro tocada por um SoundFont, no tempo da gravação, para misturar com o áudio.

O MIDI sai do alphaTab do projeto (as articulações que ele sabe tocar, uma trilha por pista), o andamento do Guitar Pro
é trocado pelo do mapa de tempo (um evento de andamento por ponto do mapa: cada batida cai onde ela soa na gravação) e
cada pista é sintetizada separada, na taxa do áudio do vídeo. Com o FluidSynth instalado, por ele (com o reverb e o
chorus dele: `web/tools/gp-midi.cjs` + `retimed` + `render`); sem ele, pelo sintetizador do próprio alphaTab
(TinySoundFont, `web/tools/gp-synth.cjs`), que não tem efeitos: aqui ganha um reverb de convolução leve. No iMac Intel
o Homebrew não instala mais o FluidSynth (28/10: sem pacotes para Intel, e a compilação baixa uma dependência do GitHub
dentro da caixa de areia), então vale o alphaTab: as sete pistas de White Room em ~6 s.
Cada pista é gravada no tamanho do áudio do vídeo, começando onde o tique 0 cai nele: as faixas tocam no mesmo
relógio das outras e o mixer as soma com o original ou com as faixas separadas. O volume de todas junto é levado ao
do áudio do vídeo (um ganho só, para o equilíbrio entre elas ficar o do Guitar Pro).

O SoundFont (.sf2 ou .sf3) é o de `TRACKLAB_SOUNDFONT`, ou `~/TrackLab/config.json` → `soundfont`, ou o primeiro de
`~/TrackLab/Sons/`. Mudar o mapa de tempo (o Ajuste) deixa a síntese desatualizada: o app pede de novo.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile

from .. import home
from ..errors import MediaError
from ..tempomap import TICKS_PER_QUARTER
from ..util import atomic_json, now_iso
from . import align
from .separate import _write_stem

Progress = Callable[[str, str, float | None], None]

STAGE = "synth"
PROCEDURE = "synth.v1"
GAIN = 0.4                 # ganho do FluidSynth por pista: folga para os acordes e a bateria não estourarem
LOUDNESS = 0.8             # todas as pistas juntas a 80 % do volume (RMS) do áudio do vídeo
PEAK = 0.95
SOUNDFONT_SUFFIXES = (".sf2", ".sf3")
REPO = Path(__file__).resolve().parents[4]
MIDI_SCRIPT = REPO / "web" / "tools" / "gp-midi.cjs"
SYNTH_SCRIPT = REPO / "web" / "tools" / "gp-synth.cjs"
REVERB_SECONDS = 1.6
REVERB_WET = 0.18
FLUIDSYNTH_FOLDERS = ("/usr/local/bin", "/opt/homebrew/bin")


def sounds() -> Path:
    folder = home.home() / "Sons"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def soundfont() -> Path:
    """O SoundFont da síntese: a variável de ambiente, o config.json do TrackLab ou o primeiro de ~/TrackLab/Sons."""
    chosen = os.environ.get("TRACKLAB_SOUNDFONT")
    config = home.home() / "config.json"
    if not chosen and config.is_file():
        try:
            chosen = json.loads(config.read_text(encoding="utf-8")).get("soundfont")
        except (OSError, ValueError):
            chosen = None
    if chosen:
        path = Path(chosen).expanduser()
        if not path.is_file():
            raise MediaError(f"O SoundFont escolhido não está em {path}.")
        return path
    found = sorted(p for p in sounds().iterdir() if p.suffix.lower() in SOUNDFONT_SUFFIXES and not p.name.startswith("."))
    if not found:
        raise MediaError(f"Ponha um SoundFont (.sf2 ou .sf3) em {sounds()} para sintetizar a TAB.")
    return found[0]


def _tool(name: str, folders=FLUIDSYNTH_FOLDERS) -> str:
    found = shutil.which(name) or shutil.which(name, path=":".join(folders))
    if found is None:
        hint = "brew install fluid-synth" if name == "fluidsynth" else "brew install node"
        raise MediaError(f"A síntese da TAB precisa do {name} ({hint}).")
    return found


def gp_to_midi(gp: Path, target: Path) -> dict:
    """O MIDI do Guitar Pro (uma trilha por pista) e as pistas que ele tem."""
    try:
        done = subprocess.run([_tool("node"), str(MIDI_SCRIPT), str(gp), str(target)], capture_output=True, check=False,
                              timeout=300)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MediaError(f"Não consegui gerar o MIDI da partitura: {error}") from None
    if done.returncode != 0:
        tail = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [f"código {done.returncode}"]
        raise MediaError(f"Não consegui gerar o MIDI da partitura: {tail[0][:200]}")
    return json.loads(done.stdout.decode("utf-8"))


def retimed(source: Path, points: list[dict], track: int):
    """Um MIDI só com a pista `track`, no andamento do mapa de tempo: um evento de andamento em cada ponto (o trecho
    até o ponto seguinte), e o primeiro trecho também antes do primeiro ponto. Devolve o MIDI e o segundo da gravação em
    que cai o tique 0 (o começo do MIDI)."""
    import mido

    original = mido.MidiFile(str(source))
    division = original.ticks_per_beat
    scale = division / TICKS_PER_QUARTER
    pairs = sorted((float(p["tick"]), float(p["seconds"])) for p in points)
    if len(pairs) < 2:
        raise MediaError("O mapa de tempo precisa de dois pontos para sintetizar a TAB.")
    changes = []
    for (t0, s0), (t1, s1) in zip(pairs, pairs[1:]):
        if t1 > t0 and s1 > s0:
            per_quarter = (s1 - s0) / (t1 - t0) * TICKS_PER_QUARTER
            changes.append((max(0, round(t0 * scale)), max(1, round(per_quarter * 1_000_000))))
    if not changes:
        raise MediaError("O mapa de tempo não cresce: não dá para sintetizar a TAB.")
    offset = tick_zero(points)
    conductor = mido.MidiTrack()
    now = 0
    changes[0] = (0, changes[0][1])
    for tick, tempo in changes:
        conductor.append(mido.MetaMessage("set_tempo", tempo=tempo, time=tick - now))
        now = tick
    music = mido.MidiTrack()
    carried = 0
    for message in original.tracks[track]:
        if message.is_meta and message.type in ("set_tempo", "time_signature", "key_signature"):
            carried += message.time   # o tempo do evento que sai passa para o seguinte
            continue
        music.append(message.copy(time=message.time + carried))
        carried = 0
    result = mido.MidiFile(type=1, ticks_per_beat=division)
    result.tracks.extend([conductor, music])
    return result, offset


def render(midi: Path, font: Path, target: Path, rate: int) -> None:
    command = [_tool("fluidsynth"), "-ni", "-q", "-g", str(GAIN), "-r", str(rate), "-O", "float", "-T", "wav",
               "-o", "synth.polyphony=1024", "-o", "synth.reverb.active=1", "-o", "synth.chorus.active=1",
               "-F", str(target), str(font), str(midi)]
    try:
        done = subprocess.run(command, capture_output=True, check=False, timeout=1800)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MediaError(f"O FluidSynth falhou: {error}") from None
    if done.returncode != 0 or not target.is_file():
        tail = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [f"código {done.returncode}"]
        raise MediaError(f"O FluidSynth falhou: {tail[0][:200]}")


def synthesize(gp: Path, points: list[dict], source: Path, output: Path, *, progress: Progress | None = None,
               cancel=None, font: Path | None = None, engine: str | None = None) -> dict:
    """Grava `output/t<pista>.flac` para cada pista com notas, no tamanho e na taxa de `source` (o áudio do vídeo).
    `engine`: "fluidsynth" ou "alphatab"; sem ele, o FluidSynth se estiver instalado."""
    started = time.monotonic()
    font = Path(font or soundfont())
    info = soundfile.info(str(source))
    rate, frames = int(info.samplerate), int(info.frames)
    engine = engine or ("fluidsynth" if _has("fluidsynth") else "alphatab")
    offset = tick_zero(points)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tracklab-synth-") as scratch:
        scratch = Path(scratch)
        render_tracks = _with_fluidsynth if engine == "fluidsynth" else _with_alphatab
        tracks, raw = render_tracks(gp, points, font, rate, scratch, progress, cancel)
    if not raw:
        raise MediaError("A partitura não tem notas para sintetizar.")
    rendered = {index: align.place(data, round(offset * rate), frames) for index, data in raw.items()}
    _check(cancel)
    gain = _gain(rendered, source)
    files = {}
    for index, data in rendered.items():
        track = next(t for t in tracks if t["index"] == index)
        stem = _write_stem(output / f"t{index}.flac", (data * gain).T, rate)
        files[str(index)] = {**stem, "name": track["name"], "program": track["program"],
                             "percussion": track["percussion"]}
    receipt = {"version": PROCEDURE, "engine": engine, "soundfont": font.name, "sampleRate": rate, "frames": frames,
               "gain": round(gain, 4), "seconds": round(time.monotonic() - started, 3), "created": now_iso(),
               "tracks": files}
    atomic_json(output / "receipt.json", receipt)
    _emit(progress, "TAB sintetizada.", 1.0)
    return receipt


def tick_zero(points: list[dict]) -> float:
    """O segundo da gravação em que cai o tique 0 (pela reta do primeiro trecho do mapa)."""
    pairs = sorted((float(p["tick"]), float(p["seconds"])) for p in points)
    if len(pairs) < 2 or pairs[1][0] <= pairs[0][0]:
        raise MediaError("O mapa de tempo precisa de dois pontos para sintetizar a TAB.")
    (t0, s0), (t1, s1) = pairs[0], pairs[1]
    return s0 - t0 * (s1 - s0) / (t1 - t0)


def _with_fluidsynth(gp, points, font, rate, scratch, progress, cancel):
    _emit(progress, "Gerando o MIDI da partitura…", 0.02)
    whole = scratch / "score.mid"
    tracks = gp_to_midi(gp, whole)["tracks"]
    raw = {}
    for number, track in enumerate(tracks):
        _check(cancel)
        _emit(progress, f"Sintetizando {track['name']} ({number + 1} de {len(tracks)})…",
              0.05 + 0.85 * number / len(tracks))
        midi, _ = retimed(whole, points, track["index"])
        if not any(m.type == "note_on" and m.velocity > 0 for m in midi.tracks[1]):
            continue   # pista sem notas
        midi_path = scratch / f"t{track['index']}.mid"
        midi.save(str(midi_path))
        wav = scratch / f"t{track['index']}.wav"
        render(midi_path, font, wav, rate)
        data, got = soundfile.read(str(wav), dtype="float32", always_2d=True)
        if got != rate:
            data = align.decode(wav, rate, channels=2)
        raw[track["index"]] = np.repeat(data, 2, axis=1) if data.shape[1] == 1 else data[:, :2]
    return tracks, raw


def _with_alphatab(gp, points, font, rate, scratch, progress, cancel):
    _emit(progress, "Sintetizando as pistas (alphaTab)…", 0.05)
    points_file = scratch / "points.json"
    points_file.write_text(json.dumps([{"tick": p["tick"], "seconds": p["seconds"]} for p in points]))
    try:
        done = subprocess.run([_tool("node"), str(SYNTH_SCRIPT), str(gp), str(font), str(points_file), str(scratch),
                               str(rate)], capture_output=True, check=False, timeout=1800)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MediaError(f"A síntese da TAB falhou: {error}") from None
    if done.returncode != 0:
        tail = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [f"código {done.returncode}"]
        raise MediaError(f"A síntese da TAB falhou: {tail[0][:200]}")
    tracks = json.loads(done.stdout.decode("utf-8"))["tracks"]
    raw = {}
    for number, track in enumerate(tracks):
        _check(cancel)
        _emit(progress, f"Ambiência de {track['name']} ({number + 1} de {len(tracks)})…",
              0.3 + 0.6 * number / len(tracks))
        data = np.fromfile(scratch / track["file"], dtype="<f4").reshape(-1, 2)
        raw[track["index"]] = reverb(data, rate)
    return tracks, raw


def reverb(data: np.ndarray, rate: int, seconds: float = REVERB_SECONDS, wet: float = REVERB_WET) -> np.ndarray:
    """Um reverb de sala leve por convolução (ruído que decai, um pouco diferente em cada canal), para o som seco do
    TinySoundFont não soar colado ao ouvido. Determinístico: a mesma pista dá sempre o mesmo áudio."""
    length = int(seconds * rate)
    rng = np.random.default_rng(7)
    decay = np.exp(-6.9 * np.arange(length) / length)          # −60 dB no fim
    impulse = rng.standard_normal((length, 2)) * decay[:, None]
    impulse[: int(0.012 * rate)] = 0                          # pré-atraso de 12 ms
    kernel = np.ones(8) / 8                                   # tira o chiado do agudo
    impulse = np.stack([np.convolve(impulse[:, c], kernel, "same") for c in range(2)], axis=1)
    norm = np.sqrt(np.sum(impulse ** 2, axis=0, keepdims=True))
    impulse /= np.where(norm > 0, norm, 1)
    size = 1 << int(np.ceil(np.log2(len(data) + length)))
    out = np.empty_like(data)
    for c in range(2):
        tail = np.fft.irfft(np.fft.rfft(data[:, c], size) * np.fft.rfft(impulse[:, c], size), size)[: len(data)]
        out[:, c] = data[:, c] + wet * tail.astype(np.float32)
    return out


def _has(name: str) -> bool:
    return bool(shutil.which(name) or shutil.which(name, path=":".join(FLUIDSYNTH_FOLDERS)))


def _gain(rendered: dict[int, np.ndarray], source: Path) -> float:
    """Um ganho para todas as pistas: juntas, a LOUDNESS do volume do áudio do vídeo, sem nenhuma passar de PEAK."""
    total = sum(rendered.values())
    mix, _ = soundfile.read(str(source), dtype="float32", always_2d=True)
    loud = float(np.sqrt(np.mean(total ** 2))) or 1e-9
    gain = LOUDNESS * float(np.sqrt(np.mean(mix ** 2))) / loud
    peak = max(float(np.max(np.abs(data))) for data in rendered.values()) or 1e-9
    return min(gain, PEAK / peak)


def _check(cancel) -> None:
    if cancel is not None:
        cancel.check()


def _emit(progress: Progress | None, message: str, fraction: float | None) -> None:
    if progress is not None:
        progress(STAGE, message, fraction)


__all__ = ["PROCEDURE", "gp_to_midi", "render", "retimed", "reverb", "soundfont", "synthesize", "tick_zero"]
