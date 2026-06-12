# Skill `delegando-ancalagon` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Uma skill global que permite ao Claude Code cloud terceirizar trabalho ao Ancalagon de forma headless — geração one-shot via `curl :1234` e iteração com tools via `local-claude -p` — com preflight automático de disponibilidade e um watchdog térmico persistente protegendo a GPU.

**Architecture:** Dois componentes. (1) No Mac: `skills/delegando-ancalagon/` com `SKILL.md` (instruções para o Claude) e `anc-delegate` (helper bash: preflight em escada + dois caminhos de disparo). (2) No Ancalagon: `gpu-guard` (watchdog `nvidia-smi` escalonado) + `gpu-guard.service` (systemd user, enabled). Deploy via `make install-skill` e `make install-system` estendido.

**Tech Stack:** Bash (set -euo pipefail, shellcheck-clean — convenção do repo), `curl`/`jq`, systemd --user, `nvidia-smi`, `local-claude` (repo separado, já instalado em `~/.local/bin`), Tailscale SSH.

**Verificação (convenção do repo):** este repo é infra bash (`lmswitch`, `videoswitch`, `bootwin`) sem framework de teste unitário. A verificação segue o padrão existente: **shellcheck-clean** + **smoke test contra o Ancalagon real** com saída esperada documentada. Não introduzir bats/test harness (CLAUDE.md global proíbe ferramentas novas sem justificativa). Pré-requisito: `brew install shellcheck` no Mac (não está instalado — ver Task 0).

**Spec:** `docs/superpowers/specs/2026-06-12-delegando-ancalagon-design.md`

**Gate results (2026-06-12, executados pelo controller):**
- ✅ **Task 0** — shellcheck 0.11.0 instalado.
- ✅ **P0 (Task 1)** — `local-claude --backend remote --host ancalagon-ubuntu -p` retornou `PONG`, exit 0. Caminho 2 viável (ponte de protocolo OK; tool-use validado na Task 5).
- ✅ **Caminho 1 (Task 1)** — `curl :1234` retornou `PONG`.
- ✅ **Host** — corrigido para MagicDNS `ancalagon-ubuntu` (o `100.64.0.10` da doc é fictício; IP real não vai no código).
- ⚠️ **P1 (Task 2)** — Windows tem OpenSSH (confirmado pelo Lucas). `WINDOWS_REBOOT_CMD` preenchido, mas **NÃO-TESTADO** (nó Windows offline enquanto em Linux). Validar na próxima vez que a máquina estiver no Windows.

Tasks 0–2 já concluídas; implementação começa na Task 3.

---

## Task 0: Pré-requisito — shellcheck no Mac

**Files:** nenhum (setup de ambiente)

- [ ] **Step 1: Instalar shellcheck**

Run: `brew install shellcheck`
Expected: instala (ou "already installed").

- [ ] **Step 2: Verificar**

Run: `shellcheck --version`
Expected: imprime versão (ex.: `version: 0.10.0`).

---

## Task 1: GATE P0 — `claude -p` headless funciona contra a `:1234`

Esta é a premissa que define a forma do Caminho 2. **Se falhar, PARE e revise o spec** (o Caminho 2 vira "prepara pacote, Lucas conduz", ou precisamos adicionar um proxy Anthropic↔OpenAI ao backend `remote` do `local-claude`).

**Files:** nenhum (validação)

- [ ] **Step 1: Garantir o coder no ar (modelo de menor consumo, ~100W)**

Run: `ssh Ancalagon_Ubuntu-Tailnet /home/lucas/.local/bin/lmswitch coder`
Expected: termina com `... ready` e `http://localhost:1234 (v1/chat/completions)`.

- [ ] **Step 2: Confirmar health pela Tailscale (do Mac)**

Run: `curl -m 5 -fs http://100.64.0.10:1234/health && echo " HEALTH-OK"`
Expected: `HEALTH-OK`.

- [ ] **Step 3: Confirmar que o curl puro (Caminho 1) responde**

Run:
```bash
curl -sf -m 60 http://100.64.0.10:1234/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Responda apenas: PONG"}],"max_tokens":16,"stream":false}' \
  | jq -r '.choices[0].message.content'
```
Expected: contém `PONG`. **Isto valida o Caminho 1 inteiro.**

- [ ] **Step 4: GATE — testar `local-claude -p` headless (Caminho 2)**

