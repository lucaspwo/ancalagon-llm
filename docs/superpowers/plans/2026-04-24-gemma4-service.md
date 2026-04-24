# Gemma 4 service — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adicionar `llama-gemma4.service` como terceiro preset systemd mutuamente exclusivo, expondo Gemma 4 26B-A4B-it (MoE, 16 GB) na porta 1234 com mesmo contrato do `llama-coder`.

**Architecture:** Unit systemd `--user` com `Conflicts=` simétrico aos existentes, invocado pelo wrapper `lmswitch` já no repo. Deploy via `make install` (sobrescreve units + wrapper, faz daemon-reload). Config inicial idêntica à do `llama-coder` (ctx=96K, ncmoe=16, KV q4_0) como ponto de partida empírico — tuning iterativo após primeiro benchmark.

**Tech Stack:** systemd user units, bash, llama.cpp upstream (CUDA sm_89), ssh/scp via Tailscale.

**Spec:** [`docs/superpowers/specs/2026-04-24-gemma4-service-design.md`](../specs/2026-04-24-gemma4-service-design.md)

---

## File Structure

**Criar:**
- `systemd/llama-gemma4.service` — unit novo

**Modificar:**
- `systemd/llama-coder.service` — adicionar gemma4 em `Conflicts=`
- `systemd/llama-qwen36.service` — adicionar gemma4 em `Conflicts=`
- `bin/lmswitch` — novo case, updates em status/logs/off/sleep/usage
- `Makefile` — novo target + `.PHONY`
- `scripts/install.sh` — acrescentar unit na linha do `scp`
- `README.md` — referência ao service novo em arquitetura + componentes
- `CLAUDE.md` — atualizar diagrama, listagens, tabela de performance
- `AI_CONTEXT.md` — acrescentar nas listagens
- `benchmarks/TUNING.md` — entrada de dados empíricos (após medir)

---

## Task 1: Criar `systemd/llama-gemma4.service`

**Files:**
- Create: `systemd/llama-gemma4.service`

- [ ] **Step 1: Escrever o unit**

Arquivo novo com config idêntica à do coder (espelhando pragmaticamente como ponto de partida empírico), trocando apenas a descrição, o modelo e os conflicts:

```ini
[Unit]
Description=llama.cpp server - Gemma 4 26B-A4B-it (MoE, n-cpu-moe=16, KV q4_0)
Conflicts=llama-coder.service llama-qwen36.service lmstudio.service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/lucas/git/llama.cpp/build/bin
Environment=PATH=/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/lucas/git/llama.cpp/build/bin/llama-server -m /home/lucas/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf --host 0.0.0.0 --port 1234 -c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 16 --jinja
Restart=on-failure
RestartSec=3
KillMode=mixed
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=default.target
```

- [ ] **Step 2: Verificar sintaxe**

Run: `systemd-analyze verify systemd/llama-gemma4.service 2>&1 || true`

Isso vai reclamar que o binário não existe no Mac — OK, é esperado. Só queremos checar sintaxe inválida. Se reclamar de diretiva desconhecida, corrigir. Se só reclamar de `ExecStart` path not found, seguir.

- [ ] **Step 3: Commit**

```bash
git add systemd/llama-gemma4.service
git commit -m "Add llama-gemma4.service — Gemma 4 26B-A4B MoE preset

Config idêntica ao llama-coder como ponto de partida empírico (ctx=96K,
ncmoe=16, KV q4_0). Conflicts mútuo com os dois services existentes."
```

---

## Task 2: Atualizar `Conflicts=` nos services existentes

**Files:**
- Modify: `systemd/llama-coder.service:3`
- Modify: `systemd/llama-qwen36.service:3`

- [ ] **Step 1: Adicionar gemma4 em `Conflicts=` do coder**

Em `systemd/llama-coder.service`, linha 3:

```
Conflicts=llama-qwen36.service lmstudio.service
```

vira:

```
Conflicts=llama-qwen36.service llama-gemma4.service lmstudio.service
```

