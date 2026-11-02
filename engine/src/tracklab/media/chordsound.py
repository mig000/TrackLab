"""Os acordes pelo som: o Chord-CNN-LSTM (Jiang, Chen e Xia, "Large-Vocabulary Chord Transcription via Chord
Structure Decomposition", ISMIR 2019; Music X Lab, MIT; o modelo e o decodificador em `chordnet/`).

O áudio vira um CQT (mono a 22 050 Hz, um quadro a cada 512 amostras, 288 linhas de 1/3 de semitom do Fá♯ 0, o
`hybrid_cqt` do librosa, como no original), e cinco redes treinadas em partes diferentes dos dados dão, a cada quadro, as
probabilidades da tríade, do baixo e das extensões (a média das cinco, como no original). Isso é o caro (~30 s para 5
minutos na CPU do iMac) e é guardado no pacote. O nome dos acordes sai depois, de um HMM sobre essas probabilidades: com
as batidas do mapa de tempo, um acorde só troca numa batida, e trocar custa menos no 1 do compasso e no meio dele (10,
20 e 40; os do original, 15, 45 e 100, engoliam os acordes curtos dos riffs: no Sunshine of Your Love, 24 dos 49 escritos
contra 30, no Highway Star 100 dos 165 contra 108); sem batidas, a qualquer quadro (30). Medido em 1/11 sobre a música
inteira, com as batidas: 87 dos 93 acordes escritos no Guitar Pro do Ramblin' Man e 18 dos 20 do Sultans of Swing.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from . import align

RATE = 22_050
HOP = 512
# No nome do arquivo guardado: outra receita refaz as probabilidades. A v1 guardava em float16, que zerava as
# probabilidades abaixo de ~3e-8: o HMM tira o log sem piso e parte de "sem acorde", e um zero ali deixava a música
# inteira sem acorde na segunda leitura.
VERSION = 2
# O menor valor que entra no log do HMM: um zero (da rede ou de um arquivo antigo) não mata todos os caminhos.
FLOOR = 1e-12
CHORD_LIST = Path(__file__).with_name("chordnet") / "submission_chord_list.txt"
# As larguras das seis saídas da rede, na ordem: tríade, baixo, sétima, nona, décima primeira, décima terceira.
WIDTHS = (73, 13, 4, 4, 3, 3)
# O custo de trocar: num quadro qualquer (sem batidas) e, com batidas, no 1 do compasso, no meio dele e num tempo.
FREE_PENALTY = 30.0
BEAT_PENALTIES = (10.0, 20.0, 40.0)


def probabilities(path: Path, weights: list[Path]) -> np.ndarray:
    """As probabilidades de cada quadro (quadros × 100: as seis saídas lado a lado), a média das redes de `weights`."""
    import librosa
    import torch

    from .chordnet.network import ChordNet

    signal = align.decode(path, RATE, channels=1)[:, 0].astype(np.float32)
    cqt = np.abs(librosa.hybrid_cqt(signal, sr=RATE, bins_per_octave=36, fmin=librosa.note_to_hz("F#0"), n_bins=288,
                                    tuning=None, hop_length=HOP).T).astype(np.float32)
    total = None
    for file in weights:
        net = ChordNet()
        state = torch.load(file, map_location="cpu")
        net.load_state_dict(state["net"])
        net.eval()
        with torch.no_grad():
            parts = net.inference(torch.from_numpy(cqt))
        joined = np.concatenate(parts, axis=1)
        total = joined if total is None else total + joined
    return (total / len(weights)).astype(np.float32)


def split(probs: np.ndarray) -> list[np.ndarray]:
    edges = np.cumsum((0,) + WIDTHS)
    return [probs[:, edges[i]:edges[i + 1]] for i in range(len(WIDTHS))]


def beat_frames(count: int, beats: list[tuple[float, int]]) -> np.ndarray:
    """O tipo de cada quadro para o HMM (o `__get_beat_arr` do original): 1 onde o acorde troca livre (antes da primeira
    batida e depois da última), 0 entre batidas, e na batida 2 (o 1 do compasso), 3 (o meio dele) ou 4 (outro tempo)."""
    arr = np.ones(count, dtype=np.int8)
    # Uma batida no quadro 0 não conta: o HMM do original parte de "sem acorde" ali, e ficaria nele até a seguinte.
    marks = sorted((int(round(seconds * RATE / HOP)), kind) for seconds, kind in beats
                   if 0 < int(round(seconds * RATE / HOP)) < count and kind in (2, 3, 4))
    for (a, _), (b, _) in zip(marks, marks[1:]):
        arr[a + 1:b] = 0
    # Duas marcas no mesmo quadro: vale a mais forte (o 1 do compasso).
    for frame, kind in sorted(marks, key=lambda mark: -mark[1]):
        arr[frame] = kind
    return arr


def decode(probs: np.ndarray, beats: list[tuple[float, int]] | None = None) -> list[list]:
    """Os acordes, `[[início, fim, nome], …]` em segundos, com o nome como o original escreve ("A:min7", "C:maj/5",
    "N" sem acorde), presos às batidas quando elas vêm."""
    from .chordnet.xhmm import XHMMDecoder

    hmm = XHMMDecoder(diff_trans_penalty=FREE_PENALTY, beat_trans_penalty=BEAT_PENALTIES, template_file=str(CHORD_LIST))
    probs = np.maximum(np.asarray(probs, dtype=np.float32), FLOOR)
    count = probs.shape[0]
    arr = beat_frames(count, beats or [])
    names = hmm.decode(split(probs), arr)
    step = HOP / RATE
    result = []
    first = 0
    for index in range(count):
        if index + 1 == count or names[index + 1] != names[index]:
            result.append([round(first * step, 4), round((index + 1) * step, 4), names[index]])
            first = index + 1
    return result