Run:
```bash
local-claude --backend remote --host 100.64.0.10 --port 1234 \
  -p "Responda apenas com a palavra: PONG" 2>/tmp/lc-stderr.log
echo "---exit: $?---"; tail -5 /tmp/lc-stderr.log
```
Expected (PASS): stdout contém `PONG`, exit 0.
Expected (FAIL): erro de protocolo (ex.: 404 `/v1/messages`, "model not found", proxy ausente) → **PARE**. Registre o erro exato e reavalie: o backend `remote` do `local-claude` define `ANTHROPIC_BASE_URL` direto na `:1234` sem proxy Anthropic↔OpenAI (verificado no código). Se o `claude` CLI não falar com a `:1234`, o Caminho 2 precisa de um proxy (modelar como o `apfel-proxy.py` já presente no repo `local-claude`) ou degrada para conduzido pelo Lucas.

- [ ] **Step 5: Registrar resultado**

Anotar no PR/commit: "P0 PASS" ou "P0 FAIL: <erro>". Não prosseguir para Task 5 sem P0 PASS.

---

## Task 2: GATE P1 — canal headless para o Windows (reboot automático)

Determina se o reboot Windows→Linux pode ser **automático** (decisão D8) ou degrada para "reporta ação física".

**Files:**
- Create: `skills/delegando-ancalagon/.p1-result` (arquivo de registro temporário, decide o corpo do helper na Task 3)

- [ ] **Step 1: Descobrir o hostname Tailscale do nó Windows**

Run: `tailscale status | grep -i ancalagon`
Expected: lista nós; identificar o nome do nó Windows (ex.: `ancalagon-windows` / `.23`). Anotar.

- [ ] **Step 2: Testar SSH headless no Windows (se o nó responder)**

Run (substituir `<WIN_HOST>` pelo descoberto):
```bash
ssh -o ConnectTimeout=5 -o BatchMode=yes <WIN_HOST> 'echo WIN-SSH-OK' 2>&1 | tail -3
```
Expected (PASS): `WIN-SSH-OK` → existe canal SSH headless. Reboot automático viável: `ssh <WIN_HOST> 'shutdown /r /t 0'`.
Expected (FAIL): timeout / connection refused / auth → **sem canal headless confirmado**. Nota: o nó Windows `.23` é historicamente instável no Tailscale (memória `reference_ancalagon_windows_tailscale_unreachable`).

- [ ] **Step 3: Registrar a decisão de canal**

Escrever o resultado em `skills/delegando-ancalagon/.p1-result` com UMA destas linhas:
```
WINDOWS_REBOOT_CMD="ssh <WIN_HOST> 'shutdown /r /t 0'"
```
ou (se P1 FAIL):
```
WINDOWS_REBOOT_CMD=""   # sem canal headless — preflight reporta ação física
```
Este valor preenche `reboot_windows_to_linux()` na Task 3, Step 4. **Sem placeholder:** o corpo do helper usa exatamente esta string.

---

## Task 3: `anc-delegate` — esqueleto + preflight em escada

**Files:**
- Create: `skills/delegando-ancalagon/anc-delegate`
- Test: smoke test contra o Ancalagon real

- [ ] **Step 1: Escrever o esqueleto com usage e constantes**

Create `skills/delegando-ancalagon/anc-delegate`:
```bash
#!/bin/bash
# anc-delegate — delega trabalho ao Ancalagon de forma headless (roda no Mac).
# Caminho 1 (gen): curl :1234, geração sem tools.
# Caminho 2 (iter): local-claude -p, Claude Code headless no Mac, inferência remota.
set -euo pipefail

REMOTE="${ANC_REMOTE:-Ancalagon_Ubuntu-Tailnet}"
HOST="${ANC_HOST:-ancalagon-ubuntu}"  # MagicDNS Tailscale (resolve dinâmico; sem IP hardcoded)
PORT="${ANC_PORT:-1234}"
WIN_HOST="${ANC_WIN_HOST:-ancalagon}" # nó Tailscale do Windows (MagicDNS)
WAKE_MAC="${ANC_WAKE_MAC:-10:7C:61:45:D8:38}"
DEFAULT_MODEL="coder"
BOOT_TIMEOUT=120                       # s para SSH-Linux voltar após WoL/reboot

usage() {
  cat <<EOF
Usage: anc-delegate <command> [args]

  preflight [--model M]              garante :$PORT saudável (escada SSH/WoL/reboot)
  gen  <briefing.md> [--model M]     geração one-shot via curl (sem tools)
  iter <briefing.md> [--cwd DIR] [--model M]
                                     iteração via local-claude -p (Claude Code + tools)
  health                             snapshot nvidia-smi + service ativo (JSON)

  --model {coder|qwen36|gemma4}      força um service (default: usa o ativo, senão coder)
EOF
  exit 1
}

log() { printf '%s\n' "$*" >&2; }

# --- helpers de estado remoto ---
ssh_linux() { ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE" "$@" 2>/dev/null; }

is_linux_up() { [[ "$(ssh_linux 'uname -s' || true)" == "Linux" ]]; }

active_service() {
  ssh_linux 'for s in llama-coder llama-qwen36 llama-gemma4; do
    systemctl --user is-active --quiet "$s.service" && echo "$s" && break
  done' || true
}

health_ok() { curl -fs -o /dev/null -m 5 "http://$HOST:$PORT/health" 2>/dev/null; }
```

