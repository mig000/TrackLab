"""Mapa de batida: a conversão tique ↔ segundo por trechos, que deixa a grade de compassos seguir a gravação.

A régua do M4 é uma reta (um andamento e um início para a música inteira); o mapa é uma poligonal por pontos
(tique, segundo), crescentes nos dois. Entre dois pontos a conversão é linear; antes do primeiro e depois do último
ela segue a inclinação do trecho da ponta. Uma régua é o mapa de dois pontos, então tudo o que lê o mapa continua
valendo para quem só tem régua. As notas nunca mudam por causa do mapa: muda só o tique em que cada uma é escrita.

Contrato (campo `tempoMap` da revisão), tiques da régua (o tique 0 é o começo do primeiro compasso, anacruse
incluída; antes dele os tiques são negativos):

    {"schemaVersion": 1, "source": "audio" | "reference" | "manual", "algorithm": "...",
     "points": [{"tick": 0, "seconds": 0.692, "kind": "anchor" | "detected" | "interpolated",
                 "confidence": 0.8}, ...]}

`kind` diz de onde veio cada ponto: `anchor` foi posto pela pessoa e nenhum recálculo o apaga; `detected` é uma
batida ouvida no áudio; `interpolated` foi preenchido onde o áudio não dava certeza. A fórmula e a anacruse
continuam na régua; com mapa, o andamento e o início da régua passam a ser derivados dele (`derived_ruler`).
"""

from __future__ import annotations

import bisect
import math
import statistics

from .errors import TrackLabError

SCHEMA_VERSION = 1
TICKS_PER_QUARTER = 960
WHOLE = 4 * TICKS_PER_QUARTER
SOURCES = ("audio", "reference", "manual")
KINDS = ("anchor", "detected", "interpolated")
MAX_POINTS = 20000  # meia hora a 600 BPM: mais que isso não é um mapa de batidas
MIN_SECONDS_PER_QUARTER = 60 / 1000  # 1000 BPM
MAX_SECONDS_PER_QUARTER = 60 / 10  # 10 BPM


class RhythmError(TrackLabError):
    """Régua, mapa, grade ou notas que a projeção escrita não aceita."""


class TempoMap:
    """Tique ↔ segundo por trechos lineares; com um ponto só, ou nenhum, não há mapa."""

    def __init__(self, points: list[tuple[float, float]]):
        if len(points) < 2:
            raise RhythmError("Mapa de batida inválido: são precisos ao menos dois pontos.")
        self.ticks = [float(tick) for tick, _ in points]
        self.seconds_list = [float(seconds) for _, seconds in points]
        for index in range(1, len(points)):
            if not (self.ticks[index] > self.ticks[index - 1] and self.seconds_list[index] > self.seconds_list[index - 1]):
                raise RhythmError("Mapa de batida inválido: tiques e segundos precisam crescer juntos.")

    @classmethod
    def from_ruler(cls, ruler: dict) -> TempoMap:
        """A reta da régua como mapa de dois pontos: um compasso inteiro a partir do tique 0."""
        seconds_per_tick = 60.0 / (ruler["bpm"] * TICKS_PER_QUARTER)
        return cls([(0.0, ruler["offset"]), (float(WHOLE), ruler["offset"] + WHOLE * seconds_per_tick)])

    def seconds(self, tick: float) -> float:
        """O segundo do áudio em que cai o tique."""
        return _interpolate(self.ticks, self.seconds_list, tick)

    def tick(self, seconds: float) -> float:
        """O tique (fracionário) em que cai o segundo do áudio."""
        return _interpolate(self.seconds_list, self.ticks, seconds)

    def pairs(self, shift: int = 0) -> list[list[float]]:
        """Os pontos como pares [tique + shift, segundo], para a página interpolar do mesmo jeito."""
        return [[round(tick + shift, 3), round(seconds, 6)] for tick, seconds in zip(self.ticks, self.seconds_list)]


def _interpolate(xs: list[float], ys: list[float], x: float) -> float:
    """Linear por trechos; fora dos pontos, pela inclinação do trecho da ponta."""
    index = bisect.bisect_right(xs, x)
    low = min(max(index - 1, 0), len(xs) - 2)
    x0, x1, y0, y1 = xs[low], xs[low + 1], ys[low], ys[low + 1]
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)


