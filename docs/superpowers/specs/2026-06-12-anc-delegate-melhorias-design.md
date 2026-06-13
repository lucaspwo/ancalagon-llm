# Design: melhorias na skill `delegando-ancalagon` (roteamento + instrumentação)

**Data:** 2026-06-12
**Autor:** Lucas + Claude (brainstorming)
**Status:** spec — aguardando review antes do plano
**Spec anterior:** `2026-06-12-delegando-ancalagon-design.md` (a skill base, já mergeada)

## Problema

Uso real da skill (2026-06-12, gerar `fleet-anexos.js` via Caminho 1) revelou que
a delegação **não economizou tokens** — o briefing (128 linhas) era quase do
tamanho do output (187 linhas), a revisão foi pesada (2 bugs sutis) e a aplicação
re-emitiu o arquivo. Saldo de output ~negativo vs. escrever direto.

Duas causas-raiz:
1. **Roteamento impreciso.** A regra atual ("tem que executar? → Caminho 2") não
   captura que o Caminho 1 só economiza sob condições estreitas, nem que tarefas
   com muita referência embutida pertencem ao Caminho 2 mesmo sem necessidade de
   iterar (o agente lê os arquivos, não precisa embutir no briefing).
2. **Economia invisível.** Não há medição — toda discussão de "economizou?" é
   palpite. A resposta da `:1234` carrega `usage`, mas o helper o descarta.

Referência do aprendizado: memória `feedback_anc_caminho1_economia_tokens`.

## Objetivos

- **#1** — Reescrever o roteamento no `SKILL.md` para uma regra precisa de quando
  cada caminho economiza, incluindo a disciplina de aplicação (`cp`+`Edit`).
- **#2** — Instrumentar `anc-delegate`: one-liner no stderr a cada chamada com os
  tokens reais do lado Ancalagon (economia bruta), preservando o stdout atual.

## Não-objetivos

- **#3 (`gen --out <arquivo>`)** — excluído (YAGNI). `cp` da saída + `Edit`
  cirúrgico já aplica sem re-emitir; vira disciplina documentada no #1, não código.
- **Roteamento automático** Caminho 1 vs 2 — o cloud decide pela heurística; não
  há auto-router.
- **Razão de tokens líquido** — o helper não enxerga o custo de cloud (escrever
  briefing, revisar). Reporta só economia bruta (ver Restrição).

## Restrição honesta (núcleo do design)

O `anc-delegate` roda no Mac e só observa a resposta da `:1234`. Ele conhece:
- `completion_tokens` — output que o cloud **não emitiu** (economia bruta).
- `prompt_tokens` — o briefing enviado.

Ele **não** conhece o custo de cloud de (a) escrever o briefing nem (b)
revisar/reaplicar — isso ocorre na sessão cloud, fora do processo. Logo a
instrumentação reporta **economia BRUTA (teto)**, não líquida. O rótulo no
one-liner deixa isso explícito; o cloud soma os próprios custos de cabeça.

## #1 — Roteamento afiado (`SKILL.md`)

Substitui a seção "Escolha do caminho" atual. Regra nova:

- **Caminho 1 (`gen`)** — usar **somente** quando os três valem:
  1. **Output ≫ spec** — boilerplate/expansão mecânica (ex.: N fixtures de um
     schema pequeno). Se especificar é quase tão caro quanto escrever, não delega.
  2. **Revisão leve** — baixo risco de bug, output verificável de relance.
  3. **Pouca referência embutida** — o briefing não precisa carregar trechos
     grandes de outros arquivos (o Ancalagon não os lê).
  **Aplicação:** `cp` da saída crua para o destino + `Edit` cirúrgico nos ajustes.
  **Nunca** re-Write o arquivo inteiro no cloud — isso joga fora a economia.