- [ ] **Step 2: Adicionar `ensure_model` (sobe service só se preciso, nunca troca ativo)**

Append:
```bash
# Sobe um modelo apenas se nenhum service llama estiver ativo.
# Respeita o service já ativo (não troca). Default: coder.
ensure_model() {
  local want="$1"
  local cur; cur="$(active_service)"
  if [[ -n "$cur" ]]; then
    log "Service ativo: $cur (não troco)"
    health_ok && { log ":$PORT saudável"; return 0; }
    log "Service $cur ativo mas :$PORT não responde — reiniciando via lmswitch"
  fi
  local sub="${want:-$DEFAULT_MODEL}"
  log "Subindo $sub..."
  ssh_linux "/home/lucas/.local/bin/lmswitch $sub" >&2
  health_ok
}
```

- [ ] **Step 3: Adicionar WoL + espera de boot**

Append:
```bash
wake_and_wait() {
  log "Mandando magic packet WoL ($WAKE_MAC)..."
  wakeonlan "$WAKE_MAC" >/dev/null 2>&1 || log "WARN: wakeonlan falhou"
  log "Aguardando SSH-Linux voltar (até ${BOOT_TIMEOUT}s)..."
  local waited=0
  while (( waited < BOOT_TIMEOUT )); do
    is_linux_up && { log "Linux up."; return 0; }
    sleep 5; waited=$((waited+5)); printf '.' >&2
  done
  printf '\n' >&2
  return 1
}
```

- [ ] **Step 4: Adicionar `reboot_windows_to_linux` (corpo definido pela Task 2)**

Append — **preencher `WINDOWS_REBOOT_CMD` com o valor de `.p1-result`**:
```bash
# Definido pelo resultado do GATE P1 (Task 2): Windows tem OpenSSH ativo.
# NÃO-TESTADO até a máquina estar bootada no Windows (nó offline quando em Linux).
WINDOWS_REBOOT_CMD="ssh -o ConnectTimeout=5 ancalagon 'shutdown /r /t 0'"

reboot_windows_to_linux() {
  if [[ -z "$WINDOWS_REBOOT_CMD" ]]; then
    log "ERRO: Ancalagon parece estar no Windows e não há canal headless"
    log "      configurado. Ação física necessária (reboot manual -> Ubuntu)."
    return 2
  fi
  log "Detectado Windows — disparando reboot para Linux..."
  eval "$WINDOWS_REBOOT_CMD" || { log "Reboot via Windows falhou"; return 2; }
  wake_and_wait   # após reboot, GRUB cai no Ubuntu (default); espera SSH-Linux
}
```

- [ ] **Step 5: Adicionar `preflight` (a escada completa)**

Append:
```bash
preflight() {
  local model="${1:-}"

  # 1. Linux up?
  if is_linux_up; then
    ensure_model "$model" && return 0
    log "ERRO: Linux up mas :$PORT não ficou saudável"; return 1
  fi

  # 2. SSH-Linux mudo: suspenso/desligado OU Windows. Tenta WoL primeiro.
  log "SSH-Linux mudo — tentando WoL (suspenso/desligado?)..."
  if wake_and_wait; then
    ensure_model "$model" && return 0
    log "ERRO: acordou mas :$PORT não ficou saudável"; return 1
  fi

  # 3. WoL não trouxe o Linux: provavelmente bootado no Windows. Reboot.
  log "WoL não trouxe o Linux — verificando Windows..."
  if [[ -n "$WIN_HOST" ]] && ssh -o ConnectTimeout=5 -o BatchMode=yes "$WIN_HOST" 'exit' 2>/dev/null; then
    reboot_windows_to_linux || return $?
    ensure_model "$model" && return 0
    log "ERRO: pós-reboot :$PORT não ficou saudável"; return 1
  fi

  # 4. Inalcançável — reporta, não faz polling.
  log "ERRO: Ancalagon inalcançável (não-Linux, sem Windows headless, sem WoL)."
  log "      Ação física provável necessária. Não vou retentar em loop."
  return 2
}
```