def normalize_tempo_map(raw) -> dict:
    """O mapa do contrato conferido; erros em português dizem o que está fora."""
    if not isinstance(raw, dict):
        raise RhythmError("Mapa de batida inválido: esperava um objeto com points.")
    points = raw.get("points")
    if not isinstance(points, list) or not 2 <= len(points) <= MAX_POINTS:
        raise RhythmError(f"Mapa de batida inválido: points precisa ter de 2 a {MAX_POINTS} pontos.")
    clean = []
    for point in points:
        if not isinstance(point, dict) or not (_number(point.get("tick")) and _number(point.get("seconds"))):
            raise RhythmError("Mapa de batida inválido: cada ponto precisa de tick e seconds numéricos.")
        kind = point.get("kind", "detected")
        if kind not in KINDS:
            raise RhythmError(f"Mapa de batida inválido: kind {kind!r} não é anchor, detected nem interpolated.")
        item = {"tick": point["tick"], "seconds": float(point["seconds"]), "kind": kind}
        if _number(point.get("confidence")):
            item["confidence"] = round(min(1.0, max(0.0, float(point["confidence"]))), 3)
        clean.append(item)
    clean.sort(key=lambda item: item["tick"])
    tempo_map = TempoMap([(item["tick"], item["seconds"]) for item in clean])
    for t0, t1, s0, s1 in zip(tempo_map.ticks, tempo_map.ticks[1:], tempo_map.seconds_list, tempo_map.seconds_list[1:]):
        per_quarter = (s1 - s0) / (t1 - t0) * TICKS_PER_QUARTER
        if not MIN_SECONDS_PER_QUARTER <= per_quarter <= MAX_SECONDS_PER_QUARTER:
            raise RhythmError("Mapa de batida inválido: um trecho tem andamento fora de 10 a 1000 BPM.")
    source = raw.get("source", "manual")
    if source not in SOURCES:
        raise RhythmError(f"Mapa de batida inválido: source {source!r} não é audio, reference nem manual.")
    result = {"schemaVersion": SCHEMA_VERSION, "source": source, "points": clean}
    if isinstance(raw.get("algorithm"), str):
        result["algorithm"] = raw["algorithm"]
    return result


def map_of(tempo_map: dict) -> TempoMap:
    """O conversor de um mapa já conferido por `normalize_tempo_map`."""
    return TempoMap([(point["tick"], point["seconds"]) for point in tempo_map["points"]])


def derived_ruler(tempo_map: dict, ruler: dict) -> dict:
    """A régua que o mapa implica: a fórmula e a anacruse da régua dada, o andamento mediano dos trechos e o
    início no tique 0. É o que lê quem só conhece a régua (a pauta escreve esse andamento no começo)."""
    converter = map_of(tempo_map)
    rates = [(t1 - t0) / (s1 - s0) for t0, t1, s0, s1 in zip(converter.ticks, converter.ticks[1:],
                                                                converter.seconds_list, converter.seconds_list[1:])]
    bpm = statistics.median(rates) * 60.0 / TICKS_PER_QUARTER
    result = dict(ruler)
    result["bpm"] = round(bpm, 2)
    result["offset"] = round(converter.seconds(0.0), 6)
    return result


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


# MARK: - Âncoras da pessoa


