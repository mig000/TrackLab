"""As curvas de altura das notas (a receita do motor, tracklab.media.pitch) no MP3 de cada Guitar Pro, com os ajustes
de sincronia de `ajustes.json` (deslocamento em segundos e escala do tempo, achados pela sincronia.py: o tempo de cada
nota vira tempo × escala + deslocamento) e sem os arquivos de "fora".

engine/.venv/bin/python -I bench/licks/curvas.py <notas.json> <saída.json> [--apenas nome…] [--exceto nome…]
(o refazer.sh chama)"""
import argparse, json, sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parent.parent / "engine" / "src"))
from tracklab.media import pitch  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("notas")
ap.add_argument("saida")
ap.add_argument("--apenas", nargs="*", default=None)
ap.add_argument("--exceto", nargs="*", default=[])
args = ap.parse_args()
fixes = json.loads((here / "ajustes.json").read_text())
data = json.load(open(args.notas))
songs = []
for song in data["songs"]:
    name = song["name"]
    if name in fixes["fora"] or name in args.exceto or (args.apenas is not None and name not in args.apenas):
        continue
    shift, scale = fixes["sincronia"].get(name, [0.0, 1.0])
    x = pitch.samples(Path(song["mp3"]))
    for track in song["tracks"]:
        kept = []
        for n in track["notes"]:
            n["start"], n["end"] = n["start"] * scale + shift, n["end"] * scale + shift
            if not (0 <= n["start"] < n["end"] <= n["start"] + 8) or not 20 <= n["pitch"] <= 110:
                continue
            n["curve"] = pitch.note_curve(x, n["start"], n["end"], float(n["pitch"]), others=[float(o) for o in n["others"]])
            kept.append(n)
        track["notes"] = kept
    songs.append(song)
    print(name, sum(len(t["notes"]) for t in song["tracks"]), "curvas", "(ajuste %+.3f s × %.5f)" % (shift, scale)
          if (shift, scale) != (0.0, 1.0) else "", file=sys.stderr)
json.dump({"songs": songs}, open(args.saida, "w"))