- [ ] **Step 6: Adicionar dispatch de comandos (parse + case)**

Append:
```bash
# --- parse de --model / --cwd ---
MODEL=""; CWD="$PWD"
CMD="${1:-}"; shift || true
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --cwd)   CWD="$2"; shift 2 ;;
    *)       ARGS+=("$1"); shift ;;
  esac
done

case "$CMD" in
  preflight) preflight "$MODEL" ;;
  gen)       preflight "$MODEL" >&2 && gen "${ARGS[0]:?briefing.md requerido}" ;;
  iter)      preflight "$MODEL" >&2 && iter "${ARGS[0]:?briefing.md requerido}" "$CWD" ;;
  health)    health_snapshot ;;
  *)         usage ;;
esac
```
(As funções `gen`, `iter`, `health_snapshot` entram nas Tasks 4–6, antes do bloco de dispatch. Reordenar de forma que dispatch fique por último no arquivo.)

- [ ] **Step 7: shellcheck**

Run: `shellcheck skills/delegando-ancalagon/anc-delegate`
Expected: sem warnings. (Funções ainda-não-definidas `gen`/`iter`/`health_snapshot` darão erro de "command not found" só em runtime, não no shellcheck; mas para shellcheck passar, adicionar stubs temporários `gen(){ :; }` etc. que serão substituídos nas próximas tasks, OU implementar Tasks 4–6 antes de rodar o dispatch.)

- [ ] **Step 8: Smoke test do preflight (Ancalagon já no ar pela Task 1)**

Run: `chmod +x skills/delegando-ancalagon/anc-delegate && ANC_WIN_HOST=<WIN_HOST> skills/delegando-ancalagon/anc-delegate preflight`
Expected: detecta Linux up + service ativo, loga ":1234 saudável", exit 0.

- [ ] **Step 9: Commit**

```bash
git add skills/delegando-ancalagon/anc-delegate
git commit -m "feat(skill): anc-delegate preflight em escada (SSH/WoL/reboot)"
```

---

## Task 4: `anc-delegate gen` — Caminho 1 (curl)

**Files:**
- Modify: `skills/delegando-ancalagon/anc-delegate` (adicionar função `gen` antes do dispatch)

- [ ] **Step 1: Implementar `gen`**

Inserir antes do bloco de dispatch:
```bash
# Caminho 1: geração one-shot via curl OpenAI-compat. Sem tools.
gen() {
  local briefing_file="$1"
  [[ -f "$briefing_file" ]] || { log "briefing não encontrado: $briefing_file"; return 1; }
  local prompt; prompt="$(cat "$briefing_file")"
  # Guard-rail do spec: briefing grande = recorte ruim.
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
  curl -sf -m 600 "http://$HOST:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$payload" \
  | jq -r '.choices[0].message.content'
}
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck skills/delegando-ancalagon/anc-delegate`
Expected: sem warnings.

- [ ] **Step 3: Smoke test com briefing mínimo**

Run:
```bash
printf '# Tarefa\nEscreva uma função Python add(a,b) que retorna a soma. Só o código.\n' > /tmp/brief.md
skills/delegando-ancalagon/anc-delegate gen /tmp/brief.md
```
Expected: imprime uma função `def add(a, b): return a + b` (ou equivalente). Preflight roda antes e confirma :1234.

- [ ] **Step 4: Commit**

```bash
git add skills/delegando-ancalagon/anc-delegate
git commit -m "feat(skill): anc-delegate gen (Caminho 1, curl one-shot)"
```

---

## Task 5: `anc-delegate iter` — Caminho 2 (local-claude -p)

**Depende de P0 PASS (Task 1).** Se P0 falhou, não implementar — revisar spec.

**Files:**
- Modify: `skills/delegando-ancalagon/anc-delegate` (adicionar função `iter`)

- [ ] **Step 1: Implementar `iter`**

Inserir antes do dispatch:
```bash
# Caminho 2: Claude Code headless no Mac (tools reais), inferência remota.
iter() {
  local briefing_file="$1"; local cwd="$2"
  [[ -f "$briefing_file" ]] || { log "briefing não encontrado: $briefing_file"; return 1; }
  [[ -d "$cwd" ]] || { log "cwd inválido: $cwd"; return 1; }
  local prompt; prompt="$(cat "$briefing_file")"
  log "Disparando Claude Code headless em $cwd (inferência no Ancalagon)..."
  ( cd "$cwd" && \
    local-claude --backend remote --host "$HOST" --port "$PORT" \
      -p "$prompt" --output-format json )
}
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck skills/delegando-ancalagon/anc-delegate`
Expected: sem warnings.