def move_anchor(tempo_map: dict, tick: float, seconds: float, reach: float | None = None) -> dict:
    """A batida do tique levada ao segundo dado, como âncora; mexe só até as âncoras vizinhas (a regra do sync-lab).

    Entre a âncora da esquerda e a nova, e entre a nova e a da direita, cada ponto é re-esticado na proporção do
    tempo que ocupava no trecho, então a variação de andamento ouvida dentro do trecho se mantém. Sem âncora de um
    lado, esse lado inteiro anda junto com a batida; com `reach` (tiques), só até o primeiro ponto a essa distância,
    que fica parado como se fosse âncora. As outras âncoras não se mexem, e a batida não passa delas.
    Um tique que não é ponto do mapa vira ponto no segundo em que o mapa o punha. O mapa sai conferido."""
    clean = normalize_tempo_map(tempo_map)
    points = [dict(p) for p in clean["points"]]
    converter = map_of(clean)
    if not any(p["tick"] == tick for p in points):
        points.append({"tick": tick, "seconds": converter.seconds(tick), "kind": "detected"})
        points.sort(key=lambda p: p["tick"])
    index = next(k for k, p in enumerate(points) if p["tick"] == tick)
    old = points[index]["seconds"]
    left = next((k for k in range(index - 1, -1, -1) if points[k]["kind"] == "anchor"), None)
    right = next((k for k in range(index + 1, len(points)) if points[k]["kind"] == "anchor"), None)
    if reach:
        if left is None:
            left = next((k for k in range(index - 1, -1, -1) if tick - points[k]["tick"] >= reach), None)
        if right is None:
            right = next((k for k in range(index + 1, len(points)) if points[k]["tick"] - tick >= reach), None)
    if (left is not None and seconds <= points[left]["seconds"]) or (right is not None and seconds >= points[right]["seconds"]):
        raise RhythmError("A batida precisa ficar entre as âncoras vizinhas.")
    for k, point in enumerate(points):
        if k == index:
            continue
        before = k < index
        edge = left if before else right
        if edge is not None and (k <= edge if before else k >= edge):
            continue  # do outro lado da âncora vizinha: não muda
        if edge is None:
            point["seconds"] += seconds - old
        else:
            span = old - points[edge]["seconds"]
            point["seconds"] = points[edge]["seconds"] + (point["seconds"] - points[edge]["seconds"]) * (seconds - points[edge]["seconds"]) / span
    points[index].update(seconds=float(seconds), kind="anchor", confidence=1.0)
    return normalize_tempo_map(dict(clean, points=points))


def release_anchor(tempo_map: dict, tick: float) -> dict:
    """A âncora do tique solta: o ponto fica onde está, mas volta a ser batida ouvida, que um novo cálculo pode mover."""
    clean = normalize_tempo_map(tempo_map)
    points = [dict(p, kind="detected") if p["tick"] == tick and p["kind"] == "anchor" else p for p in clean["points"]]
    return dict(clean, points=points)


DEFAULT_REACH_BEATS = 8  # o arrasto local da régua: medido nas 80 músicas do Rock Band (beat-eval --fine)
MIN_TAPS = 4  # menos que isso não diz o andamento de um trecho
MIN_TAP_GAP = 0.1  # dois toques mais perto que isso são um tremor do dedo, não duas batidas


def _reach(tempo_map: dict, beats: float) -> float:
    """`beats` batidas do mapa em tiques (o passo mediano entre os pontos)."""
    ticks = [p["tick"] for p in tempo_map["points"]]
    return beats * statistics.median(b - a for a, b in zip(ticks, ticks[1:]))


def tap_beats(tempo_map: dict, taps: list[float], reach: float | None = None) -> dict:
    """Bater junto: os toques (segundos ouvidos, um por batida, em ordem) regravam as batidas de um trecho.

    O primeiro toque fica com a batida do mapa mais perto dele, e cada toque seguinte com a batida seguinte. A
    primeira e a última batidas do trecho viram âncoras, levadas como num arrasto (`move_anchor`, com `reach`
    tiques de alcance do lado sem âncora); as de dentro ficam exatamente nos toques. Âncoras de dentro do trecho dão
    lugar aos toques. Toques além do fim do mapa são ignorados."""
    clean = normalize_tempo_map(tempo_map)
    times = [float(t) for t in taps if _number(t)]
    if len(times) < MIN_TAPS:
        raise RhythmError(f"Bata ao menos {MIN_TAPS} vezes, uma em cada batida, para regravar um trecho.")
    if any(b - a < MIN_TAP_GAP for a, b in zip(times, times[1:])):
        raise RhythmError("Os toques precisam vir em ordem, um por batida.")
    points = clean["points"]
    first = min(range(len(points)), key=lambda k: abs(points[k]["seconds"] - times[0]))
    times = times[:len(points) - first]
    if len(times) < MIN_TAPS:
        raise RhythmError("Os toques passaram do fim do mapa.")
    ticks = [points[first + i]["tick"] for i in range(len(times))]
    for tick in ticks:
        clean = release_anchor(clean, tick)
    clean = move_anchor(clean, ticks[0], times[0], reach=reach)
    clean = move_anchor(clean, ticks[-1], times[-1], reach=reach)
    points = [dict(p) for p in clean["points"]]
    where = {p["tick"]: k for k, p in enumerate(points)}
    for tick, seconds in zip(ticks[1:-1], times[1:-1]):
        points[where[tick]].update(seconds=seconds, kind="detected", confidence=1.0)
    return normalize_tempo_map(dict(clean, points=points))


