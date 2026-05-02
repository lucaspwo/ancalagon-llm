# `gla` Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar wrapper único `gla <model>` que sobe um backend LLM local (MLX ou llama.cpp) com mutex de portas, reescreve `opencode.json` com o modelo escolhido e abre o TUI do opencode. Renomear aliases `glau_*` → `gla_*` no `.zshrc` para simetria com `anc_*`.

**Architecture:** Script bash de ~150 linhas em `clients/glaurung-llm/gla`, instalado como symlink em `~/.local/bin/gla`. Mutex via `lsof` nas portas 1235 (llama.cpp) e 1236 (MLX). Reescrita atômica do `opencode.json` via `jq` + `mv`. Sem testes automatizados — smoke tests manuais determinísticos por task.

**Tech Stack:** bash 5+, lsof, curl, jq, opencode 1.14+, mlx_lm.server, llama.cpp Metal build.

**Spec de referência:** `docs/superpowers/specs/2026-05-01-gla-wrapper-design.md`

---

## File Structure

| Arquivo | Responsabilidade |
|---|---|
| `clients/glaurung-llm/gla` (novo) | Script único: parse args → mutex → start backend → wait_ready → set opencode model → exec opencode |
| `Makefile` (modificar) | Novo target `install-gla` (symlink em `~/.local/bin/gla`) |
| `~/.zshrc` linhas 283-362 (modificar) | Rename `glau_*` → `gla_*` (15 identificadores + 2 paths de log) |

Não há testes automatizados. Cada task tem comando de validação + expected output.

---

### Task 1: Skeleton do script com parser de argumentos

**Files:**
- Create: `clients/glaurung-llm/gla`

- [ ] **Step 1: Criar o script com header e parser**

```bash
mkdir -p /Users/lucas/git/apps_mac/ancalagon-llm/clients/glaurung-llm
cat > /Users/lucas/git/apps_mac/ancalagon-llm/clients/glaurung-llm/gla <<'EOF'
#!/usr/bin/env bash
# gla — wrapper único: sobe backend LLM local + abre opencode com modelo selecionado.
# Spec: docs/superpowers/specs/2026-05-01-gla-wrapper-design.md
set -euo pipefail

readonly LCPP_PORT=1235
readonly MLX_PORT=1236
readonly LCPP_LOG=/tmp/gla-lcpp.log
readonly MLX_LOG=/tmp/gla-mlx.log
readonly LCPP_BIN="$HOME/git/llama.cpp/build/bin/llama-server"
readonly MLX_BIN="$HOME/.venvs/mlx/bin/mlx_lm.server"
readonly LCPP_QWEN="$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q4_K_M.gguf"
readonly LCPP_GEMMA="$HOME/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf"
readonly OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"

usage() {
  cat <<USAGE
gla — single-command LLM backend + opencode launcher (Glaurung)

Usage: gla <command>

Models (sobe backend + abre opencode com modelo selecionado):
  gemma4        MLX (default), porta $MLX_PORT
  qwen36        MLX (default), porta $MLX_PORT
  gemma4-lcpp   llama.cpp Metal, porta $LCPP_PORT
  qwen36-lcpp   llama.cpp Metal, porta $LCPP_PORT

Utilities:
  off           mata backends nas portas $LCPP_PORT + $MLX_PORT (não abre opencode)
  status        mostra estado dos dois backends
  -h, --help    esta mensagem
USAGE
}

cmd="${1:-}"
case "$cmd" in
  gemma4|qwen36|gemma4-lcpp|qwen36-lcpp)
    echo "[gla] would start: $cmd (not implemented yet)"
    ;;
  off)
    echo "[gla] would kill backends (not implemented yet)"
    ;;
  status)
    echo "[gla] would show status (not implemented yet)"
    ;;
  -h|--help|"")
    usage
    [ -z "$cmd" ] && exit 1 || exit 0
    ;;
  *)
    echo "[gla] unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
EOF
chmod +x /Users/lucas/git/apps_mac/ancalagon-llm/clients/glaurung-llm/gla
```

- [ ] **Step 2: Validar parser**

Run:
```bash
cd /Users/lucas/git/apps_mac/ancalagon-llm
./clients/glaurung-llm/gla
echo "---"
./clients/glaurung-llm/gla gemma4
./clients/glaurung-llm/gla off
./clients/glaurung-llm/gla foo; echo "exit=$?"
```