- [ ] **Step 2: Adicionar gemma4 em `Conflicts=` do qwen36**

Em `systemd/llama-qwen36.service`, linha 3:

```
Conflicts=llama-coder.service lmstudio.service
```

vira:

```
Conflicts=llama-coder.service llama-gemma4.service lmstudio.service
```

- [ ] **Step 3: Verificar sintaxe**

Run: `systemd-analyze verify systemd/llama-coder.service systemd/llama-qwen36.service 2>&1 || true`

Mesma lógica da Task 1 — path errors do Mac são OK, só importa sintaxe válida.

- [ ] **Step 4: Commit**

```bash
git add systemd/llama-coder.service systemd/llama-qwen36.service
git commit -m "Add llama-gemma4 to Conflicts= of coder/qwen36

Exclusão mútua agora é simétrica entre os três services."
```

---

## Task 3: Atualizar `bin/lmswitch`

**Files:**
- Modify: `bin/lmswitch`

- [ ] **Step 1: Atualizar usage (linhas 10-21)**

Bloco atual:

```bash
usage() {
  cat <<EOF
Usage: lmswitch {coder|qwen36|off|sleep|status|logs}

  coder    — start upstream llama.cpp with Qwen3-Coder-30B-A3B (MoE, ncmoe=16)
  qwen36   — start TQ3 fork with Qwen3.6-27B-TQ3_4S (100% GPU)
  off      — stop any active llama server
  sleep    — stop services and suspend the system (wake via WoL)
  status   — show service states + health probe on :$PORT
  logs     — tail journal of the currently active llama server
EOF
  exit 1
}
```

vira:

```bash
usage() {
  cat <<EOF
Usage: lmswitch {coder|qwen36|gemma4|off|sleep|status|logs}

  coder    — start upstream llama.cpp with Qwen3-Coder-30B-A3B (MoE, ncmoe=16)
  qwen36   — start TQ3 fork with Qwen3.6-27B-TQ3_4S (100% GPU)
  gemma4   — start upstream llama.cpp with Gemma 4 26B-A4B-it (MoE, ncmoe=16)
  off      — stop any active llama server
  sleep    — stop services and suspend the system (wake via WoL)
  status   — show service states + health probe on :$PORT
  logs     — tail journal of the currently active llama server
EOF
  exit 1
}
```

- [ ] **Step 2: Atualizar case `coder)` para também parar gemma4**

Trecho atual (linhas 46-50):

```bash
  coder)
    systemctl --user stop llama-qwen36.service 2>/dev/null || true
    systemctl --user start llama-coder.service
    wait_ready llama-coder.service "qwen3-coder (ncmoe=16)"
    ;;
```

vira:

```bash
  coder)
    systemctl --user stop llama-qwen36.service 2>/dev/null || true
    systemctl --user stop llama-gemma4.service 2>/dev/null || true
    systemctl --user start llama-coder.service
    wait_ready llama-coder.service "qwen3-coder (ncmoe=16)"
    ;;
```

- [ ] **Step 3: Atualizar case `qwen36)` para também parar gemma4**

Trecho atual (linhas 51-55):

```bash
  qwen36|qwen3.6|tq3)
    systemctl --user stop llama-coder.service 2>/dev/null || true
    systemctl --user start llama-qwen36.service
    wait_ready llama-qwen36.service "qwen3.6-27b TQ3"
    ;;
```

vira:

```bash
  qwen36|qwen3.6|tq3)
    systemctl --user stop llama-coder.service 2>/dev/null || true
    systemctl --user stop llama-gemma4.service 2>/dev/null || true
    systemctl --user start llama-qwen36.service
    wait_ready llama-qwen36.service "qwen3.6-27b TQ3"
    ;;
```

- [ ] **Step 4: Adicionar case `gemma4)` logo após o case `qwen36)`**

Inserir após a linha `;;` que fecha o case `qwen36`:

