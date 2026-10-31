"""O conjunto de medição dos bends a partir do GOAT (o áudio DI de cada item e o Guitar Pro dele).

Tempo de cada nota no áudio DI:
  1. notas.cjs dá as notas do GP (core.trackNotes, como o app) em cada vez que tocam, no tempo do GP (andamentos
     do arquivo, repetições abertas).
  2. item_N.mid (o MIDI que o Guitar Pro exportou, no mesmo tempo do GP, com o swing/"triplet feel" aplicado): cada
     nota do GP casa com a de mesma altura mais perto (até 0,2 s).
  3. item_N_fine_aligned.mid (as mesmas notas, alinhadas ao DI pelo procedimento do GAPS): casa com o MIDI do GP pela
     mesma altura (até 0,5 s); fica só o par cujo deslocamento está a até 80 ms da mediana dos vizinhos (±2 s): o
     alinhamento fino às vezes "fecha" uma nota no ataque seguinte (duração de ~0,09 s, +340 ms).
  4. Âncoras (início no GP → início no DI), mediana por instante, só as crescentes (maior subsequência); o começo e o
     fim de cada nota por interpolação linear entre elas (inclinação 1 fora delas).
  Sem o fino (20 itens), as âncoras são as do MIDI do GP e um deslocamento único é buscado no áudio (o meio do
  patamar da validação abaixo).
  5. (variante "centered", a padrão) Um deslocamento constante por item para a mediana de (ataque medido pelo motor,
     pitch.attack − começo) das notas isoladas (nenhum outro começo a ±150 ms) e sem ligado/slide de chegada ficar em
     zero: no fino como veio, o som começa ~10–35 ms antes da nota (conferido também pela altura, não só pela energia).
     A variante "asis" deixa o fino como veio (e centra só os itens sem o fino).
Validação (a do sync2.py): das notas sem acorde e sem bend, a fração com a mediana da metade do meio da curva a menos
de 0,5 semitom da altura escrita.

uso: engine/.venv/bin/python -I bench/goat/curvas.py <repo> <gp.json> <metadata.csv> <pasta data> <saída.json> [--workers N]
     [--variant centered|asis] [--min-score 0.7] [itens...]
"""
import argparse, bisect, collections, csv, json, math, os, statistics, sys, time
from multiprocessing import Pool
from pathlib import Path

import mido

ARGS = None
pitch = None


def setup(repo):
    global pitch
    sys.path.insert(0, os.path.join(repo, "engine/src"))
    from tracklab.media import pitch as p
    pitch = p


def midi_notes(path):
    m = mido.MidiFile(path)
    on, out, t = {}, [], 0.0
    for msg in m:
        t += msg.time
        if msg.type == "note_on" and msg.velocity > 0:
            on.setdefault((msg.channel, msg.note), []).append(t)
        elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            k = (msg.channel, msg.note)
            if on.get(k):
                out.append((on[k].pop(0), t, msg.note))
    out.sort()
    return out


def match(a, b, window):
    """Pares (i, j) de notas (início, fim, altura) de mesma altura, os mais perto primeiro, até `window` s."""
    by_pitch = collections.defaultdict(list)
    for j, n in enumerate(b):
        by_pitch[n[2]].append((n[0], j))
    for v in by_pitch.values():
        v.sort()
    cands = []
    for i, n in enumerate(a):
        lst = by_pitch.get(n[2], [])
        k = bisect.bisect_left(lst, (n[0] - window, -1))
        while k < len(lst) and lst[k][0] <= n[0] + window:
            cands.append((abs(lst[k][0] - n[0]), i, lst[k][1]))
            k += 1
    cands.sort()
    ua, ub, pairs = set(), set(), {}
    for d, i, j in cands:
        if i in ua or j in ub:
            continue
        ua.add(i); ub.add(j); pairs[i] = j
    return pairs


