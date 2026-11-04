# Benchmark agêntico (opencode → Ancalagon)

Três tarefas de código resolvidas pelo opencode, sozinho, contra o preset ativo na `:1234`, e avaliadas
**por fora**: testes visíveis, testes ocultos que o modelo nunca vê, checagem de que não alterou testes
existentes, arquivos sobrando e tamanho do diff. Método e resultados: [`../TUNING.md` §20](../TUNING.md).

```bash
benchmarks/agentic/matrix.sh flint r2          # sobe o preset e roda hard/bugfix/refactor × sem/com (6 runs)
benchmarks/agentic/run.sh flint refactor com r3  # um run só (preset já ativo)
cat ${TMPDIR}ancalagon-agentic/results.tsv       # 1 linha por run
```

- `tasks/hard` — 9 testes `unittest` (`durations.py`), a mesma tarefa do §18.
- `tasks/bugfix` — repo `lojinha` com 4 bugs plantados e um `ISSUE.md` que só descreve sintomas.
- `tasks/refactor` — o mesmo repo correto, com a lógica de preço triplicada em `relatorio.py`.
- `hidden/` — testes ocultos. `goldens.json` saiu do `relatorio.py` original:
  `python3 hidden/gen_goldens.py tasks/refactor hidden hidden/goldens.json`.
- `AGENTS.v1.md` — o pré-prompt medido em 2026-11-04. O vigente é `../../clients/opencode/AGENTS.md`
  (`COND=com` usa ele; `PROMPT_FILE=` troca).
- `opencode-direct.json` — provider `ancdirect` direto no Ancalagon (sem o `llm-gateway`), com o `limit.context`
  de cada preset.

Autoteste dos avaliadores, sem modelo: `DRY='true' ./run.sh dry bugfix sem t0` deve dar
`ocultos=[FAILED (failures=3, errors=6)]` (os 4 bugs ainda lá).

Cuidados: feche sessões do opencode antes (o 2.2.5 às vezes deixa um `opencode serve` órfão que trava o
próximo run; o `run.sh` só mata os que ele mesmo criou). As cópias de trabalho ficam em `$RUNS`
(default `$TMPDIR/ancalagon-agentic`), nunca dentro do repo.