Expected:
- Sem arg → imprime usage, sai 1
- `gemma4` → imprime `[gla] would start: gemma4 (not implemented yet)`, sai 0
- `off` → imprime `[gla] would kill backends (not implemented yet)`
- `foo` → erro stderr + usage, sai 1

- [ ] **Step 3: Commit**

```bash
cd /Users/lucas/git/apps_mac/ancalagon-llm
git add clients/glaurung-llm/gla
git commit -m "feat(gla): skeleton with argument parser and usage

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Helpers de mutex (kill por porta)

**Files:**
- Modify: `clients/glaurung-llm/gla`

- [ ] **Step 1: Adicionar `_pids_on_port`, `_kill_port`, `_wait_port_free`, `_mutex` antes do `usage()`**

Edit `clients/glaurung-llm/gla` — inserir entre o bloco `readonly` e a função `usage()`:

```bash
_pids_on_port() {
  lsof -tnP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
}

_kill_port() {
  local port="$1"
  local pids
  pids=$(_pids_on_port "$port")
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 1
    pids=$(_pids_on_port "$port")
    if [ -n "$pids" ]; then
      # shellcheck disable=SC2086
      kill -9 $pids 2>/dev/null || true
    fi
  fi
}

_wait_port_free() {
  local port="$1"
  local i
  for i in 1 2 3 4 5; do
    [ -z "$(_pids_on_port "$port")" ] && return 0
    sleep 1
  done
  echo "[gla] port $port still busy after 5s (PIDs: $(_pids_on_port "$port"))" >&2
  return 1
}

_mutex() {
  _kill_port "$LCPP_PORT"
  _kill_port "$MLX_PORT"
  _wait_port_free "$LCPP_PORT" || return 1
  _wait_port_free "$MLX_PORT" || return 1
}
```

- [ ] **Step 2: Validar com servidor fake**

Run (em duas etapas):
```bash
# Sobe um nc na 1235 simulando backend
nc -l 1235 &
NC_PID=$!
sleep 1
lsof -tnP -iTCP:1235 -sTCP:LISTEN

# Chama _mutex via subshell (precisa source pra acessar funções)
bash -c 'source <(sed -n "1,/^usage/p" /Users/lucas/git/apps_mac/ancalagon-llm/clients/glaurung-llm/gla | head -n -1) && _mutex && echo "mutex OK"'

# Confirma que porta liberou
lsof -tnP -iTCP:1235 -sTCP:LISTEN || echo "port 1235 free"
wait $NC_PID 2>/dev/null || true
```

Expected:
- Antes do mutex: `lsof` retorna PID do nc
- Depois: `mutex OK` + `port 1235 free`

- [ ] **Step 3: Commit**

```bash
git add clients/glaurung-llm/gla
git commit -m "feat(gla): port mutex (kill+wait on 1235/1236)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Helpers de start backend + wait_ready

**Files:**
- Modify: `clients/glaurung-llm/gla`

- [ ] **Step 1: Adicionar funções `_start_lcpp_qwen36`, `_start_lcpp_gemma4`, `_start_mlx`, `_wait_ready` após o `_mutex`**

Edit — inserir antes da `usage()`:

```bash
_start_lcpp_qwen36() {
  [ -x "$LCPP_BIN" ] || { echo "[gla] llama-server não encontrado em $LCPP_BIN" >&2; return 1; }
  [ -f "$LCPP_QWEN" ] || { echo "[gla] modelo Qwen36 GGUF não encontrado em $LCPP_QWEN" >&2; return 1; }
  nohup "$LCPP_BIN" -m "$LCPP_QWEN" \
    --host 127.0.0.1 --port "$LCPP_PORT" \
    -c 49152 -np 1 -ngl 99 -fa on \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    --no-mmap --jinja --alias qwen36 \
    > "$LCPP_LOG" 2>&1 &
  disown
}

_start_lcpp_gemma4() {
  [ -x "$LCPP_BIN" ] || { echo "[gla] llama-server não encontrado em $LCPP_BIN" >&2; return 1; }
  [ -f "$LCPP_GEMMA" ] || { echo "[gla] modelo Gemma4 GGUF não encontrado em $LCPP_GEMMA" >&2; return 1; }
  nohup "$LCPP_BIN" -m "$LCPP_GEMMA" \
    --host 127.0.0.1 --port "$LCPP_PORT" \
    -c 81920 -np 1 -ngl 99 -fa on \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    --no-mmap --jinja --alias gemma4 \
    > "$LCPP_LOG" 2>&1 &
  disown
}

_start_mlx() {
  [ -x "$MLX_BIN" ] || { echo "[gla] mlx_lm.server não encontrado em $MLX_BIN" >&2; return 1; }
  nohup "$MLX_BIN" --host 127.0.0.1 --port "$MLX_PORT" --log-level INFO \
    > "$MLX_LOG" 2>&1 &
  disown
}

_wait_ready() {
  local port="$1"
  local timeout="${2:-30}"
  local i
  for i in $(seq 1 "$timeout"); do
    if curl -sf --max-time 2 "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "[gla] backend on :$port not ready after ${timeout}s — see log" >&2
  return 1
}
```

- [ ] **Step 2: Validar start + wait_ready com MLX (mais leve para teste isolado)**

Run:
```bash
# Carrega só as constantes e funções, sem dispatch
source <(sed -n '1,/^usage/p' /Users/lucas/git/apps_mac/ancalagon-llm/clients/glaurung-llm/gla | head -n -1)

_kill_port "$MLX_PORT"
_start_mlx
echo "started, waiting..."
_wait_ready "$MLX_PORT" 30 && echo "MLX READY"
curl -s http://127.0.0.1:$MLX_PORT/v1/models | python3 -m json.tool | head -10
_kill_port "$MLX_PORT"
```

Expected: `started, waiting...` → após ≤5s `MLX READY` → JSON com objeto `{"object":"list","data":[...]}` → porta liberada.

Se `_start_mlx` falhar com "não encontrado", instalar o MLX é pré-requisito do repo (ver TUNING.md §MLX). Não bloqueia o plano — corrigir e re-testar.

- [ ] **Step 3: Commit**

```bash
git add clients/glaurung-llm/gla
git commit -m "feat(gla): backend launchers (mlx, lcpp-qwen36, lcpp-gemma4) + ready poll

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Reescrita atômica do opencode.json

**Files:**
- Modify: `clients/glaurung-llm/gla`

- [ ] **Step 1: Adicionar função `_set_opencode_model`**

Edit — inserir após `_wait_ready`:

```bash
_set_opencode_model() {
  local model_id="$1"
  [ -f "$OPENCODE_CONFIG" ] || { echo "[gla] $OPENCODE_CONFIG não existe" >&2; return 1; }
  command -v jq >/dev/null || { echo "[gla] jq não está no PATH" >&2; return 1; }
  local tmp="${OPENCODE_CONFIG}.tmp.$$"
  if ! jq --arg m "$model_id" '.model = $m' "$OPENCODE_CONFIG" > "$tmp"; then
    rm -f "$tmp"
    echo "[gla] jq falhou ao processar $OPENCODE_CONFIG" >&2
    return 1
  fi
  mv "$tmp" "$OPENCODE_CONFIG"
}
```

- [ ] **Step 2: Validar com modelo dummy e revert manual**

Run:
```bash
source <(sed -n '1,/^usage/p' /Users/lucas/git/apps_mac/ancalagon-llm/clients/glaurung-llm/gla | head -n -1)

# Backup
cp ~/.config/opencode/opencode.json /tmp/opencode.json.bak

# Antes
echo "ANTES:"; jq '.model // "none"' ~/.config/opencode/opencode.json

# Aplica
_set_opencode_model "glaurung/gemma4" && echo "set OK"

# Depois
echo "DEPOIS:"; jq '.model' ~/.config/opencode/opencode.json

# Restaura
mv /tmp/opencode.json.bak ~/.config/opencode/opencode.json
echo "RESTAURADO:"; jq '.model // "none"' ~/.config/opencode/opencode.json
```

Expected:
- ANTES: `null` ou modelo anterior (string)
- `set OK`
- DEPOIS: `"glaurung/gemma4"`
- RESTAURADO: valor original

- [ ] **Step 3: Commit**

```bash
git add clients/glaurung-llm/gla
git commit -m "feat(gla): atomic opencode.json model rewrite via jq

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Comandos `off` e `status`