def map_from(raw: dict) -> dict:
    """O mapa de onde um gesto parte: o `tempoMap` enviado ou, sem ele, a reta da régua (`ruler`)."""
    if isinstance(raw.get("tempoMap"), dict):
        return normalize_tempo_map(raw["tempoMap"])
    if isinstance(raw.get("ruler"), dict) and _number(raw["ruler"].get("bpm")) and _number(raw["ruler"].get("offset")):
        line = TempoMap.from_ruler(raw["ruler"])
        return normalize_tempo_map({"source": "manual", "points": [
            {"tick": tick, "seconds": seconds, "kind": "interpolated"} for tick, seconds in zip(line.ticks, line.seconds_list)]})
    raise RhythmError("Envie o mapa de batida (tempoMap) ou a régua (ruler) de onde o gesto parte.")


def anchor_edit(raw: dict) -> dict:
    """Um gesto da régua sobre o mapa enviado pelo app (que guarda o mapa e o Desfazer): `move` leva a batida do
    `tick` a `seconds` como âncora, puxando o lado sem âncora até `reach` batidas (padrão 8), ou o resto inteiro com
    `pull`; `release` solta a âncora do `tick`; `tap` regrava um trecho pelos toques (`taps`, ver `tap_beats`). Sem
    `tempoMap`, parte da reta da régua (`ruler`)."""
    if not isinstance(raw, dict):
        raise RhythmError("Envie o gesto como um objeto com tempoMap, tick e seconds.")
    tempo_map = map_from(raw)
    if raw.get("action") == "tap":
        if not isinstance(raw.get("taps"), list):
            raise RhythmError("Para bater junto, envie os toques (taps) em segundos.")
        return tap_beats(tempo_map, raw["taps"], reach=_reach(tempo_map, DEFAULT_REACH_BEATS))
    if not _number(raw.get("tick")):
        raise RhythmError("O gesto precisa do tique da batida (tick).")
    tick = raw["tick"]
    if raw.get("action", "move") == "release":
        return release_anchor(tempo_map, tick)
    if raw.get("action", "move") != "move":
        raise RhythmError("O gesto é move, release ou tap.")
    if not _number(raw.get("seconds")):
        raise RhythmError("Para mover a batida, envie o segundo (seconds) em que ela cai.")
    reach = None
    if not raw.get("pull"):
        beats = raw.get("reach", DEFAULT_REACH_BEATS)
        if not _number(beats) or beats <= 0:
            raise RhythmError("O alcance (reach) é um número de batidas maior que zero.")
        reach = _reach(tempo_map, beats)
    return move_anchor(tempo_map, tick, raw["seconds"], reach=reach)


# MARK: - Seguir a referência

FOLLOW_WINDOW = WHOLE  # cada batida se mede pelos ataques casados até um compasso (de 4/4) de cada lado
FOLLOW_MIN_POINTS = 3
FOLLOW_MIN_SPAN = TICKS_PER_QUARTER  # os ataques da janela cobrem ao menos um tempo
FOLLOW_OUTLIER = 0.08  # um ataque que foge mais que isso da reta dos vizinhos não vota