- [ ] **Step 3: Smoke test num repo descartável**

Run:
```bash
TMP=$(mktemp -d); git -C "$TMP" init -q
printf '# Tarefa\nCrie um arquivo hello.txt com o conteúdo "oi". Use suas tools.\n' > /tmp/brief-iter.md
skills/delegando-ancalagon/anc-delegate iter /tmp/brief-iter.md --cwd "$TMP"
ls "$TMP"/hello.txt && cat "$TMP"/hello.txt
```
Expected: `hello.txt` existe com `oi`; o helper retorna o JSON de resumo do `claude -p`. **Isto confirma o Caminho 2 ponta-a-ponta (tools no Mac + inferência remota).**

- [ ] **Step 4: Commit**

```bash
git add skills/delegando-ancalagon/anc-delegate
git commit -m "feat(skill): anc-delegate iter (Caminho 2, local-claude -p headless)"
```

---

## Task 6: `anc-delegate health` — snapshot

**Files:**
- Modify: `skills/delegando-ancalagon/anc-delegate` (adicionar `health_snapshot`)

- [ ] **Step 1: Implementar `health_snapshot`**

Inserir antes do dispatch:
```bash
# Snapshot de saúde: service ativo + nvidia-smi (temp/power/throttle).
health_snapshot() {
  local svc; svc="$(active_service)"
  local smi
  smi="$(ssh_linux 'nvidia-smi --query-gpu=temperature.gpu,temperature.memory,power.draw,clocks_throttle_reasons.active --format=csv,noheader,nounits' || echo "NA,NA,NA,NA")"
  IFS=',' read -r gtemp mtemp power throttle <<< "$smi"
  jq -n --arg svc "${svc:-none}" --arg health "$(health_ok && echo ok || echo down)" \
        --arg gt "${gtemp// /}" --arg mt "${mtemp// /}" \
        --arg pw "${power// /}" --arg th "${throttle// /}" \
    '{service:$svc, port_health:$health, gpu_temp_c:$gt, mem_temp_c:$mt, power_w:$pw, throttle:$th}'
}
```

- [ ] **Step 2: shellcheck + smoke**

Run: `shellcheck skills/delegando-ancalagon/anc-delegate && skills/delegando-ancalagon/anc-delegate health`
Expected: JSON com `service`, `port_health`, `gpu_temp_c`, `power_w`, `throttle`.

- [ ] **Step 3: Commit**

```bash
git add skills/delegando-ancalagon/anc-delegate
git commit -m "feat(skill): anc-delegate health (snapshot nvidia-smi)"
```

---

## Task 7: `SKILL.md` — instruções para o Claude

**Files:**
- Create: `skills/delegando-ancalagon/SKILL.md`

- [ ] **Step 1: Escrever o SKILL.md**

Create `skills/delegando-ancalagon/SKILL.md`:
```markdown
---
name: delegando-ancalagon
description: Use quando quiser terceirizar trabalho de código ao Ancalagon (LLM local) para economizar tokens do Claude Code cloud — gerar boilerplate/testes/conversões (Caminho 1) ou tarefas que precisam rodar e iterar com tools como "faça os testes passarem" (Caminho 2). Headless, o Claude orquestra de ponta a ponta.
---

# Delegando para o Ancalagon (headless)

Terceiriza trabalho ao Ancalagon (RTX 4070 Ti SUPER, llama.cpp na :1234) para
poupar os output tokens caros do cloud. Charter completo em
`~/git/apps_mac/ancalagon-llm/docs/delegation.md`.

Helper: `~/.claude/skills/delegando-ancalagon/anc-delegate` (instalado por
`make install-skill`). Configurar o nó Windows: `export ANC_WIN_HOST=<nó>`.

## Quando NÃO delegar
Decisões arquiteturais, cross-repo, PRs, julgamento — ficam no cloud. O Ancalagon
é executor, não arquiteto. Ver "Quando NÃO delegar" em delegation.md.

## Escolha do caminho
- **Caminho 1 (`gen`)** — spec fechada → código/texto, **nada a executar**:
  boilerplate, suíte de testes para código definido, conversão A→B, refactor
  mecânico. Você monta briefing, o Ancalagon gera, **você aplica e revisa o diff**.
- **Caminho 2 (`iter`)** — precisa **rodar/verificar/iterar**: "faça os testes
  passarem", lint que corrige, debugging com ciclo. Um Claude Code headless roda
  no Mac (tools reais), inferência no Ancalagon. Ele edita/roda sozinho; você lê
  o resumo + `git diff`.

## Procedimento
1. Monte um **briefing autocontido** (formato em delegation.md: contexto do
   projeto, decisões já tomadas, arquivos relevantes inline, critério de pronto).
   Salve em arquivo temporário.
2. Caminho 1: `anc-delegate gen <briefing.md>` → recebe o texto → você aplica via
   Edit/Write → mostre o diff.
   Caminho 2: `anc-delegate iter <briefing.md> --cwd <repo>` → o agente edita →
   você roda `git diff` e revisa.
3. O `anc-delegate` faz o **preflight** sozinho (liga/acorda/sobe modelo). Se ele
   retornar erro de indisponibilidade, **reporte ao Lucas na hora** com o sintoma
   — não retente em loop (regra de delegation.md).

## Guard-rails
- Briefing > 40K tokens = recorte ruim. Pare e re-planeje (o helper também aborta).
- Nunca desligue o service depois (deixe para o Lucas via `lloff`).
- Modelo: default `coder`. Use `--model qwen36` para tarefas que pedem reasoning.
- Se o `anc-delegate` reportar corte térmico (gpu-guard parou o service), pare e
  reporte — não retente.
```

