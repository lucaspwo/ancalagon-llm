#!/bin/bash
# matrix.sh — sobe um preset no Ancalagon e roda as 3 tarefas sem/com o pré-prompt (6 runs, ~15-45 min).
# uso: matrix.sh MODELO TAG        ex.: matrix.sh flint r2
set -u
H=$(cd "$(dirname "$0")" && pwd); M=$1; TAG=$2
ssh Anc_U-T /home/lucas/.local/bin/lmswitch "$M" | tail -1 || exit 1
for T in hard bugfix refactor; do
  for C in sem com; do "$H/run.sh" "$M" "$T" "$C" "$TAG"; done
done