```bash
  gemma4|gemma)
    systemctl --user stop llama-coder.service 2>/dev/null || true
    systemctl --user stop llama-qwen36.service 2>/dev/null || true
    systemctl --user start llama-gemma4.service
    wait_ready llama-gemma4.service "gemma-4-26b (ncmoe=16)"
    ;;
```

- [ ] **Step 5: Atualizar case `off|stop)` para parar gemma4**

Trecho atual:

```bash
  off|stop)
    systemctl --user stop llama-coder.service 2>/dev/null || true
    systemctl --user stop llama-qwen36.service 2>/dev/null || true
    echo "All llama services stopped"
    ;;
```

vira:

```bash
  off|stop)
    systemctl --user stop llama-coder.service 2>/dev/null || true
    systemctl --user stop llama-qwen36.service 2>/dev/null || true
    systemctl --user stop llama-gemma4.service 2>/dev/null || true
    echo "All llama services stopped"
    ;;
```

- [ ] **Step 6: Atualizar case `sleep|suspend)` para parar gemma4**

Trecho atual:

```bash
  sleep|suspend)
    systemctl --user stop llama-coder.service 2>/dev/null || true
    systemctl --user stop llama-qwen36.service 2>/dev/null || true
    echo "Suspending system (wake with WoL)..."
```

vira:

```bash
  sleep|suspend)
    systemctl --user stop llama-coder.service 2>/dev/null || true
    systemctl --user stop llama-qwen36.service 2>/dev/null || true
    systemctl --user stop llama-gemma4.service 2>/dev/null || true
    echo "Suspending system (wake with WoL)..."
```

- [ ] **Step 7: Atualizar loop do case `status)`**

Trecho atual:

```bash
    for svc in llama-coder llama-qwen36 lmstudio; do
```

vira:

```bash
    for svc in llama-coder llama-qwen36 llama-gemma4 lmstudio; do
```

- [ ] **Step 8: Atualizar loop do case `logs)`**

Trecho atual:

```bash
    for svc in llama-coder llama-qwen36; do
```

vira:

```bash
    for svc in llama-coder llama-qwen36 llama-gemma4; do
```

- [ ] **Step 9: Verificar shellcheck (convenção do repo)**

Run: `shellcheck bin/lmswitch`

Expected: exit 0, sem avisos. Se aparecer warning novo (SC2XXX), corrigir antes de commitar.

- [ ] **Step 10: Verificar ajuda renderiza**

Run: `bash bin/lmswitch foo 2>&1 | head -20`

Expected: mostra usage com `gemma4` listado. Termina exit 1.

- [ ] **Step 11: Commit**

```bash
git add bin/lmswitch
git commit -m "lmswitch: add gemma4 subcommand + update status/logs/off/sleep

Exclusão mútua agora lida com os 3 services; usage, status e logs
mostram o novo preset."
```

---

## Task 4: Atualizar `Makefile`

**Files:**
- Modify: `Makefile:3,18-22`

- [ ] **Step 1: Adicionar `gemma4` em `.PHONY`**

Linha 3 atual:

```make
.PHONY: install install-system wake status coder qwen36 off sleep logs
```

vira:

```make
.PHONY: install install-system wake status coder qwen36 gemma4 off sleep logs
```

- [ ] **Step 2: Adicionar target `gemma4:` entre `qwen36:` e `off:`**

Após o bloco:

```make
qwen36:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch qwen36
```

Inserir:

```make
gemma4:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch gemma4
```

- [ ] **Step 3: Verificar que `make` reconhece o target**

Run: `make -n gemma4`

Expected: imprime `ssh Ancalagon_Ubuntu-Tailnet /home/lucas/.local/bin/lmswitch gemma4` (dry-run).

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "Makefile: add gemma4 target"
```

---

## Task 5: Atualizar `scripts/install.sh`

**Files:**
- Modify: `scripts/install.sh:13-14`

O install lista units por nome (não usa glob) — precisa acrescentar o novo.

- [ ] **Step 1: Incluir `llama-gemma4.service` na linha do `scp`**

Trecho atual:

```bash
echo "→ Copying systemd units..."
scp "$REPO_DIR"/systemd/llama-coder.service "$REPO_DIR"/systemd/llama-qwen36.service \
  "$REMOTE":/home/lucas/.config/systemd/user/