- [ ] **Step 2: Verificar frontmatter (name + description presentes)**

Run: `head -5 skills/delegando-ancalagon/SKILL.md`
Expected: bloco YAML com `name:` e `description:`.

- [ ] **Step 3: Commit**

```bash
git add skills/delegando-ancalagon/SKILL.md
git commit -m "feat(skill): SKILL.md de delegando-ancalagon"
```

---

## Task 8: `make install-skill`

**Files:**
- Modify: `Makefile` (linha 3 `.PHONY` e novo target após `install-gla`)

- [ ] **Step 1: Adicionar ao `.PHONY`**

Modify `Makefile:3` — acrescentar `install-skill`:
```makefile
.PHONY: install install-system install-gla install-skill wake status coder qwen36 gemma4 off sleep logs video-off video-on video-status bootwin bootwin-dry
```

- [ ] **Step 2: Adicionar o target (após `install-gla`, antes de `wake`)**

Insert após a linha 18:
```makefile
install-skill:
	@mkdir -p $(HOME)/.claude/skills
	@chmod +x $(CURDIR)/skills/delegando-ancalagon/anc-delegate
	@ln -sfn $(CURDIR)/skills/delegando-ancalagon $(HOME)/.claude/skills/delegando-ancalagon
	@echo "installed: $(HOME)/.claude/skills/delegando-ancalagon -> $(CURDIR)/skills/delegando-ancalagon"
```

- [ ] **Step 3: Rodar e verificar o symlink**

Run: `make install-skill && ls -l ~/.claude/skills/delegando-ancalagon`
Expected: symlink apontando para o repo; `anc-delegate` executável.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: make install-skill (symlink da skill delegando-ancalagon)"
```

---

## Task 9: `gpu-guard` — watchdog térmico (script)

**Files:**
- Create: `bin/gpu-guard`

Limites iniciais **conservadores** (calibrados de verdade na Task 11). Baseados no
TUNING.md: regime normal do qwen36 = 292W/96%/temp a medir; Tjmax ~88–90 °C.

- [ ] **Step 1: Escrever o `gpu-guard`**

Create `bin/gpu-guard`:
```bash
#!/bin/bash
# gpu-guard — watchdog térmico para a RTX 4070 Ti SUPER no Ancalagon.
# Polling de nvidia-smi; escalonado: warning loga, critical sustentado corta o
# service llama ativo. Proxy temp+throttle (sem sensor de conector 12VHPWR).
set -euo pipefail

INTERVAL="${GPU_GUARD_INTERVAL:-5}"        # s entre leituras
WARN_TEMP="${GPU_GUARD_WARN_TEMP:-78}"     # °C — loga
CRIT_TEMP="${GPU_GUARD_CRIT_TEMP:-84}"     # °C — candidato a corte
HOLD="${GPU_GUARD_HOLD:-30}"               # s de critical sustentado p/ cortar
STATE="/run/gpu-guard.state"

log() { printf '%s gpu-guard: %s\n' "$(date -Is)" "$*"; }

crit_since=0

active_llama() {
  for s in llama-coder llama-qwen36 llama-gemma4; do
    systemctl --user is-active --quiet "$s.service" && { echo "$s"; return; }
  done
}

