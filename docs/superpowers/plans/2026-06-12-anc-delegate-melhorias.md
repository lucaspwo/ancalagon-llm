# Melhorias `anc-delegate` (roteamento + instrumentação) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Afiar o roteamento Caminho 1 vs 2 no `SKILL.md` e instrumentar o `anc-delegate` para reportar a economia bruta de tokens (one-liner no stderr) a cada chamada `gen`/`iter`.

**Architecture:** Duas mudanças isoladas na skill já mergeada. #1 é docs pura (reescrita de uma seção do `SKILL.md`). #2 refatora `gen` (capturar resposta inteira, extrair `usage`, imprimir one-liner no stderr, emitir content no stdout) e adiciona instrumentação a `iter` (extrair `usage` do JSON, one-liner no stderr, repassar JSON intacto). stdout preservado em ambos.

**Tech Stack:** Bash (`set -euo pipefail`, shellcheck-clean), `curl`/`jq`. Verificação: shellcheck + smoke test real contra `ancalagon-ubuntu:1234`.

**Spec:** `docs/superpowers/specs/2026-06-12-anc-delegate-melhorias-design.md`

**Estado verificado (2026-06-12):** formato `usage` da `:1234` confirmado OpenAI-compat: `usage.completion_tokens`, `usage.prompt_tokens`, `usage.total_tokens`. O coder está no ar para smoke tests. Branch: `feat/anc-delegate-instrumentacao`.

---

## Task 1: Instrumentar `gen` (#2, Caminho 1)

**Files:**
- Modify: `skills/delegando-ancalagon/anc-delegate:113-132` (função `gen`)

- [ ] **Step 1: Reescrever `gen` para capturar resposta e instrumentar**

Substituir a função `gen` inteira (linhas 113-132) por:
```bash
gen() {
  local briefing_file="$1"
  [[ -f "$briefing_file" ]] || { log "briefing não encontrado: $briefing_file"; return 1; }
  local prompt; prompt="$(cat "$briefing_file")"
  local approx_tokens=$(( $(printf '%s' "$prompt" | wc -c) / 4 ))
  if (( approx_tokens > 40000 )); then
    log "ERRO: briefing ~${approx_tokens} tokens (>40K). Recorte ruim — re-planeje."
    return 1
  fi
  local model_id
  model_id="$(curl -sf -m5 "http://$HOST:$PORT/v1/models" | jq -r '.data[0].id // "local"')"
  local payload
  payload="$(jq -n --arg m "$model_id" --arg c "$prompt" '{
    model:$m, messages:[{role:"user",content:$c}],
    temperature:0.2, max_tokens:8192, stream:false
  }')"
  local resp
  resp="$(curl -sf -m 600 "http://$HOST:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$payload")" || {
    log "ERRO: requisição à :$PORT falhou"; return 1; }

  # Instrumentação (#2): economia BRUTA do lado Ancalagon. O helper NÃO vê o
  # custo de cloud de escrever o briefing nem de revisar/reaplicar.
  local comp prompt_t content
  comp="$(printf '%s' "$resp" | jq -r '.usage.completion_tokens // empty')"
  prompt_t="$(printf '%s' "$resp" | jq -r '.usage.prompt_tokens // empty')"
  content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content')"
  if [[ -n "$comp" && -n "$prompt_t" ]]; then
    log "[anc] gen: gerados ${comp} tok (poupados do cloud) · briefing ${prompt_t} tok · economia BRUTA"
  else
    local est=$(( $(printf '%s' "$content" | wc -w) * 4 / 3 ))
    log "[anc] gen: ~${est} tok gerados (~estimado, sem usage na resposta) · economia BRUTA"
  fi

  printf '%s\n' "$content"
}
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck skills/delegando-ancalagon/anc-delegate`
Expected: sem warnings.

- [ ] **Step 3: Smoke test — stdout limpo + one-liner no stderr**

Run:
```bash
printf '# Tarefa\nEscreva uma função Python add(a,b) que retorna a soma. Só o código.\n' > /tmp/brief.md
echo "=== STDOUT (deve ser só o código, sem [anc]) ==="
skills/delegando-ancalagon/anc-delegate gen /tmp/brief.md 2>/tmp/gen-err.log
echo "=== STDERR (deve conter [anc] gen: ... economia BRUTA) ==="
grep '\[anc\] gen:' /tmp/gen-err.log
```
Expected: stdout traz só a função `def add`; stderr tem a linha `[anc] gen: gerados <N> tok ... economia BRUTA` com números inteiros plausíveis. O `[anc]` NÃO aparece no stdout.

- [ ] **Step 4: Verificar que o one-liner bate com a resposta crua**

Run:
```bash
curl -sf -m60 http://ancalagon-ubuntu:1234/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"diga oi"}],"max_tokens":16,"stream":false}' \
  | jq '.usage'
```
Expected: confirma que `completion_tokens`/`prompt_tokens` existem na resposta (formato já validado) — o número no one-liner vem daí, não é inventado.