```

vira:

```bash
echo "→ Copying systemd units..."
scp "$REPO_DIR"/systemd/llama-coder.service "$REPO_DIR"/systemd/llama-qwen36.service \
  "$REPO_DIR"/systemd/llama-gemma4.service \
  "$REMOTE":/home/lucas/.config/systemd/user/
```

- [ ] **Step 2: Verificar shellcheck**

Run: `shellcheck scripts/install.sh`

Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/install.sh
git commit -m "install.sh: deploy llama-gemma4.service"
```

---

## Task 6: Deploy e smoke test

**Files:** nenhum (remoto — aplica artefatos já commitados)

- [ ] **Step 1: Deploy via `make install`**

Run: `make install`

Expected output (últimas linhas):

```
→ Copying systemd units...
→ Copying lmswitch wrapper...
→ Reloading systemd...
Done. Test with: ssh Ancalagon_Ubuntu-Tailnet /home/lucas/.local/bin/lmswitch status
```

Se `scp` ou `daemon-reload` falhar: não prosseguir; resolver conectividade ou sintaxe antes.

- [ ] **Step 2: Verificar que o unit apareceu no remoto**

Run:

```bash
ssh Ancalagon_Ubuntu-Tailnet 'ls -la ~/.config/systemd/user/llama-gemma4.service && systemctl --user cat llama-gemma4.service | head -20'
```

Expected: arquivo existe, conteúdo idêntico ao do repo.

- [ ] **Step 3: `make status` mostra o novo service**

Run: `make status`

Expected: lista `llama-coder.service`, `llama-qwen36.service`, `llama-gemma4.service`, `lmstudio.service` todos `inactive` (ou o estado corrente). `:1234` mostra "not responding" se nada estiver ativo.

- [ ] **Step 4: Subir gemma4 e esperar health**

Run: `make gemma4`

Expected:
- Output termina em `ready` + `http://localhost:1234 (v1/chat/completions)`
- Não deve demorar >120s (primeira carga do mmap pode passar de 60s — se estourar 90s do wait_ready, checar `journalctl --user -u llama-gemma4`)

Se der timeout por OOM no compute buffer: o ncmoe=16 não bastou pra gemma4 com 96K ctx. Neste caso:
- Editar `systemd/llama-gemma4.service` localmente: subir ncmoe para 20
- `make install && make gemma4` de novo
- Registrar o fato em `benchmarks/TUNING.md` na Task 8

Se falhar por erro de template jinja: remover `--jinja` do ExecStart, repetir install/gemma4.

- [ ] **Step 5: Health check direto**

Run:

```bash
curl -fs http://100.91.10.22:1234/health
echo
curl -fs http://100.91.10.22:1234/v1/models | head -c 300
```

Expected: `{"status":"ok"}` + JSON listando o modelo carregado (id contém "gemma").

- [ ] **Step 6: Testar exclusão mútua — gemma4 → coder**

Run: `make coder`

Expected: sobe coder, gemma4 cai automaticamente.

Validar:

```bash
ssh Ancalagon_Ubuntu-Tailnet 'systemctl --user is-active llama-gemma4.service; systemctl --user is-active llama-coder.service'
```

Expected: primeira linha `inactive`, segunda `active`.

- [ ] **Step 7: Testar exclusão mútua — coder → gemma4**

Run: `make gemma4`

Expected: coder cai, gemma4 sobe, health em :1234 volta a responder.

- [ ] **Step 8: Testar `make off` para os 3**

Run: `make off`

Expected:

```
All llama services stopped
```

Validar:

```bash
ssh Ancalagon_Ubuntu-Tailnet 'for s in llama-coder llama-qwen36 llama-gemma4; do echo -n "$s: "; systemctl --user is-active "$s.service" || true; done'
```

Expected: os três `inactive`.