while true; do
  read -r temp throttle < <(nvidia-smi \
    --query-gpu=temperature.gpu,clocks_throttle_reasons.active \
    --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | tr ',' ' ')
  temp="${temp:-0}"
  now=$(date +%s)

  if (( temp >= CRIT_TEMP )); then
    (( crit_since == 0 )) && crit_since=$now
    held=$(( now - crit_since ))
    printf 'CRITICAL temp=%s°C held=%ss throttle=%s\n' "$temp" "$held" "$throttle" > "$STATE"
    if (( held >= HOLD )); then
      svc="$(active_llama || true)"
      log "CRITICAL sustentado ${held}s a ${temp}°C — parando ${svc:-nenhum}"
      [[ -n "$svc" ]] && systemctl --user stop "$svc.service"
      crit_since=0
    fi
  elif (( temp >= WARN_TEMP )); then
    crit_since=0
    printf 'WARN temp=%s°C throttle=%s\n' "$temp" "$throttle" > "$STATE"
    log "WARN temp=${temp}°C throttle=${throttle}"
  else
    crit_since=0
    printf 'OK temp=%s°C\n' "$temp" > "$STATE"
  fi
  sleep "$INTERVAL"
done
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck bin/gpu-guard`
Expected: sem warnings.

- [ ] **Step 3: Smoke test manual no Ancalagon (10s, modelo já no ar)**

Run:
```bash
scp bin/gpu-guard Ancalagon_Ubuntu-Tailnet:/tmp/gpu-guard
ssh Ancalagon_Ubuntu-Tailnet 'chmod +x /tmp/gpu-guard; timeout 12 /tmp/gpu-guard; echo "---"; cat /run/gpu-guard.state'
```
Expected: loga linhas periódicas; `/run/gpu-guard.state` contém `OK temp=NN°C` (idle deve estar bem abaixo de 78 °C).

- [ ] **Step 4: Commit**

```bash
git add bin/gpu-guard
git commit -m "feat: gpu-guard watchdog térmico (escalonado, proxy temp+throttle)"
```

---

## Task 10: `gpu-guard.service` — unit systemd

**Files:**
- Create: `systemd/gpu-guard.service`

- [ ] **Step 1: Escrever a unit**

Create `systemd/gpu-guard.service`:
```ini
[Unit]
Description=GPU thermal watchdog (RTX 4070 Ti SUPER) — proxy temp+throttle
After=default.target

[Service]
Type=simple
ExecStart=%h/.local/bin/gpu-guard
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

- [ ] **Step 2: Validar sintaxe (no Mac, lint básico)**

Run: `grep -E '^(Description|ExecStart|WantedBy)=' systemd/gpu-guard.service`
Expected: as três linhas presentes. (Validação real do systemd ocorre no deploy, Task 11.)

- [ ] **Step 3: Commit**

```bash
git add systemd/gpu-guard.service
git commit -m "feat: gpu-guard.service (user unit, persistente)"
```

---

## Task 11: Deploy do watchdog + calibração empírica dos limites

**Files:**
- Modify: `scripts/setup-system.sh` (instalar gpu-guard + service)
- Modify: `Makefile` (`install-system` já chama setup-system.sh — sem mudança se o script cobrir)

- [ ] **Step 1: Estender `setup-system.sh` para instalar o gpu-guard**

Append antes do `echo "Done..."` final (linha ~50):
```bash
echo ""
echo "→ Instalando gpu-guard (watchdog térmico)..."
install -m 0755 "$REPO_DIR/bin/gpu-guard" "$HOME/.local/bin/gpu-guard"
install -d "$HOME/.config/systemd/user"
install -m 0644 "$REPO_DIR/systemd/gpu-guard.service" "$HOME/.config/systemd/user/gpu-guard.service"
systemctl --user daemon-reload
systemctl --user enable --now gpu-guard.service
systemctl --user is-active gpu-guard.service && echo "  gpu-guard ativo"
```
Nota: `setup-system.sh` roda via `make install-system` que faz scp do repo para `/tmp/ancalagon-system` — **incluir `bin/gpu-guard` e `systemd/gpu-guard.service` no scp** (próximo step).

- [ ] **Step 2: Atualizar o scp do `install-system` no Makefile**

Modify `Makefile` target `install-system` (linhas 8–12) para enviar os novos arquivos:
```makefile
install-system:
	@ssh $(REMOTE) 'mkdir -p /tmp/ancalagon-system/systemd /tmp/ancalagon-system/scripts /tmp/ancalagon-system/bin'
	@scp systemd/99-wol.yaml systemd/console-setup systemd/gpu-guard.service $(REMOTE):/tmp/ancalagon-system/systemd/
	@scp bin/gpu-guard $(REMOTE):/tmp/ancalagon-system/bin/
	@scp scripts/setup-system.sh $(REMOTE):/tmp/ancalagon-system/scripts/
	@ssh $(REMOTE) 'bash /tmp/ancalagon-system/scripts/setup-system.sh'
```
Atenção: `setup-system.sh` usa `$REPO_DIR="$(dirname $0)/.."` = `/tmp/ancalagon-system`. Os paths `bin/gpu-guard` e `systemd/gpu-guard.service` batem com o scp acima.