**Files:**
- Modify: `clients/glaurung-llm/gla`

- [ ] **Step 1: Adicionar funções `cmd_off` e `cmd_status`**

Edit — inserir antes do bloco `case "$cmd"`:

```bash
cmd_off() {
  _kill_port "$LCPP_PORT"
  _kill_port "$MLX_PORT"
  echo "[gla] :$LCPP_PORT + :$MLX_PORT killed"
}

_status_port() {
  local port="$1" label="$2"
  if [ -n "$(_pids_on_port "$port")" ]; then
    echo "=== :$port ($label) UP ==="
    curl -s --max-time 3 "http://127.0.0.1:$port/v1/models" 2>/dev/null \
      | python3 -m json.tool 2>/dev/null | head -15 \
      || echo "(no /v1/models response)"
  else
    echo "=== :$port ($label) DOWN ==="
  fi
}

cmd_status() {
  _status_port "$LCPP_PORT" "llama.cpp"
  echo
  _status_port "$MLX_PORT" "mlx_lm"
}
```

- [ ] **Step 2: Plugar no dispatch — substituir os ramos `off` e `status` no `case`**

Edit — no bloco `case "$cmd"`, trocar:

```bash
  off)
    echo "[gla] would kill backends (not implemented yet)"
    ;;
  status)
    echo "[gla] would show status (not implemented yet)"
    ;;
```

por:

```bash
  off)
    cmd_off
    ;;
  status)
    cmd_status
    ;;
```

- [ ] **Step 3: Validar `off` e `status`**

Run:
```bash
cd /Users/lucas/git/apps_mac/ancalagon-llm
./clients/glaurung-llm/gla off
./clients/glaurung-llm/gla status
```

Expected:
- `off` → `[gla] :1235 + :1236 killed`
- `status` → duas seções, ambas DOWN

- [ ] **Step 4: Commit**

```bash
git add clients/glaurung-llm/gla
git commit -m "feat(gla): off and status subcommands

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Comando principal — integração + exec opencode

**Files:**
- Modify: `clients/glaurung-llm/gla`

- [ ] **Step 1: Adicionar função `cmd_run`**

Edit — inserir após `cmd_status`:

```bash
cmd_run() {
  local choice="$1"
  local backend port model_id starter

  case "$choice" in
    gemma4)      backend=mlx;  port=$MLX_PORT;  starter=_start_mlx;          model_id="glaurung-mlx/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit" ;;
    qwen36)      backend=mlx;  port=$MLX_PORT;  starter=_start_mlx;          model_id="glaurung-mlx/mlx-community/Qwen3.6-27B-4bit" ;;
    gemma4-lcpp) backend=lcpp; port=$LCPP_PORT; starter=_start_lcpp_gemma4;  model_id="glaurung/gemma4" ;;
    qwen36-lcpp) backend=lcpp; port=$LCPP_PORT; starter=_start_lcpp_qwen36;  model_id="glaurung/qwen36" ;;
    *) echo "[gla] internal: cmd_run com choice inválido: $choice" >&2; return 1 ;;
  esac

  command -v opencode >/dev/null || { echo "[gla] opencode não está no PATH" >&2; return 1; }

  echo "[gla] mutex: matando :$LCPP_PORT + :$MLX_PORT…"
  _mutex

  echo "[gla] start: $backend (modelo opencode: $model_id) — log: $( [ "$backend" = mlx ] && echo "$MLX_LOG" || echo "$LCPP_LOG" )"
  "$starter"

  echo "[gla] aguardando :$port responder /v1/models…"
  if ! _wait_ready "$port" 60; then
    _kill_port "$port"
    return 1
  fi

  echo "[gla] gravando model em $OPENCODE_CONFIG…"
  _set_opencode_model "$model_id"

  echo "[gla] abrindo opencode (model=$model_id)…"
  exec opencode
}
```

- [ ] **Step 2: Plugar no dispatch — substituir o ramo dos modelos**

Edit — no bloco `case "$cmd"`, trocar:

```bash
  gemma4|qwen36|gemma4-lcpp|qwen36-lcpp)
    echo "[gla] would start: $cmd (not implemented yet)"
    ;;