def increasing(points):
    """A maior subsequência de pontos (x, y) com x e y crescentes (x já crescente)."""
    tails, prev, idx = [], [-1] * len(points), []
    for i, (_, y) in enumerate(points):
        k = bisect.bisect_left(tails, y)
        if k == len(tails):
            tails.append(y); idx.append(i)
        else:
            tails[k] = y; idx[k] = i
        prev[i] = idx[k - 1] if k else -1
    out, i = [], idx[-1] if idx else -1
    while i >= 0:
        out.append(points[i]); i = prev[i]
    return out[::-1]


class Map:
    def __init__(self, anchors, shift=0.0):
        self.x = [a for a, _ in anchors]
        self.y = [b + shift for _, b in anchors]

    def __call__(self, t):
        x, y = self.x, self.y
        if t <= x[0]:
            return y[0] + (t - x[0])
        if t >= x[-1]:
            return y[-1] + (t - x[-1])
        k = bisect.bisect_right(x, t)
        return y[k - 1] + (y[k] - y[k - 1]) * (t - x[k - 1]) / (x[k] - x[k - 1])


def anchors_from(pairs_xy):
    by = collections.defaultdict(list)
    for x, y in pairs_xy:
        by[round(x, 4)].append(y)
    pts = sorted((x, statistics.median(v)) for x, v in by.items())
    return increasing(pts)


def plain_score(x, plays, mapping, limit=None):
    """A validação do sync2: a fração das notas sem acorde e sem bend na altura escrita (mediana da metade do meio)."""
    good = total = 0
    devs = []
    for gp_s, gp_e, n in plays:
        if n["others"] or n["bend"]:
            continue
        a, b = mapping(gp_s), mapping(gp_e)
        if a < 0 or b - a < 0.06 or b - a > 8:
            continue
        c = pitch.note_curve(x, a, b, float(n["pitch"]))
        L = b - a
        vals = [v for i, v in enumerate(c["values"]) if v is not None and a + 0.25 * L <= c["from"] + i * c["hop"] <= b - 0.25 * L]
        if len(vals) < 3:
            continue
        total += 1
        d = statistics.median(vals) - n["pitch"]
        devs.append(d)
        good += abs(d) < 0.5
        if limit and total >= limit:
            break
    return good / max(1, total), total, devs