- [ ] **Step 3: Deploy**

Run: `make install-system`
Expected: termina com `gpu-guard ativo`.

- [ ] **Step 4: Calibração — medir regime sustentado de cada modelo**

Para cada modelo, subir e medir temp/power em carga real (~2 min de geração):
```bash
ssh Ancalagon_Ubuntu-Tailnet /home/lucas/.local/bin/lmswitch qwen36   # maior consumo (292W)
# disparar carga sustentada e amostrar:
ssh Ancalagon_Ubuntu-Tailnet 'for i in $(seq 1 24); do nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks_throttle_reasons.active --format=csv,noheader,nounits; sleep 5; done'
```
Expected: registrar a temp de pico em regime. **Calibrar `GPU_GUARD_WARN_TEMP`/`CRIT_TEMP`/`HOLD`** para ficar acima do pico normal mas abaixo do Tjmax (~88–90 °C). Ajustar os defaults no `bin/gpu-guard` e em `benchmarks/TUNING.md`.

- [ ] **Step 5: Re-deploy com limites calibrados + commit**

```bash
make install-system
git add bin/gpu-guard scripts/setup-system.sh Makefile benchmarks/TUNING.md
git commit -m "feat: deploy gpu-guard + limites térmicos calibrados empiricamente"
```

---

## Task 12: Documentação

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/delegation.md`, `AI_CONTEXT.md`

- [ ] **Step 1: Atualizar `docs/delegation.md`**

Adicionar seção "Delegação headless via skill" apontando para `anc-delegate` (os dois caminhos) e referenciando a SKILL.md. Documentar `ANC_WIN_HOST`.

- [ ] **Step 2: Atualizar `CLAUDE.md`**

No Layout, adicionar `skills/delegando-ancalagon/` e `systemd/gpu-guard.service` + `bin/gpu-guard`. Em Decisões de design, registrar D5–D8 (gpu-guard enabled, escalonado, proxy temp+throttle). No bloco de make targets, adicionar `make install-skill`.

- [ ] **Step 3: Atualizar `README.md` e `AI_CONTEXT.md`**

Mencionar o gpu-guard na tabela de artefatos e a skill como caminho de delegação headless.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md docs/delegation.md AI_CONTEXT.md benchmarks/TUNING.md
git commit -m "docs: skill delegando-ancalagon + gpu-guard"
```

---

## Self-Review (preenchido)

**Spec coverage:**
- Caminho 1 → Task 4. Caminho 2 → Task 5. Heurística → Task 7 (SKILL.md). ✓
- Preflight escada (SSH/WoL/reboot/reporta) → Task 3. ✓
- Política de service (não troca, default coder, nunca desliga) → Task 3 (`ensure_model`) + Task 7. ✓
- Watchdog escalonado proxy temp+throttle → Tasks 9–11. ✓
- gpu-guard enabled persistente → Task 11 (`enable --now`). ✓
- Premissas P0/P1/P2 → Tasks 1, 2, e P2 documentada em Task 7/9 (sem sensor de conector). ✓
- install-skill / install-system estendido → Tasks 8, 11. ✓
- Guard-rail 40K tokens → Task 4 (`gen`) + Task 7. ✓

**Placeholder scan:** `WINDOWS_REBOOT_CMD` na Task 3 é preenchido pelo artefato concreto da Task 2 (`.p1-result`), não é placeholder solto. Limites do gpu-guard têm defaults concretos na Task 9 e são recalibrados na Task 11. ✓

**Type consistency:** funções referenciadas no dispatch (Task 3 Step 6) — `gen` (Task 4), `iter` (Task 5), `health_snapshot` (Task 6), `preflight`/`ensure_model`/`active_service`/`health_ok`/`ssh_linux` (Task 3) — todas definidas. Nomes batem. Ordem de arquivo: definições antes do dispatch (nota na Task 3 Step 6 e Step 7). ✓

**Risco residual:** P0 (Task 1 Step 4) é o maior — se o backend `remote` do `local-claude` não fizer a ponte Anthropic↔OpenAI, Task 5 precisa de um proxy. Por isso é um GATE explícito antes de qualquer código do Caminho 2.