```

por:

```bash
  gemma4|qwen36|gemma4-lcpp|qwen36-lcpp)
    cmd_run "$cmd"
    ;;
```

- [ ] **Step 3: Smoke test E2E (MLX, mais leve)**

Run em terminal interativo (porque vai abrir o opencode TUI):
```bash
cd /Users/lucas/git/apps_mac/ancalagon-llm
./clients/glaurung-llm/gla off  # garantir estado limpo
./clients/glaurung-llm/gla gemma4
```

Expected:
- Sequência de mensagens: `mutex` → `start: mlx` → `aguardando :1236` (≤5s) → `gravando model` → `abrindo opencode`
- TUI do opencode abre
- Bottom-bar mostra `glaurung-mlx/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit` selecionado
- Sair com `Ctrl-C` ou `:q`

Após sair:
```bash
./clients/glaurung-llm/gla status
```

Expected: `:1236 (mlx_lm) UP` + `:1235 (llama.cpp) DOWN` (servidor sobrevive ao TUI)

```bash
./clients/glaurung-llm/gla off
```

Expected: `:1235 + :1236 killed`

- [ ] **Step 4: Commit**

```bash
git add clients/glaurung-llm/gla
git commit -m "feat(gla): main run dispatch — mutex + start + wait + model + exec opencode

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Smoke test do override `-lcpp`

**Files:**
- Nenhum (só validação).

- [ ] **Step 1: Testar transição MLX → llama.cpp (mata MLX, sobe llama.cpp)**

Run em terminal interativo:
```bash
cd /Users/lucas/git/apps_mac/ancalagon-llm
./clients/glaurung-llm/gla off
./clients/glaurung-llm/gla gemma4         # sobe MLX, abre opencode
# Sai do opencode (Ctrl-C)
./clients/glaurung-llm/gla status         # confirma :1236 UP
./clients/glaurung-llm/gla qwen36-lcpp    # mata MLX, sobe llama.cpp Qwen36
# Sai do opencode
./clients/glaurung-llm/gla status         # confirma :1235 UP, :1236 DOWN
./clients/glaurung-llm/gla off
```

Expected:
- Segunda invocação (`qwen36-lcpp`) leva ~30-60s (carga do GGUF Qwen36 15GB)
- TUI abre com `glaurung/qwen36` no bottom-bar
- Após sair: status mostra apenas :1235 UP — MLX foi morto pelo mutex

Se a segunda invocação falhar com timeout do `_wait_ready`: aumentar timeout em `cmd_run` de 60s para 120s (Qwen36 dense em llama.cpp Metal pode levar mais que 60s pra carregar).

- [ ] **Step 2: Commit (só se ajustar timeout)**

Se ajustou timeout:
```bash
git add clients/glaurung-llm/gla
git commit -m "fix(gla): bump _wait_ready timeout to 120s (lcpp dense load)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Rename `glau_*` → `gla_*` no `.zshrc`

**Files:**
- Modify: `~/.zshrc` linhas 262-362

- [ ] **Step 1: Backup do `.zshrc`**

Run:
```bash
cp ~/.zshrc ~/.zshrc.bak.$(date +%Y%m%d-%H%M%S)
ls -la ~/.zshrc.bak.*
```

Expected: backup criado.

- [ ] **Step 2: Aplicar rename via `sed` em uma única passada**

Run:
```bash
sed -i '' \
  -e 's/_GLAU_LCPP_/_GLA_LCPP_/g' \
  -e 's/_GLAU_MLX_/_GLA_MLX_/g' \
  -e 's/_glau_lcpp_kill/_gla_lcpp_kill/g' \
  -e 's/_glau_mlx_kill/_gla_mlx_kill/g' \
  -e 's/glau_lcpp_qwen36/gla_lcpp_qwen36/g' \
  -e 's/glau_lcpp_gemma4/gla_lcpp_gemma4/g' \
  -e 's/glau_lcpp_off/gla_lcpp_off/g' \
  -e 's/glau_lcpp_logs/gla_lcpp_logs/g' \
  -e 's/glau_lcpp_status/gla_lcpp_status/g' \
  -e 's/glau_mlx_up/gla_mlx_up/g' \
  -e 's/glau_mlx_off/gla_mlx_off/g' \
  -e 's/glau_mlx_logs/gla_mlx_logs/g' \
  -e 's/glau_mlx_status/gla_mlx_status/g' \
  -e 's/glau_off/gla_off/g' \
  -e 's/glau_status/gla_status/g' \
  -e 's|/tmp/glau-lcpp\.log|/tmp/gla-lcpp.log|g' \
  -e 's|/tmp/glau-mlx\.log|/tmp/gla-mlx.log|g' \
  ~/.zshrc
