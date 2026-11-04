#!/bin/bash
# run.sh — roda UMA tarefa agêntica no opencode (direto na :1234 do Ancalagon) e avalia por fora.
#
# uso: run.sh MODELO TAREFA COND TAG
#   MODELO  preset já ativo no Ancalagon (flint|qwen38|coder|...) — quem sobe é o matrix.sh
#   TAREFA  hard | bugfix | refactor
#   COND    sem | com   (com = copia o pré-prompt para AGENTS.md na raiz da tarefa)
#   TAG     rótulo livre do run (r1, r2...)
# env:
#   RUNS    onde ficam as cópias de trabalho e os logs (default: $TMPDIR/ancalagon-agentic)
#   PROMPT_FILE  pré-prompt usado em COND=com (default: ../../clients/opencode/AGENTS.md)
#   DRY     se definido, roda "$DRY" no lugar do opencode (autoteste dos avaliadores)
#
# Saída: 1 linha TSV em $RUNS/results.tsv (e no stdout). Método e resultados: benchmarks/TUNING.md §20.
set -u
M=$1; T=$2; C=$3; TAG=$4
H=$(cd "$(dirname "$0")" && pwd)
RUNS=${RUNS:-${TMPDIR:-/tmp}/ancalagon-agentic}
PROMPT_FILE=${PROMPT_FILE:-$H/../../clients/opencode/AGENTS.md}
W=$RUNS/$M-$T-$C-$TAG; L=$W.log
mkdir -p "$RUNS"; rm -rf "$W"
case $T in
  hard)     LIM=600
            PROMPT="Faça todos os testes de test_durations.py passarem (python3 -m unittest). Não altere test_durations.py. Rode os testes para confirmar antes de terminar." ;;
  bugfix)   LIM=900
            PROMPT="Resolva a issue descrita em ISSUE.md. Siga as regras de negócio documentadas nos módulos. Adicione testes de regressão para cada item da issue em tests/test_regressao.py, sem alterar os testes existentes. Rode a suíte inteira (python3 -m unittest discover -s tests -t .) para confirmar antes de terminar." ;;
  refactor) LIM=900
            PROMPT="Refatore lojinha/relatorio.py. Hoje o cálculo de preço está copiado três vezes dentro de gerar_relatorio e duplica o que lojinha/precos.py já faz. (1) Use as funções de lojinha/precos.py em vez do cálculo duplicado. (2) Crie lojinha/formatos.py com uma função por formato (csv, json, md) e um dicionário que mapeia o nome do formato para a função. (3) gerar_relatorio(pedidos, formato=\"csv\") continua em lojinha/relatorio.py, com a mesma assinatura, e a saída tem que ser idêntica byte a byte à atual em todos os formatos, inclusive as mensagens de erro. Não altere os testes existentes; pode adicionar testes novos. Rode a suíte inteira (python3 -m unittest discover -s tests -t .) para confirmar antes de terminar." ;;
  *) echo "tarefa inválida: $T" >&2; exit 2 ;;
esac
cp -R "$H/tasks/$T" "$W"
# Repositório git na cópia: o modelo pode usar git diff, e o diffstat final mede o tamanho da mudança.
( cd "$W" && printf '__pycache__/\n' > .gitignore && git init -q . && git add -A \
  && git -c user.name=bench -c user.email=bench@localhost commit -qm base )
cp "$H/opencode-direct.json" "$W/opencode.json"
[ "$C" = com ] && cp "$PROMPT_FILE" "$W/AGENTS.md"

# O opencode 2.2.5 às vezes deixa um "opencode serve" órfão que trava o run seguinte: ao fim,
# encerra só os que nasceram durante ESTE run (nunca um opencode aberto pelo usuário).
antes=$(pgrep -f "opencode serve" | sort)
cd "$W"; t0=$(date +%s)
if [ -n "${DRY:-}" ]; then eval "$DRY" > "$L" 2>&1
else timeout "$LIM" opencode run --auto -m "ancdirect/$M" "$PROMPT" > "$L" 2>&1; fi
rc=$?; dt=$(( $(date +%s)-t0 ))
for pid in $(comm -13 <(echo "$antes") <(pgrep -f "opencode serve" | sort)); do kill "$pid" 2>/dev/null; done

calls=$(sed 's/\x1b\[[0-9;]*m//g' "$L" | grep -c -E '^(→|←|\$) ')
rm -f "$W/opencode.json" "$W/AGENTS.md"
if [ "$T" = hard ]; then
  vis=$(python3 -m unittest 2>&1 | tail -1)
  intact=$([ "$(md5 -q test_durations.py)" = "$(cat "$H/hard-tests.md5")" ] && echo sim || echo NAO)
  hid="n/a"; extra="-"
else
  vis=$(python3 -m unittest discover -s tests -t . 2>&1 | tail -1)
  # sim = idênticos; so_adicoes = testes novos no mesmo arquivo, nenhuma linha original removida/alterada
  if [ "$(md5 -q tests/test_precos.py tests/test_relatorio.py | tr '\n' ' ')" = "$(tr '\n' ' ' < "$H/lojinha-tests.md5")" ]; then intact=sim
  elif [ "$(git diff -U0 -- tests/test_precos.py tests/test_relatorio.py | grep -c '^-[^-]')" = 0 ]; then intact=so_adicoes
  else intact=NAO; fi
  # Testes ocultos: o modelo nunca os vê. O refactor só roda os goldens do relatório.
  rm -rf tests_hidden; mkdir tests_hidden; cp "$H"/hidden/{dataset.py,goldens.json,test_hidden_*.py} tests_hidden/
  [ "$T" = refactor ] && rm tests_hidden/test_hidden_precos.py
  hid=$(python3 -m unittest discover -s tests_hidden -t tests_hidden 2>&1 | grep -E '^(OK|FAILED)' | tail -1)
  rm -rf tests_hidden
  junk=$(git status --porcelain --untracked-files=all | grep -v -E '__pycache__|tests/test_[a-z_]+\.py|lojinha/formatos.py|^ M ' | tr '\n' ' ')
  if [ "$T" = bugfix ]; then
    nreg=$( [ -f tests/test_regressao.py ] && grep -c -E '^\s+def test_' tests/test_regressao.py || echo 0)
    extra="testes_regressao=$nreg sobras=[${junk:-nenhuma}]"
  else
    extra=$(python3 "$H/check_refactor.py" "$W")" sobras=[${junk:-nenhuma}]"
  fi
fi
diffstat=$(git diff --shortstat 2>/dev/null | sed 's/^ //'); diffstat=${diffstat:--}
printf '%s\t%s\t%s\t%s\trc=%s\t%ss\tcalls=%s\tvisiveis=[%s]\ttestes_intactos=%s\tocultos=[%s]\t%s\tdiff=[%s]\n' \
  "$M" "$T" "$C" "$TAG" "$rc" "$dt" "$calls" "$vis" "$intact" "$hid" "$extra" "$diffstat" | tee -a "$RUNS/results.tsv"