def work(item):
    t0 = time.time()
    g = GP[item]
    meta = META[item]
    report = {"item": item, "tuning_class": meta["tuning_class"], "player": meta["player"], "guitar": meta["guitar_brand"],
              "f_measure": meta["alignment_f_measure_fine"], "title": g.get("title"), "artist": g.get("artist")}
    if "error" in g:
        report["error"] = g["error"]
        return report, None
    tracks = [t for t in g["tracks"] if not t["percussion"] and t["tuning"]]
    plays = []  # (gp_s, gp_e, note, track index)
    for t in tracks:
        for n in t["notes"]:
            for k, (s, e) in enumerate(n["plays"]):
                plays.append((s, e, n, t["index"], k))
    plays.sort(key=lambda p: (p[0], p[2]["pitch"]))
    folder = os.path.join(ARGS.data, item)
    q = midi_notes(os.path.join(folder, item + ".mid"))
    pq = match([(p[0], p[1], p[2]["pitch"]) for p in plays], q, 0.2)
    report.update(gp_notes=len(plays), mid_notes=len(q), gp_mid_matched=len(pq),
                  swing_shift_ms=round(max((abs(q[j][0] - plays[i][0]) for i, j in pq.items()), default=0) * 1000))
    fine_path = os.path.join(folder, item + "_fine_aligned.mid")
    x = pitch.samples(Path(folder) / (item + ".wav"))
    duration = len(x) / pitch.RATE
    report["audio_s"] = round(duration, 2)
    quant = Map(anchors_from([(plays[i][0], q[j][0]) for i, j in pq.items()]))
    plain = [(p[0], p[1], p[2]) for p in plays]
    if os.path.exists(fine_path):
        f = midi_notes(fine_path)
        pf = match(q, f, 0.5)
        offs = sorted((q[i][0], f[j][0] - q[i][0], i) for i, j in pf.items())
        keep = {}
        times = [o[0] for o in offs]
        for t, d, i in offs:
            lo, hi = bisect.bisect_left(times, t - 2), bisect.bisect_right(times, t + 2)
            med = statistics.median(o[1] for o in offs[lo:hi])
            if abs(d - med) <= 0.08:
                keep[i] = t + d
        pairs = [(plays[i][0], keep[j]) for i, j in pq.items() if j in keep]
        fine = Map(anchors_from(pairs))
        report.update(fine_notes=len(f), mid_fine_matched=len(pf), fine_kept=len(keep), anchors=len(fine.x),
                      fine_offset_ms=round(statistics.median(o[1] for o in offs) * 1000, 1) if offs else None)
        sf, nf, devf = plain_score(x, plain, fine)
        # O MIDI do GP com o deslocamento mediano do fino (para comparar o que o fino ganha).
        shift = statistics.median(o[1] for o in offs) if offs else 0.0
        sq, nq, _ = plain_score(x, plain, Map(list(zip(quant.x, quant.y)), shift))
        report.update(score_fine=round(sf, 3), score_quant=round(sq, 3), score_n=nf, timing="fine")
        mapping, score, devs = fine, sf, devf
    else:
        # Sem o fino: o MIDI do GP com um deslocamento único, buscado no áudio: o meio do patamar da validação (de −0,6
        # a +0,6 s, de 30 em 30 ms); o ataque (abaixo) acerta o resto.
        tried = []
        for k in range(-20, 21):
            s, _, _ = plain_score(x, plain, Map(list(zip(quant.x, quant.y)), 0.03 * k), limit=120)
            tried.append((s, 0.03 * k))
        top = max(s for s, _ in tried)
        plateau = [d for s, d in tried if s >= top - 0.01]
        shift = statistics.median(plateau)
        mapping = Map(list(zip(quant.x, quant.y)), shift)
        report.update(timing="quant+shift", shift_ms=round(shift * 1000), plateau_ms=[round(min(plateau) * 1000), round(max(plateau) * 1000)])
        score = None
    # O ataque: um deslocamento por item para a mediana de (ataque medido − começo) ficar em zero (notas que atacam:
    # sem ligado ou slide de chegada), duas passadas (o ataque é procurado a ±120 ms do começo). Na variante "asis", só
    # nos itens sem o fino.
    centre = ARGS.variant == "centered" or report["timing"] != "fine"
    moved = 0.0
    # Só as notas isoladas (nenhum outro começo a ±150 ms no tempo do GP): numa passagem rápida o ataque mais forte
    # dos ±120 ms pode ser o da vizinha. Com menos de 20 delas, todas.
    onsets = sorted({round(p[0], 4) for p in plain})
    def isolated(s):
        k = bisect.bisect_left(onsets, round(s, 4))
        return (k == 0 or s - onsets[k - 1] >= 0.15) and (k + 1 >= len(onsets) or onsets[k + 1] - s >= 0.15)
    lonely = [p for p in plain if isolated(p[0]) and not p[2]["approached"]]
    report["attack_notes"] = len({round(p[0], 4) for p in lonely})
    sample = lonely if report["attack_notes"] >= 20 else plain
    for _ in range(2 if centre else 1):
        seen, offsets = set(), []
        for s, e, n in sample:
            if n["approached"] or round(s, 4) in seen:
                continue
            seen.add(round(s, 4))
            a = mapping(s)
            at = pitch.attack(x, a)
            if at is not None:
                offsets.append(at - a)
        median = statistics.median(offsets) if offsets else 0.0
        report["attack_before_ms"] = report.get("attack_before_ms", round(median * 1000, 1))
        if not centre:
            break
        moved += median
        mapping = Map(list(zip(mapping.x, mapping.y)), median)
    report["attack_shift_ms"] = round(moved * 1000, 1)
    score, n, devs = plain_score(x, plain, mapping)
    report["score_n"] = n
    report["score"] = round(score, 3)
    report["median_dev"] = round(statistics.median(devs), 3) if devs else None
    # As curvas de todas as notas.
    out_tracks = []
    attacks = []
    for t in tracks:
        notes = []
        for n in t["notes"]:
            for k, (s, e) in enumerate(n["plays"]):
                a, b = mapping(s), mapping(e)
                if not (0 <= a and b <= duration and 0.04 <= b - a <= 8) or not 20 <= n["pitch"] <= 110:
                    continue
                c = pitch.note_curve(x, a, b, float(n["pitch"]), others=[float(o) for o in n["others"]])
                if c["attack"] is not None and not n["approached"]:
                    attacks.append(c["attack"] - a)
                note = {key: n[key] for key in ("tick", "duration", "pitch", "string", "fret", "vibrato", "trill", "bend",
                                                 "others", "next", "approached", "slidesOut", "bar")}
                note.update(start=round(a, 4), end=round(b, 4), play=k, curve=c)
                notes.append(note)
        notes.sort(key=lambda n: (n["start"], n["string"]))
        out_tracks.append({"index": t["index"], "name": t["name"], "tuning": t["tuning"], "notes": notes})
    if attacks:
        s = sorted(attacks)
        report.update(attack_med_ms=round(s[len(s) // 2] * 1000, 1), attack_iqr_ms=round((s[3 * len(s) // 4] - s[len(s) // 4]) * 1000, 1),
                      attack_n=len(s), attack_within_30ms=round(sum(abs(v) <= 0.03 for v in s) / len(s), 3))
    report["notes"] = sum(len(t["notes"]) for t in out_tracks)
    report["written_bends"] = sum(1 for t in out_tracks for n in t["notes"] if n["bend"])
    report["seconds"] = round(time.time() - t0, 1)
    song = {"name": item, "item": item, "title": g.get("title"), "artist": g.get("artist"),
            "tuning_class": meta["tuning_class"], "player": meta["player"], "guitar": meta["guitar_brand"],
            "score": report["score"], "timing": report["timing"], "barStarts": g["barStarts"], "tracks": out_tracks}
    return report, song


def init(args, gp, meta):
    global ARGS, GP, META
    ARGS, GP, META = args, gp, meta
    setup(args.repo)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("repo"); ap.add_argument("gp"); ap.add_argument("metadata"); ap.add_argument("data"); ap.add_argument("out")
    ap.add_argument("items", nargs="*")
    ap.add_argument("--workers", type=int, default=5)
    ap.add_argument("--min-score", type=float, default=0.7)
    ap.add_argument("--variant", choices=["centered", "asis"], default="centered",
                    help="centered: cada item deslocado para a mediana do ataque cair no começo; asis: o fino como veio")
    args = ap.parse_intermixed_args()
    gp = {x["item"]: x for x in json.load(open(args.gp))}
    meta = {r["item"]: r for r in csv.DictReader(open(args.metadata))}
    items = args.items or sorted(gp, key=lambda s: int(s.split("_")[1]))
    reports, songs = [], []
    with Pool(args.workers, initializer=init, initargs=(args, gp, meta)) as pool:
        for report, song in pool.imap_unordered(work, items):
            print(json.dumps(report, ensure_ascii=False), flush=True)
            reports.append(report)
            if song:
                songs.append(song)
    order = {it: k for k, it in enumerate(items)}
    songs.sort(key=lambda s: order[s["item"]])
    reports.sort(key=lambda r: order[r["item"]])
    kept = [s for s in songs if s["score"] >= args.min_score]
    json.dump({"songs": kept}, open(args.out, "w"))
    json.dump(reports, open(args.out.replace(".json", "") + "-relatorio.json", "w"), ensure_ascii=False, indent=1)
    print(f"{len(kept)} de {len(songs)} itens com validação ≥ {args.min_score:.0%}", file=sys.stderr)