```

- [ ] **Step 3: Verificar — nenhum `glau` deve sobrar**

Run:
```bash
grep -n 'glau' ~/.zshrc || echo "rename completo"
grep -nE 'gla[_-]' ~/.zshrc | head -25
```

Expected:
- Primeiro grep → `rename completo` (zero matches a `glau`)
- Segundo grep → 17 ocorrências de `gla_*` ou `gla-*` nos lugares esperados (linhas 283-362)

- [ ] **Step 4: Validar carregamento do `.zshrc` em shell nova**

Run:
```bash
zsh -i -c 'type gla_off gla_status gla_lcpp_gemma4 gla_mlx_up _gla_lcpp_kill _gla_mlx_kill 2>&1 | head -20'
```

Expected: cada identificador aparece como function/alias. Sem erro de sintaxe.

- [ ] **Step 5: Smoke test funcional dos aliases renomeados**

Run em shell nova (`zsh -i`):
```bash
gla_status
gla_off
```

Expected: comportamento idêntico ao antigo `glau_status` / `glau_off` — duas seções DOWN, mensagem `[gla_off] :1235 + :1236 killed`.

Note: a mensagem dentro do alias `gla_off` ainda diz `[gla_off]` corretamente porque o sed também renomeou a string literal (`alias gla_off='..."[gla_off]..."'`). Confirmar visualmente.

- [ ] **Step 6: `.zshrc` não está versionado neste repo — sem commit aqui**

A modificação é local à máquina. Se você versiona dotfiles em outro repo, comitar lá. Documentação do rename já está no spec deste repo.

---

### Task 9: Make target `install-gla`

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Adicionar target ao `Makefile`**

Edit `/Users/lucas/git/apps_mac/ancalagon-llm/Makefile` — na linha 3, expandir `.PHONY` para incluir `install-gla`:

```
.PHONY: install install-system install-gla wake status coder qwen36 gemma4 off sleep logs video-off video-on video-status bootwin bootwin-dry
```

E adicionar após o bloco `install-system` (após linha 10):

```makefile
install-gla:
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(CURDIR)/clients/glaurung-llm/gla $(HOME)/.local/bin/gla
	@echo "installed: $(HOME)/.local/bin/gla -> $(CURDIR)/clients/glaurung-llm/gla"
	@command -v gla >/dev/null && echo "gla in PATH" || echo "WARN: ~/.local/bin not in PATH; add 'export PATH=\$$HOME/.local/bin:\$$PATH' to ~/.zshrc"
```

(Use TAB no início da linha — Makefiles exigem TAB, não espaços.)

- [ ] **Step 2: Executar `make install-gla`**

Run:
```bash
cd /Users/lucas/git/apps_mac/ancalagon-llm
make install-gla
```

Expected: `installed: /Users/lucas/.local/bin/gla -> .../clients/glaurung-llm/gla` + `gla in PATH` (ou warning sobre PATH).

- [ ] **Step 3: Validar symlink em terminal limpo**

Run em shell nova:
```bash
zsh -i -c 'which gla && gla -h | head -5'
```

Expected: `/Users/lucas/.local/bin/gla` + cabeçalho do usage.

- [ ] **Step 4: Commit**

```bash
cd /Users/lucas/git/apps_mac/ancalagon-llm
git add Makefile
git commit -m "build(gla): add install-gla target (symlink to ~/.local/bin)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Smoke test E2E final + documentação no CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (adicionar referência ao `gla`)

- [ ] **Step 1: E2E final via `gla` instalado**

Run em shell nova:
```bash
gla off
gla gemma4
# (TUI abre com Gemma 4 MLX selecionado — manda "ola, em uma frase: o que é entropia?")
# Confirma resposta + bottom-bar correto, sai com Ctrl-C
gla qwen36-lcpp
# (TUI abre com Qwen36 llama.cpp selecionado — manda "ola, em uma frase: o que é entropia?")
# Confirma resposta + bottom-bar correto, sai
gla status   # mostra :1235 UP, :1236 DOWN
gla off      # libera GPU
gla status   # ambos DOWN
```

