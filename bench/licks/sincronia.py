"""A busca do ajuste de sincronia de um arquivo (para o ajustes.json): larga e depois fina, do deslocamento (−1 a +1 s)
e da escala do tempo (0,94 a 1,06), pela fração das notas sem acorde e sem bend com a mediana da metade do meio da curva
a menos de meio semitom da altura escrita. Lenta (minutos por arquivo).

engine/.venv/bin/python -I bench/licks/sincronia.py <notas.json> <nome>"""
import json, statistics, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "engine" / "src"))
from tracklab.media import pitch  # noqa: E402

data = json.load(open(sys.argv[1]))
name = sys.argv[2]
song = next(s for s in data["songs"] if s["name"] == name)
x = pitch.samples(Path(song["mp3"]))
notes = [n for n in song["tracks"][0]["notes"] if not n["others"] and not n["bend"]]


def score(shift, scale):
    good = total = 0
    for n in notes:
        a, b = n["start"] * scale + shift, n["end"] * scale + shift
        if a < 0 or b - a < 0.06:
            continue
        c = pitch.note_curve(x, a, b, float(n["pitch"]))
        length = b - a
        values = [v for i, v in enumerate(c["values"])
                  if v is not None and a + 0.25 * length <= c["from"] + i * c["hop"] <= b - 0.25 * length]
        if len(values) < 3:
            continue
        total += 1
        good += abs(statistics.median(values) - n["pitch"]) < 0.5
    return good / max(1, total)


best = (score(0, 1), 0.0, 1.0)
print(f"sem ajuste: {best[0]:.0%}", flush=True)
for scale in [0.94 + 0.01 * k for k in range(13)]:
    for shift in [-1.0 + 0.08 * k for k in range(26)]:
        r = score(shift, scale)
        if r > best[0]:
            best = (r, shift, scale)
print(f"busca larga: {best[0]:.0%} com {best[1] * 1000:+.0f} ms × {best[2]:.4f}", flush=True)
_, s0, k0 = best
for scale in [k0 + 0.0025 * k for k in range(-4, 5)]:
    for shift in [s0 + 0.01 * k for k in range(-8, 9)]:
        r = score(shift, scale)
        if r > best[0]:
            best = (r, shift, scale)
print(f"{name}: {best[0]:.0%} com {best[1] * 1000:+.0f} ms × {best[2]:.4f} → \"{name}\": [{best[1]:.4f}, {best[2]:.5f}]")
