#!/bin/zsh
# Refaz o conjunto de medição dos bends do GOAT (as notas do Guitar Pro de cada item no tempo do áudio DI, com a curva
# de altura do motor do TrackLab). O GOAT (arXiv 2509.22655) é o GOAT.zip de "Backup projeto" no HD externo, aberto.
#
#   zsh bench/goat/refazer.sh <pasta GOAT (com metadata.csv e data/)> [saída.json] [centered|asis] [itens…]
#
# A saída padrão é $TRACKLAB_BENCH_DIR/goat.json (~/TrackLab/Medidas). Escreve a saída (só os itens com validação de 70 %
# ou mais) e <saída>-relatorio.json (a sincronia de todos). ~15 min com 5 processos no iMac. Depois: bench/medir.sh.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
goat=${1:?pasta do GOAT (com metadata.csv e data/)}
out=${2:-${TRACKLAB_BENCH_DIR:-$HOME/TrackLab/Medidas}/goat.json}
variant=${3:-centered}
shift $(( $# < 3 ? $# : 3 ))
python=${TRACKLAB_PYTHON:-$repo/engine/.venv/bin/python}
gp=${out%.json}-gp.json
mkdir -p ${out:h}
node "$here/notas.cjs" "$repo" "$goat/data" "$gp" "$@"
"$python" -I "$here/curvas.py" "$repo" "$gp" "$goat/metadata.csv" "$goat/data" "$out" --workers 5 --variant "$variant" "$@"