- [ ] **Step 9: Commit (nenhum código novo — só registrar marco se desejar, senão pular)**

Se nenhum ajuste de config foi necessário no Step 4, pular. Caso tenha ajustado ncmoe ou removido `--jinja`:

```bash
git add systemd/llama-gemma4.service
git commit -m "llama-gemma4: tune for first successful boot — <descrever ajuste>"
```

---

## Task 7: Benchmark inicial

**Files:**
- Modify: `benchmarks/TUNING.md` (append)

Este benchmark produz os números que vão pra tabela de performance do `CLAUDE.md` e o threshold de regressão.

- [ ] **Step 1: Subir gemma4 limpo**

Run: `make gemma4`

Expected: ready em :1234.

- [ ] **Step 2: Medir tok/s de geração com prompt curto**

Run (do Mac):

```bash
time curl -s http://100.91.10.22:1234/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gemma",
    "messages": [{"role":"user","content":"Explain quantum entanglement in 5 paragraphs."}],
    "max_tokens": 400,
    "stream": false
  }' | tee /tmp/gemma4-bench.json | jq -r '.usage, .choices[0].message.content[:200]'
```

Anotar de `/tmp/gemma4-bench.json`:
- `usage.completion_tokens`
- tempo total (do `time`)
- tok/s gen ≈ `completion_tokens / elapsed`

- [ ] **Step 3: Medir prefill tok/s com prompt longo**

Run (do Mac):

```bash
python3 -c "print('Explain quantum entanglement. ' * 2000)" > /tmp/big-prompt.txt
time curl -s http://100.91.10.22:1234/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "$(jq -Rs '{model:"gemma",messages:[{role:"user",content:.}],max_tokens:50,stream:false}' /tmp/big-prompt.txt)" \
  | jq -r '.usage'
```

Anotar `prompt_tokens` e tempo total; pp tok/s ≈ `prompt_tokens / elapsed`.

- [ ] **Step 4: Capturar VRAM e GPU util**

Em outra aba, durante o Step 3, rodar no Mac:

```bash
ssh Ancalagon_Ubuntu-Tailnet 'nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.free,power.draw --format=csv -l 1' | head -10
```

Anotar:
- GPU util pico
- memory.used (MiB)
- memory.free (MiB)
- power.draw pico (W)

- [ ] **Step 5: Adicionar entrada em `benchmarks/TUNING.md`**

Append uma seção nova no final:

```markdown
## Gemma 4 26B-A4B-it Q4_K_M — primeiro benchmark (2026-04-24)

Hardware: Ryzen 5 7600X + RTX 4070 Ti SUPER 16 GB. llama.cpp upstream.
Config: `-c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 16 --jinja`

| Métrica | Valor |
|---|---|
| tok/s gen (prompt curto, 400 out) | <X> |
| pp tok/s (~<N>K prefill) | <Y> |
| GPU util pico | <Z>% |
| VRAM usada | <V> GiB |
| VRAM livre | <F> MiB |
| Power pico | <P> W |

Comparação vs coder (78 tok/s gen, 15.4 GiB VRAM): <narrativa curta>.

Ajustes aplicados (se algum): <ex: ncmoe 16 → 20 por OOM em compute buffer a 96K>.
```

Substituir `<X>`, `<Y>`, etc. pelos números medidos.

- [ ] **Step 6: Commit**

```bash
git add benchmarks/TUNING.md
git commit -m "benchmarks: record first Gemma 4 26B-A4B run

<tok/s gen>, <tok/s pp>, <VRAM>. Comparação com coder ao lado."
```

---

## Task 8: Atualizar documentação

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `AI_CONTEXT.md`

Objetivo: fazer cada arquivo refletir que existe um terceiro preset. Não mexer em decisões de design já documentadas; só acrescentar linhas.

- [ ] **Step 1: Atualizar `README.md` — parágrafo de abertura**

Linha 3 atual:

```
Setup do Ancalagon (Ubuntu Server 24.04 dual-boot) como servidor LLM dedicado, otimizado para GPU RTX 4070 Ti SUPER (16 GB VRAM). Substitui LM Studio por `llama.cpp` nativo controlado por systemd, com dois presets mutuamente exclusivos: Qwen3-Coder 30B (MoE upstream) e Qwen3.6-27B (fork TQ3).
```

vira:

```
Setup do Ancalagon (Ubuntu Server 24.04 dual-boot) como servidor LLM dedicado, otimizado para GPU RTX 4070 Ti SUPER (16 GB VRAM). Substitui LM Studio por `llama.cpp` nativo controlado por systemd, com três presets mutuamente exclusivos: Qwen3-Coder 30B (MoE upstream), Qwen3.6-27B (fork TQ3) e Gemma 4 26B-A4B-it (MoE upstream).
```

- [ ] **Step 2: Atualizar `README.md` — diagrama ASCII (linhas 27-40)**

Trecho atual:

```
aliases:                          systemd --user:
  llcoder  ──────ssh─────▶        llama-coder.service ─┐
  llq36    ──────ssh─────▶        llama-qwen36.service ┼─ Conflicts=
  lloff    ──────ssh─────▶        (lmstudio.service    ─┘  (only one up)
  llstatus ──────ssh─────▶        + disabled)
```

vira:

```
aliases:                          systemd --user:
  llcoder  ──────ssh─────▶        llama-coder.service ──┐
  llq36    ──────ssh─────▶        llama-qwen36.service ─┤
  llgemma4 ──────ssh─────▶        llama-gemma4.service ─┼─ Conflicts=
  lloff    ──────ssh─────▶        (lmstudio.service    ─┘  (only one up)
  llstatus ──────ssh─────▶        + disabled)
```

- [ ] **Step 3: Atualizar `README.md` — seção Componentes**

Após o bloco `### systemd/llama-qwen36.service` (linha 60 aprox), inserir nova subseção:

```markdown
### `systemd/llama-gemma4.service`

Upstream llama.cpp com Gemma 4 26B-A4B-it Q4_K_M (16 GB em disco, MoE com 4B ativos). Mesmo binário do coder.

- `-c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 16 --jinja` (config inicial espelha a do coder; medido após primeiro boot — ver `benchmarks/TUNING.md`)
- Bind `0.0.0.0:1234`, `Conflicts=llama-coder.service llama-qwen36.service lmstudio.service`
```

- [ ] **Step 4: Atualizar `README.md` — seção de uso do `lmswitch`**

Bloco atual (linhas 70-76):

```
lmswitch coder    # sobe qwen3-coder
lmswitch qwen36   # sobe qwen3.6 TQ3
lmswitch off      # para tudo
lmswitch status
lmswitch logs
```

vira:

```
lmswitch coder    # sobe qwen3-coder
lmswitch qwen36   # sobe qwen3.6 TQ3
lmswitch gemma4   # sobe gemma-4-26b
lmswitch off      # para tudo
lmswitch status
lmswitch logs
```

- [ ] **Step 5: Atualizar `README.md` — bloco de aliases `.zshrc` exemplo (linhas 104-112)**

Trecho atual:

```
alias llcoder="lmswitch coder"
alias llq36="lmswitch qwen36"
alias lloff="lmswitch off"
alias llstatus="lmswitch status"
alias lllogs="lmswitch logs"
```

vira:

```
alias llcoder="lmswitch coder"
alias llq36="lmswitch qwen36"
alias llgemma4="lmswitch gemma4"
alias lloff="lmswitch off"
alias llstatus="lmswitch status"
alias lllogs="lmswitch logs"
```

- [ ] **Step 6: Atualizar `README.md` — bloco de aliases `.zshrc` do Mac (linhas 124-137)**

Após:

```
alias llq36='ssh "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch qwen36'
```

inserir:

```
alias llgemma4='ssh "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch gemma4'
```

- [ ] **Step 7: Atualizar `CLAUDE.md` — diagrama (linhas ~10-20)**

Trecho atual:

```
Glaurung (Mac)                    Ancalagon-Ubuntu (100.91.10.22)
aliases no .zshrc                  systemd --user (Conflicts= entre os três):
  llcoder  ──ssh──▶                llama-coder.service   (upstream)
  llq36    ──ssh──▶                llama-qwen36.service  (fork TQ3)
  lloff    ──ssh──▶                lmstudio.service      (DISABLED)
  llstatus ──ssh──▶                     │
```

vira:

```
Glaurung (Mac)                    Ancalagon-Ubuntu (100.91.10.22)
aliases no .zshrc                  systemd --user (Conflicts= entre os quatro):
  llcoder  ──ssh──▶                llama-coder.service   (upstream)
  llq36    ──ssh──▶                llama-qwen36.service  (fork TQ3)
  llgemma4 ──ssh──▶                llama-gemma4.service  (upstream)
  lloff    ──ssh──▶                lmstudio.service      (DISABLED)
  llstatus ──ssh──▶                     │
```

- [ ] **Step 8: Atualizar `CLAUDE.md` — seção Layout (listagem de arquivos)**

Localizar o bloco:

```
systemd/
  llama-coder.service      # Qwen3-Coder-30B Q4_K_M, --n-cpu-moe 12
  llama-qwen36.service     # Qwen3.6-27B-TQ3_4S, fork turbo-tan/llama.cpp-tq3
```

e trocar por:

```
systemd/
  llama-coder.service      # Qwen3-Coder-30B Q4_K_M, --n-cpu-moe 16
  llama-qwen36.service     # Qwen3.6-27B-TQ3_4S, fork turbo-tan/llama.cpp-tq3
  llama-gemma4.service     # Gemma 4 26B-A4B-it Q4_K_M, --n-cpu-moe 16
```

(Ajuste de passagem: `--n-cpu-moe 12 → 16` no comentário do coder, alinhando com a config real na linha 11 do unit.)

- [ ] **Step 9: Atualizar `CLAUDE.md` — seção Deploy (comandos make)**

Localizar:

```
make coder       # sobe qwen3-coder
make qwen36      # sobe qwen3.6 TQ3 (mata coder)
make off         # para services (mantém máquina ligada)
```

e trocar por:

```
make coder       # sobe qwen3-coder
make qwen36      # sobe qwen3.6 TQ3 (mata coder)
make gemma4      # sobe gemma-4-26b (mata os outros)
make off         # para services (mantém máquina ligada)
```

- [ ] **Step 10: Atualizar `CLAUDE.md` — tabela de performance**

Localizar a tabela `| Service | tok/s gen | pp tok/s | ...` e adicionar uma terceira linha com os números reais da Task 7:

```
| llama-gemma4 (96K ctx, ncmoe=<N>) | <X> | <Y> | <Z>% | <P>W | <V> GiB |
```

Atualizar também o parágrafo de threshold:

```
Se `make status` + um bench curto (5-par quantum entanglement, 400 tokens) der menos de **55 tok/s no coder**, **25 tok/s no qwen36** ou **<T> tok/s no gemma4**, há regressão
```

Onde `<T>` = `round(tok/s_medido * 0.7)`.

- [ ] **Step 11: Atualizar `CLAUDE.md` — seção "Pré-requisitos no Ancalagon"**

Adicionar na lista de modelos:

```
  - `/home/lucas/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf`
```

- [ ] **Step 12: Atualizar `CLAUDE.md` — seção "Uso dos clients (Mac)"**

Adicionar linha após `llq36 && srl-tq`:

```
llgemma4                # gemma 4 26B-A4B MoE, ~<X> tok/s (alternativa ao coder — ver TUNING)
```

Onde `<X>` é o número da Task 7.

- [ ] **Step 13: Atualizar `AI_CONTEXT.md` — diagrama (linhas ~23-33)**

Trecho atual:

```
aliases .zshrc                         systemd --user (Conflicts= entre si):
  llcoder  ──ssh──▶                    llama-coder.service   (upstream)
  llq36    ──ssh──▶                    llama-qwen36.service  (fork TQ3)
  lloff    ──ssh──▶                    lmstudio.service      (DISABLED)
```