- **Caminho 2 (`iter`)** — default para qualquer coisa com **muita referência**
  (o agente headless lê os arquivos — briefing vira tarefa + ponteiros),
  **testável** (o agente roda os testes e entrega verde/diff), ou **sutil**. O
  custo de cloud desacopla do tamanho da tarefa (briefing curto + resumo curto;
  o trabalho pesado roda local na GPU).
  **Ressalva:** só ganha se o qwen3-coder for competente para a tarefa sem
  supervisão — ganho de token não compra competência. Se o modelo local provavelmente
  erraria, ou faça você mesmo no cloud, ou aceite revisar o resultado.

Mantém os guard-rails existentes (40K tokens, nunca desligar service, corte
térmico). Adiciona ponteiro para a memória `feedback_anc_caminho1_economia_tokens`.

## #2 — Instrumentação (`anc-delegate`)

One-liner **sempre no stderr** após cada `gen`/`iter`. Prefixo `[anc]`.

### `gen` (refator)

Hoje: `curl ... | jq -r '.choices[0].message.content'` — descarta `usage`.

Novo fluxo:
1. Captura a resposta completa do `curl` numa variável (`resp`).
2. Extrai `usage.completion_tokens` e `usage.prompt_tokens` via `jq`.
3. Imprime no stderr:
   `[anc] gen: gerados <C> tok (poupados do cloud) · briefing <P> tok · economia BRUTA`
4. Emite `.choices[0].message.content` no stdout (comportamento atual preservado).

Defensivo: se `usage` ausente/null (formato confirmado padrão OpenAI-compat no
llama-server e fork TQ3, mas defensivo mesmo assim), cai para estimativa por
contagem de palavras do content e marca `~estimado` no one-liner. Se a resposta
não for JSON válido, falha como hoje (curl `-sf` já trata HTTP error).

### `iter` (adição)

Hoje: repassa o JSON do `claude -p --output-format json` direto pro stdout.

Novo fluxo:
1. Captura o JSON de resultado numa variável.
2. Extrai `usage.input_tokens` e `usage.output_tokens` (já presentes — validado no
   smoke test da skill base: `input_tokens:23136, output_tokens:121`).
3. Imprime no stderr:
   `[anc] iter: agente local processou <I> in + <O> out tok na GPU · cloud pagou só briefing + este resumo`
4. Emite o JSON intacto no stdout (preserva quem consome).

Defensivo: se o JSON não tiver `usage` (ex.: erro do claude CLI), imprime
`[anc] iter: usage indisponível` e repassa o output como veio.

## Arquivos

| Arquivo | Mudança |
|---|---|
| `skills/delegando-ancalagon/SKILL.md` | reescrita da seção "Escolha do caminho" (#1) |
| `skills/delegando-ancalagon/anc-delegate` | refator `gen` + adição `iter` (#2) |

## Verificação (convenção do repo — shellcheck + smoke real)

- `shellcheck skills/delegando-ancalagon/anc-delegate` clean.
- Smoke `gen`: briefing curto → stdout traz só o content (sem o one-liner
  vazando pro stdout); stderr traz `[anc] gen: ...` com números plausíveis
  (bate com `usage` da resposta crua conferida à parte).
- Smoke `iter`: repo descartável → stdout traz o JSON íntegro e parseável;
  stderr traz `[anc] iter: ...`. Confirmar que separar stdout/stderr
  (`2>/dev/null`) ainda dá o content/JSON limpo — não quebra consumidores.
- Verificar o caso defensivo: forçar/simular resposta sem `usage` e confirmar o
  fallback `~estimado` / `indisponível` sem crash.

## Decisões registradas

| # | Decisão | Razão |
|---|---|---|
| E1 | One-liner sempre no stderr (não flag, não JSON) | Objetivo é tornar o tradeoff visível por padrão; opt-in enfraquece |
| E2 | Rótulo "economia BRUTA" explícito | Helper não vê custo de cloud (briefing/revisão); honestidade sobre o que mede |
| E3 | stdout preservado (content no gen, JSON no iter) | Não quebrar consumidores existentes; instrumentação só no stderr |
| E4 | #3 (`gen --out`) excluído | `cp`+`Edit` já evita re-emissão; disciplina documentada basta |
| E5 | Sem auto-router | Heurística é simples o bastante pro cloud aplicar; YAGNI |