Expected: cada transição funciona, sem mensagem de erro, GPU liberada ao final.

- [ ] **Step 2: Adicionar seção breve no `CLAUDE.md`**

Edit `/Users/lucas/git/apps_mac/ancalagon-llm/CLAUDE.md` — encontrar a seção `## Uso dos clients (Mac)` e adicionar como primeira sub-seção (antes dos aliases atuais):

```markdown
### Comando único (`gla`)

Wrapper local que faz tudo em um comando: mata backends rivais, sobe o backend correto, reescreve `opencode.json` e abre o TUI já com o modelo selecionado:

```
gla gemma4         # MLX, ~57 tok/s
gla qwen36         # MLX, ~13.7 tok/s
gla gemma4-lcpp    # llama.cpp Metal (override)
gla qwen36-lcpp    # llama.cpp Metal (override)
gla off            # libera GPU
gla status         # estado dos backends
```

Instalado por `make install-gla` (symlink em `~/.local/bin/gla`). Substituto Mac do `lmswitch` do Ancalagon — mesma UX, mutex no nível de processo (não systemd). Spec: `docs/superpowers/specs/2026-05-01-gla-wrapper-design.md`.
```

- [ ] **Step 3: Commit**

```bash
cd /Users/lucas/git/apps_mac/ancalagon-llm
git add CLAUDE.md
git commit -m "docs: document gla wrapper in CLAUDE.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (do plano contra o spec)

| Requisito do spec | Task que cobre |
|---|---|
| Comando `gla <modelo>` único | Task 1 + Task 6 |
| Catálogo de 4 modelos (gemma4, qwen36, ±-lcpp) | Task 6 (mapa case) |
| Subcomandos `off` e `status` | Task 5 |
| Mutex local nas portas 1235/1236 (lsof) | Task 2 + Task 6 |
| Sem pidfile | Task 2 (intencional) |
| Reescrita atômica do opencode.json via jq+mv | Task 4 |
| Servidor vive além do TUI (sem cleanup ao exit) | Task 6 (`exec opencode`, sem trap matando backend) |
| `gla off` libera GPU sem abrir TUI | Task 5 |
| Tratamento de erro: porta ocupada, ready timeout, jq inválido, opencode.json ausente, binários ausentes, arg desconhecido | Tasks 2, 3, 4, 6 cobertas; arg desconhecido em Task 1 |
| `set -euo pipefail` no script | Task 1 (header) |
| Rename `glau_*` → `gla_*` (15 identificadores + 2 paths log) | Task 8 |
| Rename só atinge zsh + /tmp logs (não opencode providers / dirs) | Task 8 (sed só em ~/.zshrc) |
| Sem alias de compatibilidade | Task 8 (sed substitui in-place) |
| Script em `clients/glaurung-llm/gla` | Task 1 |
| Make target `install-gla` (symlink) | Task 9 |
| `make install` (existente) não alterado | Task 9 (target separado) |

**Lacunas resolvidas:**
- Trap de cleanup do `$tmpfile` do jq (mencionado no spec § Tratamento de erro): coberto em Task 4 (`rm -f "$tmp"` no path de erro do jq) — basta em vez de trap global, porque o script só chama `_set_opencode_model` uma vez e o `mv` é o último step antes do exec. Sem necessidade de trap EXIT separado.

**Placeholder scan:** nenhum "TBD"/"TODO"/"adapt as needed". Cada step tem comando exato + expected output. Code blocks completos.

**Type consistency:** funções referenciadas (`_mutex`, `_kill_port`, `_wait_port_free`, `_pids_on_port`, `_start_mlx`, `_start_lcpp_*`, `_wait_ready`, `_set_opencode_model`, `cmd_off`, `cmd_status`, `cmd_run`) são definidas antes de serem chamadas no `case`. Constantes (`LCPP_PORT`, `MLX_PORT`, `LCPP_LOG`, etc.) aparecem com mesmo nome em todas as tasks.

**Scope:** plano único, ~10 tasks, ~150 linhas de bash + 5 linhas de Makefile + 17 substituições no .zshrc. Cabe em uma execução.