vira:

```
aliases .zshrc                         systemd --user (Conflicts= entre si):
  llcoder  ──ssh──▶                    llama-coder.service   (upstream)
  llq36    ──ssh──▶                    llama-qwen36.service  (fork TQ3)
  llgemma4 ──ssh──▶                    llama-gemma4.service  (upstream)
  lloff    ──ssh──▶                    lmstudio.service      (DISABLED)
```

- [ ] **Step 14: Atualizar `AI_CONTEXT.md` — parágrafo após o diagrama (linha ~35)**

Trecho atual:

```
Dois services mutuamente exclusivos (`Conflicts=`), ambos na :1234.
```

vira:

```
Três services mutuamente exclusivos (`Conflicts=`), todos na :1234.
```

- [ ] **Step 15: Atualizar `AI_CONTEXT.md` — tabela de artefatos**

Após a linha do `llama-qwen36.service`, inserir:

```
| `systemd/llama-gemma4.service` | user unit — Gemma 4 26B-A4B-it MoE, `--n-cpu-moe 16`, KV q4/q4, ctx 96K | `~/.config/systemd/user/` no Ancalagon |
```

E atualizar a linha do `lmswitch` para incluir o novo subcomando:

```
| `bin/lmswitch` | wrapper com subcomandos `coder\|qwen36\|gemma4\|off\|sleep\|status\|logs` | `~/.local/bin/` no Ancalagon |
```

- [ ] **Step 16: Atualizar `AI_CONTEXT.md` — seção "Estado atual (2026-04-24)"**

Primeiro bullet:

```
- Services rodando com `ctx=96K` no coder, `ctx=32K` no qwen36
```

vira:

```
- Services rodando com `ctx=96K` no coder, `ctx=32K` no qwen36, `ctx=96K` no gemma4 (alternativa ao coder)
```

- [ ] **Step 17: Verificar links/coerência**

Run: `grep -n "gemma" README.md CLAUDE.md AI_CONTEXT.md`

Expected: várias linhas em cada arquivo, consistentes com as edições acima.

Run: `grep -nE "llama-(coder|qwen36|gemma4)\.service" systemd/*.service bin/lmswitch Makefile scripts/install.sh`

Expected: todos os três services referenciados em cada arquivo relevante.

- [ ] **Step 18: Commit**

```bash
git add README.md CLAUDE.md AI_CONTEXT.md
git commit -m "docs: document llama-gemma4 preset + benchmark results

Diagrama, listagens, tabela de performance e threshold de regressão
atualizados nos três arquivos de referência."
```

---

## Self-Review (executado antes de entregar)

**Cobertura do spec:**
- "Novos: systemd/llama-gemma4.service" → Task 1 ✓
- "Modificados: Conflicts= nos services existentes" → Task 2 ✓
- "bin/lmswitch — novo case, stops, status, logs, usage" → Task 3 ✓
- "Makefile" → Task 4 ✓
- "scripts/install.sh" → Task 5 ✓
- "README.md + CLAUDE.md + AI_CONTEXT.md" → Task 8 ✓
- "benchmarks/TUNING.md" → Task 7 ✓
- "Critérios de aceitação (deploy, health, conflicts, status, logs)" → Task 6 ✓
- "Tuning iterativo de ncmoe se VRAM estourar" → Task 6 Step 4 ✓
- "Threshold de regressão a definir após benchmark" → Task 8 Step 10 ✓

**Placeholders:** Nenhum TBD/TODO deixado sem ação. Os `<X>`/`<Y>` das Tasks 7-8 são preenchidos com números reais medidos — não são placeholders no código, são campos de medida.

**Consistência de tipos/nomes:** service name `llama-gemma4.service`, subcomando `gemma4`, target `gemma4`, alias `llgemma4` — consistentes em todos os lugares.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-24-gemma4-service.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — executar as tasks nesta sessão usando executing-plans, batch com checkpoints para review

Qual preferir?