- [ ] **Step 5: Commit**

```bash
git add skills/delegando-ancalagon/anc-delegate
git commit -m "feat(skill): instrumenta gen com one-liner de economia bruta no stderr"
```

---

## Task 2: Instrumentar `iter` (#2, Caminho 2)

**Files:**
- Modify: `skills/delegando-ancalagon/anc-delegate:134-143` (função `iter`)

- [ ] **Step 1: Reescrever `iter` para capturar JSON e instrumentar**

Substituir a função `iter` inteira (linhas 134-143) por:
```bash
iter() {
  local briefing_file="$1"; local cwd="$2"
  [[ -f "$briefing_file" ]] || { log "briefing não encontrado: $briefing_file"; return 1; }
  [[ -d "$cwd" ]] || { log "cwd inválido: $cwd"; return 1; }
  local prompt; prompt="$(cat "$briefing_file")"
  log "Disparando Claude Code headless em $cwd (inferência no Ancalagon)..."
  local out
  out="$( cd "$cwd" && \
    local-claude --backend remote --host "$HOST" --port "$PORT" \
      -p "$prompt" --output-format json )"

  # Instrumentação (#2): tokens processados LOCAL (na GPU do Ancalagon). O cloud
  # paga só o briefing + a leitura deste resumo.
  local in_t out_t
  in_t="$(printf '%s' "$out" | jq -r '.usage.input_tokens // empty' 2>/dev/null)"
  out_t="$(printf '%s' "$out" | jq -r '.usage.output_tokens // empty' 2>/dev/null)"
  if [[ -n "$in_t" && -n "$out_t" ]]; then
    log "[anc] iter: agente local processou ${in_t} in + ${out_t} out tok na GPU · cloud pagou só briefing + este resumo"
  else
    log "[anc] iter: usage indisponível na resposta"
  fi

  printf '%s\n' "$out"
}
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck skills/delegando-ancalagon/anc-delegate`
Expected: sem warnings.

- [ ] **Step 3: Smoke test — JSON íntegro no stdout + one-liner no stderr**

Run:
```bash
TMP=$(mktemp -d); git -C "$TMP" init -q
printf '# Tarefa\nCrie um arquivo hello.txt com o conteúdo "oi". Use suas tools.\n' > /tmp/brief-iter.md
echo "=== STDOUT (deve ser JSON parseável) ==="
skills/delegando-ancalagon/anc-delegate iter /tmp/brief-iter.md --cwd "$TMP" 2>/tmp/iter-err.log | jq -r '.subtype // "JSON-INVALIDO"'
echo "=== arquivo criado? ==="; cat "$TMP"/hello.txt 2>/dev/null
echo "=== STDERR (deve conter [anc] iter: ...) ==="
grep '\[anc\] iter:' /tmp/iter-err.log
rm -rf "$TMP"
```
Expected: stdout é JSON válido (jq extrai `subtype` = `success`); `hello.txt` contém `oi`; stderr tem `[anc] iter: agente local processou <I> in + <O> out tok na GPU ...`. Pode levar 1-2 min.

- [ ] **Step 4: Commit**

```bash
git add skills/delegando-ancalagon/anc-delegate
git commit -m "feat(skill): instrumenta iter com tokens locais no stderr"
```

---

## Task 3: Afiar o roteamento no `SKILL.md` (#1)

**Files:**
- Modify: `skills/delegando-ancalagon/SKILL.md` (seção "## Escolha do caminho")

- [ ] **Step 1: Substituir a seção "Escolha do caminho"**