def follow_anchors(tempo_map: dict, pairs: list[tuple[float, float]]) -> tuple[dict, dict]:
    """O mapa levado aos ataques casados com a referência, batida a batida: `pairs` são (tique escrito, segundo
    ouvido). Cada batida com ataques confiáveis por perto vai à reta local deles; entre essas, as outras se
    re-espaçam por igual; antes da primeira e depois da última, andam junto com a ponta. As âncoras da pessoa não se
    mexem e o compasso em volta delas fica com elas. Volta o mapa e um resumo (batidas apoiadas, maior correção)."""
    clean = normalize_tempo_map(tempo_map)
    points = [dict(p) for p in clean["points"]]
    good = _consistent(sorted(pairs))
    anchors = [p["tick"] for p in points if p["kind"] == "anchor"]
    target: dict[int, float] = {}
    for k, point in enumerate(points):
        if point["kind"] == "anchor":
            target[k] = point["seconds"]
            continue
        if any(abs(point["tick"] - a) < FOLLOW_WINDOW for a in anchors):
            continue
        estimate = _local(good, point["tick"])
        if estimate is not None:
            target[k] = estimate
    # Nada que vá contra a ordem: uma estimativa que não cresce com as vizinhas sai.
    changed = True
    while changed:
        changed = False
        kept = sorted(target)
        for a, b in zip(kept, kept[1:]):
            if target[b] - target[a] < (points[b]["tick"] - points[a]["tick"]) / TICKS_PER_QUARTER * MIN_SECONDS_PER_QUARTER:
                drop = b if points[b]["kind"] != "anchor" else a
                if points[drop]["kind"] == "anchor":
                    continue
                del target[drop]
                changed = True
                break
    supported = [k for k in target if points[k]["kind"] != "anchor"]
    if not supported:
        return clean, {"beats": 0, "pairs": len(good), "largest": 0.0}
    kept = sorted(target)
    largest = 0.0
    for k, point in enumerate(points):
        old = point["seconds"]
        if k in target:
            if point["kind"] != "anchor":
                point.update(seconds=target[k], kind="detected", confidence=1.0)
        elif k < kept[0]:
            point["seconds"] = old + (target[kept[0]] - _old(clean, kept[0]))
            point["kind"] = "interpolated"
        elif k > kept[-1]:
            point["seconds"] = old + (target[kept[-1]] - _old(clean, kept[-1]))
            point["kind"] = "interpolated"
        else:
            right = next(j for j in kept if j > k)
            left = max(j for j in kept if j < k)
            t0, t1 = points[left]["tick"], points[right]["tick"]
            o0, o1 = _old(clean, left), _old(clean, right)
            # Entre duas batidas apoiadas, cada uma guarda a fração de tempo que ocupava no trecho.
            share = (old - o0) / (o1 - o0) if o1 > o0 else (point["tick"] - t0) / (t1 - t0)
            point["seconds"] = target[left] + share * (target[right] - target[left])
            point["kind"] = "interpolated"
            point["confidence"] = 0.3
        largest = max(largest, abs(point["seconds"] - old))
    result = normalize_tempo_map(dict(clean, points=points, source="reference", algorithm="seguir-referencia-1"))
    return result, {"beats": len(supported), "pairs": len(good), "largest": round(largest, 4)}


def _old(clean: dict, index: int) -> float:
    return clean["points"][index]["seconds"]


def _line(pairs: list[tuple[float, float]]) -> tuple[float, float] | None:
    """Reta de mínimos quadrados (segundo = a + b·tique); None sem espalhamento."""
    n = len(pairs)
    mt = sum(t for t, _ in pairs) / n
    ms = sum(s for _, s in pairs) / n
    var = sum((t - mt) ** 2 for t, _ in pairs)
    if var <= 0:
        return None
    slope = sum((t - mt) * (s - ms) for t, s in pairs) / var
    if not slope > 0:
        return None
    return ms - slope * mt, slope


