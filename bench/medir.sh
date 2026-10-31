#!/bin/zsh
# As quatro medidas da detecção de bend (medicaoDosBends) e do corretor (medicaoDoCorretor), lado a lado: o GOAT, as
# músicas do repertório, os licks e o reference.gp, dos arquivos de $TRACKLAB_BENCH_DIR (~/TrackLab/Medidas: goat.json
# do bench/goat/refazer.sh, musicas.json do web/tools/bend-curves.cjs, licks.json e reference.json do
# bench/licks/refazer.sh; o que faltar fica de fora). Cada medida vai para medidas/<rótulo>/ e o resumo para a tela.
# ~2 min no iMac.
#
#   zsh bench/medir.sh <rótulo>
set -euo pipefail
label=${1:?rótulo (a pasta das medidas, para comparar uma mudança com a anterior)}
repo=${0:A:h:h}
dir=${TRACKLAB_BENCH_DIR:-$HOME/TrackLab/Medidas}
out=$dir/medidas/$label
mkdir -p "$out"
cd "$repo/mac"
for name in goat musicas licks reference; do
  file=$dir/$name.json
  [[ -f $file ]] || { echo "sem $file: fica de fora" >&2; continue; }
  TRACKLAB_BEND_BENCH=$file ./test.sh --filter medicaoDosBends >/dev/null 2>&1
  TRACKLAB_CORRECTOR_BENCH=$file ./test.sh --filter medicaoDoCorretor >/dev/null 2>&1
  cp "$file.txt" "$out/$name.txt"
  cp "$file.corretor.txt" "$out/$name.corretor.txt"
done
python3 - "$out" <<'PY'
import os, re, sys
keys = [("escrito com bend", "bends"), ("escrito: o som tem o mesmo tipo", "tipo"), ("escrito: mesmo tipo e alturas", "tipo+alt"),
        ("escrito: o som não dobra", "não dobra"), ("não escrito: o som dobra ½ tom ou mais, confirmado", "não escr≥½"),
        ("suspeita: altura", "altura"), ("suspeita: bend", "bend"), ("suspeitas (notas)", "suspeitas")]
corrector = [("corrigidas", "corrig"), ("Miguel mudou: o corretor fez igual", "=Miguel")]
def table(path):
    head = open(path, encoding="utf-8").read().split("\n\n")[0]
    return dict(re.findall(r"^(.*?): (\d+)$", head, re.M))
print(f"{'conjunto':10s}" + "".join(f"{k[1]:>11s}" for k in keys + corrector))
for name in ["goat", "musicas", "licks", "reference"]:
    path = os.path.join(sys.argv[1], name + ".txt")
    if not os.path.exists(path):
        continue
    t, c = table(path), table(path.replace(".txt", ".corretor.txt"))
    print(f"{name:10s}" + "".join(f"{t.get(k[0], '-'):>11s}" for k in keys) + "".join(f"{c.get(k[0], '-'):>11s}" for k in corrector))
PY
