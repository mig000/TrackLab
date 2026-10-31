#!/bin/zsh
# Refaz os conjuntos de medição dos licks e do reference.gp: as notas de cada Guitar Pro com o áudio dentro (a pasta
# "Blues Licks" de "Backup projeto" no HD externo), no tempo do áudio pelos pontos de sincronia e pelos ajustes de
# ajustes.json, com a curva de altura do motor. Escreve licks.json (todos menos o reference e os de "fora") e
# reference.json em $TRACKLAB_BENCH_DIR (~/TrackLab/Medidas), e os MP3 em audio/ ao lado. ~1 min. Depois: bench/medir.sh.
#
#   zsh bench/licks/refazer.sh [pasta Blues Licks]
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
folder=${1:-"/Volumes/HD Externo WD/Backup projeto/Blues Licks"}
dir=${TRACKLAB_BENCH_DIR:-$HOME/TrackLab/Medidas}
python=${TRACKLAB_PYTHON:-$repo/engine/.venv/bin/python}
mkdir -p "$dir"
node "$here/notas.cjs" "$dir/licks-notas.json" "$dir/audio" "$folder"
"$python" -I "$here/curvas.py" "$dir/licks-notas.json" "$dir/licks.json" --exceto reference
"$python" -I "$here/curvas.py" "$dir/licks-notas.json" "$dir/reference.json" --apenas reference