Localizar a seção atual:
```markdown
## Escolha do caminho

- **Caminho 1 (`gen`)** — spec fechada → código/texto, **nada a executar**:
  boilerplate, suíte de testes para código definido, conversão A→B, refactor
  mecânico. Você monta o briefing, o Ancalagon gera, **você aplica e revisa o
  diff**. Economiza os output tokens da geração.
- **Caminho 2 (`iter`)** — precisa **rodar/verificar/iterar**: "faça os testes
  passarem", lint que corrige, debugging com ciclo tentativa-erro. Um Claude Code
  headless roda no Mac (tools reais: Read/Edit/Bash, no diretório do repo) com a
  inferência inteira na GPU do Ancalagon. Ele edita/roda sozinho; você lê o resumo
  + `git diff`. Economia máxima — nem as iterações intermediárias custam tokens
  cloud.
```
Substituir por:
```markdown
## Escolha do caminho

A economia depende mais de **qual caminho** que de como briefar. Detalhes e o caso
que motivou esta regra: memória `feedback_anc_caminho1_economia_tokens`.

- **Caminho 1 (`gen`)** — usar **somente** quando os três valem:
  1. **Output ≫ spec** — boilerplate/expansão mecânica (ex.: N fixtures de um
     schema pequeno). Se especificar é quase tão caro quanto escrever, não delega.
  2. **Revisão leve** — baixo risco de bug, output verificável de relance.
  3. **Pouca referência embutida** — o briefing não precisa carregar trechos
     grandes de outros arquivos (o Ancalagon não os lê).

  **Aplicação (preserva a economia):** `cp` da saída crua para o destino + `Edit`
  cirúrgico nos ajustes. **Nunca** re-Write o arquivo inteiro no cloud — re-emitir
  o conteúdo gerado joga fora a economia da geração.

- **Caminho 2 (`iter`)** — default para qualquer coisa com **muita referência**
  (o agente headless lê os arquivos — o briefing vira tarefa + ponteiros, não
  conteúdo copiado), **testável** (o agente roda os testes e te entrega verde +
  `git diff`), ou **sutil**. O custo de cloud desacopla do tamanho da tarefa:
  briefing curto + resumo curto; o trabalho pesado roda local na GPU.

  **Ressalva:** só ganha se o qwen3-coder for competente para a tarefa sem
  supervisão — ganho de token não compra competência. Se o modelo local
  provavelmente erraria, faça no cloud ou aceite revisar o resultado.

Cada chamada imprime no stderr um one-liner `[anc] ...` com a **economia bruta**
(tokens do lado Ancalagon). É teto, não líquido: não inclui seu custo de cloud de
escrever o briefing nem de revisar. Some-os ao decidir se valeu.
```

- [ ] **Step 2: Verificar que o frontmatter e o resto do SKILL.md seguem intactos**

Run: `head -6 skills/delegando-ancalagon/SKILL.md && grep -c '## ' skills/delegando-ancalagon/SKILL.md`
Expected: frontmatter YAML com `name:`/`description:` intacto; as demais seções (`## Quando NÃO delegar`, `## Procedimento`, `## Guard-rails`) ainda presentes.

- [ ] **Step 3: Commit**

```bash
git add skills/delegando-ancalagon/SKILL.md
git commit -m "docs(skill): afia roteamento Caminho 1 vs 2 (condições reais de economia)"
```

---

## Task 4: Caso defensivo — fallback sem `usage`

**Files:**
- Test: verificação manual (sem modificar código — valida o fallback já escrito nas Tasks 1-2)

- [ ] **Step 1: Validar o fallback do `gen` (sem usage) com função shell isolada**

O fallback está nas Tasks 1-2 (`else` branches). Validar a lógica de estimativa do `gen` sem depender de uma resposta real malformada:
```bash
bash -c '
content="def add(a, b):
    return a + b"
est=$(( $(printf "%s" "$content" | wc -w) * 4 / 3 ))
echo "estimativa de fallback: ${est} tok (deve ser > 0)"
'
```
Expected: imprime um número > 0 (ex.: `~9 tok`). Confirma que a aritmética do fallback não quebra (sem divisão por zero, sem string vazia).

- [ ] **Step 2: Validar o fallback do `iter` (JSON sem usage)**

Run:
```bash
echo '{"subtype":"success"}' | jq -r '.usage.input_tokens // empty' 2>/dev/null
echo "exit=$? (jq não falha em campo ausente; saída vazia = aciona o else)"
```
Expected: saída vazia, exit 0 — confirma que `.usage.input_tokens // empty` num JSON sem `usage` retorna vazio (aciona o branch `[anc] iter: usage indisponível`), não crash.

- [ ] **Step 3: shellcheck final do arquivo completo**

Run: `shellcheck skills/delegando-ancalagon/anc-delegate && echo CLEAN`
Expected: `CLEAN`.

---

## Self-Review (preenchido)

**Spec coverage:**
- #1 roteamento afiado (3 condições Caminho 1, default Caminho 2, ressalva competência, disciplina cp+Edit) → Task 3. ✓
- #2 instrumentação `gen` (captura resp, extrai usage, one-liner stderr, content no stdout) → Task 1. ✓
- #2 instrumentação `iter` (extrai usage do JSON, one-liner stderr, JSON no stdout) → Task 2. ✓
- Restrição "economia BRUTA" no rótulo (E2) → Tasks 1 e 3 (one-liner + nota no SKILL.md). ✓
- stdout preservado (E3) → Tasks 1-2 smoke tests validam stdout limpo. ✓
- Fallback defensivo sem usage → Tasks 1-2 (código) + Task 4 (validação). ✓
- #3 excluído (E4), sem auto-router (E5) → não há task, correto. ✓

**Placeholder scan:** `<N>`/`<I>`/`<O>` nos Expected são valores de runtime (números reais que aparecem na execução), não placeholders de código. Todo código está completo. ✓

**Type consistency:** funções `gen`/`iter` mantêm a mesma assinatura e o mesmo contrato de stdout (content / JSON); o dispatch (linhas 167-173 do arquivo) não muda. Variáveis novas (`resp`, `comp`, `prompt_t`, `content`, `out`, `in_t`, `out_t`) são locais, não colidem. ✓