def _consistent(pairs: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Os ataques que concordam com a reta dos vizinhos (sem eles mesmos): um casamento errado não puxa a grade."""
    kept = []
    ticks = [tick for tick, _ in pairs]
    for i, (tick, seconds) in enumerate(pairs):
        lo, hi = bisect.bisect_left(ticks, tick - FOLLOW_WINDOW), bisect.bisect_right(ticks, tick + FOLLOW_WINDOW)
        near = pairs[lo:i] + pairs[i + 1:hi]
        if len(near) < FOLLOW_MIN_POINTS - 1:
            continue
        line = _line(near)
        if line is not None and abs(line[0] + line[1] * tick - seconds) <= FOLLOW_OUTLIER:
            kept.append((tick, seconds))
    return kept


def _local(pairs: list[tuple[float, float]], tick: float) -> float | None:
    """O segundo do tique pela reta dos ataques confiáveis em volta; None sem apoio dos dois lados."""
    lo = bisect.bisect_left(pairs, (tick - FOLLOW_WINDOW, -math.inf))
    hi = bisect.bisect_right(pairs, (tick + FOLLOW_WINDOW, math.inf))
    near = pairs[lo:hi]
    if len(near) < FOLLOW_MIN_POINTS or near[-1][0] - near[0][0] < FOLLOW_MIN_SPAN:
        return None
    if not (near[0][0] <= tick + TICKS_PER_QUARTER and near[-1][0] >= tick - TICKS_PER_QUARTER):
        return None
    line = _line(near)
    return None if line is None else line[0] + line[1] * tick


PULSE_SNAP = 0.06  # a batida ouvida a até 60 ms da reta das notas ganha dela: é mais precisa na fase


def snap_to_pulse(tempo_map: dict, heard: list[float], radius: float = PULSE_SNAP) -> tuple[dict, int]:
    """Cada batida do mapa (menos as âncoras) vai à batida ouvida mais perto, se houver uma a até `radius`: as notas
    dão a deriva, o pulso dá a fase (o guitarrista toca na frente ou atrás do tempo; a banda, não). Uma batida que
    deixaria de crescer com as vizinhas fica onde está. Volta o mapa e quantas batidas encaixaram."""
    clean = normalize_tempo_map(tempo_map)
    if not heard:
        return clean, 0
    times = sorted(float(t) for t in heard)
    points = [dict(p) for p in clean["points"]]
    snapped = 0
    for k, point in enumerate(points):
        if point["kind"] == "anchor":
            continue
        index = bisect.bisect_left(times, point["seconds"])
        near = sorted((abs(t - point["seconds"]), t) for t in times[max(0, index - 1):index + 1])
        if not near or near[0][0] > radius:
            continue
        candidate = near[0][1]
        before = points[k - 1]["seconds"] if k > 0 else -math.inf
        after = points[k + 1]["seconds"] if k + 1 < len(points) else math.inf
        if not before < candidate < after:
            continue
        if abs(candidate - point["seconds"]) > 1e-6:
            point["seconds"] = candidate
            snapped += 1
        point["kind"] = "detected"
        point["confidence"] = 1.0
    return normalize_tempo_map(dict(clean, points=points)), snapped


# MARK: - Mapa inicial a partir do Songsterr


def beat_ticks(numerator: int, denominator: int) -> int:
    """A batida como o metrônomo do TabLab conta: a figura do denominador, ou a semínima pontuada no composto."""
    if denominator == 8 and numerator > 3 and numerator % 3 == 0:
        return TICKS_PER_QUARTER * 3 // 2
    return WHOLE // max(1, denominator)


def bar_ticks(numerator: int, denominator: int) -> int:
    return numerator * WHOLE // max(1, denominator)


def from_bar_starts(starts: list[float], signatures: list[tuple[int, int]], *,
                    algorithm: str = "songsterr-video-points") -> dict:
    """O mapa de batidas a partir do início de cada compasso no áudio (os pontos de sincronização do Songsterr).

    `starts[i]` é o segundo em que o compasso i começa, na ordem escrita; `signatures[i]` a fórmula dele. O início de
    cada compasso vira um ponto `detected`; as batidas de dentro são `interpolated`, em passos iguais. Com um ponto a
    mais que compassos, ele fecha o último; sem ele, o último compasso segue o andamento do anterior (e o ponto que o
    fecha também é `interpolated`). Pontos além disso são ignorados.
    """
    count = len(signatures)
    if count < 1 or len(starts) < count:
        raise RhythmError("Mapa de batida inválido: faltam pontos para os compassos da partitura.")
    starts = [float(value) for value in starts[:count + 1]]
    if not all(_number(value) and value >= 0 for value in starts) or any(b <= a for a, b in zip(starts, starts[1:])):
        raise RhythmError("Mapa de batida inválido: os pontos do Songsterr estão fora de ordem.")
    ticks = [0]
    for numerator, denominator in signatures:
        ticks.append(ticks[-1] + bar_ticks(numerator, denominator))
    closed = len(starts) > count
    if not closed:
        if count < 2:
            raise RhythmError("Mapa de batida inválido: um compasso só não diz o andamento.")
        rate = (starts[-1] - starts[-2]) / (ticks[-2] - ticks[-3])
        starts.append(starts[-1] + rate * (ticks[-1] - ticks[-2]))
    points = []
    for index, (numerator, denominator) in enumerate(signatures):
        t0, t1, s0, s1 = ticks[index], ticks[index + 1], starts[index], starts[index + 1]
        step = beat_ticks(numerator, denominator)
        points.append({"tick": t0, "seconds": round(s0, 6), "kind": "detected"})
        for tick in range(t0 + step, t1, step):
            points.append({"tick": tick, "seconds": round(s0 + (s1 - s0) * (tick - t0) / (t1 - t0), 6),
                           "kind": "interpolated"})
    points.append({"tick": ticks[-1], "seconds": round(starts[-1], 6), "kind": "detected" if closed else "interpolated"})
    return normalize_tempo_map({"source": "reference", "algorithm": algorithm, "points": points})
