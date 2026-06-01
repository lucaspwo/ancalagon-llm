# Atualizar llama.cpp (Fase 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Atualizar os dois binários do `llama-server` (upstream + fork TQ3) no Ancalagon, medindo perf antes/depois e mantendo só o que não regredir, com rollback instantâneo por backup de binário.

**Architecture:** Uma variável por vez (upstream e fork decididos independentemente). Baseline medido antes de qualquer mudança. Configs dos services (`--n-cpu-moe`, ctx, KV quant) ficam intocadas — a única variável é a versão do binário. Rollback = restaurar o `.bak`.

**Tech Stack:** llama.cpp (CUDA sm_89), CMake, systemd --user, `lmswitch`/Makefile, curl+jq contra `:1234`.

**Spec:** `docs/superpowers/specs/2026-06-01-atualizar-llamacpp-fase1-design.md`

---

## Convenções deste plano

- **Onde rodar:** comandos prefixados `[MAC]` rodam do diretório do repo no Glaurung
  (`/Users/lucas/git/apps_mac/ancalagon-llm`). Comandos `[ANCA]` rodam no Ancalagon via
  `ssh lucas@100.91.10.22 '...'` (ou `192.168.1.8` se na LAN).
- **Endpoint de medição:** `:1234/completion` (nativo do llama-server), lendo
  `.timings.predicted_per_second` = tok/s de geração.
- **Prompt canônico de perf:** `"Explain quantum entanglement in exactly 5 paragraphs"`,
  `n_predict=400`, `temperature=0.2`.
- **Subir/parar services:** `make coder` | `make qwen36` | `make gemma4` | `make off`
  (já fazem ssh+lmswitch). `make status` para o health.
- **Arquivo de resultados:** `/tmp/llama-bench-fase1.txt` no Ancalagon (acumula baseline + pós-update).

---

## File Structure

- **Criar** `scripts/build-llama.sh` — script de build reproduzível (upstream|tq3), roda no Anca.
- **Modificar** `benchmarks/TUNING.md` — nova seção §8 com antes/depois e commits novos.
- **Modificar** `CLAUDE.md` — atualizar commits/datas de referência (só se binários mantidos).
- **Não versionado** (no Anca): rebuild de `build/bin/llama-server` nos dois repos; backups `.bak-<commit>`.

---

## Task 1: Baseline de performance (antes de tocar em nada)

**Files:** nenhum no repo. Gera `/tmp/llama-bench-fase1.txt` no Anca.

- [ ] **Step 1: Confirmar GPU livre e nenhum service ativo**

`[MAC]`
```bash
make off
ssh lucas@100.91.10.22 'nvidia-smi --query-gpu=memory.used --format=csv,noheader'
```
Expected: `make off` ok; VRAM usada ≈ 30-40 MiB (GPU livre).

- [ ] **Step 2: Criar helper de bench no Anca**

`[ANCA]` — cria um script que mede tok/s 2x e reporta a melhor:
```bash
ssh lucas@100.91.10.22 'cat > /tmp/bench.sh <<'"'"'EOF'"'"'
#!/usr/bin/env bash
# uso: bench.sh <label>
set -euo pipefail
LABEL="${1:?label}"
best=0
for i in 1 2; do
  r=$(curl -s http://127.0.0.1:1234/completion \
        -d "{\"prompt\":\"Explain quantum entanglement in exactly 5 paragraphs\",\"n_predict\":400,\"temperature\":0.2}" \
      | jq -r ".timings.predicted_per_second // 0")
  awk "BEGIN{exit !($r>$best)}" && best=$r
done
vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)
echo "$LABEL: ${best} tok/s | VRAM ${vram}" | tee -a /tmp/llama-bench-fase1.txt
EOF
chmod +x /tmp/bench.sh; echo "helper criado"'
```
Expected: `helper criado`.

- [ ] **Step 3: Baseline coder**

`[MAC]`
```bash
make coder && sleep 3 && make status
ssh lucas@100.91.10.22 '/tmp/bench.sh "baseline-coder-b76429a"'
```
Expected: linha tipo `baseline-coder-b76429a: ~78 tok/s | VRAM ~15.4 GiB`. Registrar valor real.

- [ ] **Step 4: Baseline gemma4**

`[MAC]`
```bash
make gemma4 && sleep 3 && make status
ssh lucas@100.91.10.22 '/tmp/bench.sh "baseline-gemma4-b76429a"'
```
Expected: `~84 tok/s`. Registrar valor real.

- [ ] **Step 5: Baseline qwen36 (perf)**

`[MAC]`
```bash
make qwen36 && sleep 3 && make status
ssh lucas@100.91.10.22 '/tmp/bench.sh "baseline-qwen36-794c5dc"'
```
Expected: `~37 tok/s`. Registrar valor real.

- [ ] **Step 6: Baseline qwen36 (QUALIDADE — teste ratelimiter)**

`[MAC]` — qwen36 ainda no ar do step anterior. Salva a resposta para comparação posterior:
```bash
ssh lucas@100.91.10.22 'curl -s http://127.0.0.1:1234/v1/chat/completions -d '"'"'{
  "messages":[{"role":"user","content":"Review this Python rate limiter for bugs. Be specific:\n\nimport time, threading\nclass RateLimiter:\n    def __init__(self, max_calls, period):\n        self.max_calls=max_calls; self.period=period\n        self.calls=[]; self.lock=threading.Lock()\n    def allow(self):\n        now=time.time()\n        with self.lock:\n            self.calls=[t for t in self.calls if now-t<self.period]\n        if len(self.calls)<self.max_calls:\n            with self.lock:\n                self.calls.append(now)\n            return True\n        return False\n    def remaining(self):\n        return self.max_calls-len(self.calls)"}],
  "max_tokens":700,"temperature":0.2}'"'"' | jq -r ".choices[0].message.content"' | tee /tmp/qual-baseline-tq3.txt
```
Expected: a resposta deve identificar os 3 bugs críticos: (1) **TOCTOU / lock granularity** (o check `len(self.calls)<max` e o `append` estão fora do mesmo lock que o filtro → race), (2) **`time.time()` não-monotônico** (NTP jump corrompe a janela), (3) **`remaining()` sem lock** + usa lista não-podada. Confirmar visualmente que os 3 aparecem.

- [ ] **Step 7: Parar services e revisar baseline**

`[MAC]`
```bash
make off
ssh lucas@100.91.10.22 'echo "=== BASELINE ==="; cat /tmp/llama-bench-fase1.txt'
```
Expected: três linhas de baseline registradas. **Anotar os três números** — são o critério de comparação.

---

## Task 2: Backup dos binários atuais (rollback instantâneo)

**Files:** nenhum no repo. Cria `.bak-<commit>` no Anca.

- [ ] **Step 1: Backup do binário upstream**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 'cp -v /home/lucas/git/llama.cpp/build/bin/llama-server \
  /home/lucas/git/llama.cpp/build/bin/llama-server.bak-b76429a'
```
Expected: `'...llama-server' -> '...llama-server.bak-b76429a'`.

- [ ] **Step 2: Backup do binário fork TQ3**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 'cp -v /home/lucas/git/llama.cpp-tq3/build/bin/llama-server \
  /home/lucas/git/llama.cpp-tq3/build/bin/llama-server.bak-794c5dc'
```
Expected: backup criado.

- [ ] **Step 3: Verificar backups**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 'ls -la /home/lucas/git/llama.cpp/build/bin/llama-server.bak-* \
  /home/lucas/git/llama.cpp-tq3/build/bin/llama-server.bak-*'
```
Expected: dois arquivos `.bak`, tamanho idêntico aos binários originais.

---

## Task 3: Criar script de build reproduzível

**Files:** Create `scripts/build-llama.sh`

- [ ] **Step 1: Criar o script no repo**

`[MAC]` — criar `scripts/build-llama.sh` com o conteúdo:
```bash
#!/usr/bin/env bash
# Build do llama-server com CUDA sm_89 (RTX 4070 Ti SUPER / Ada Lovelace).
# Roda NO Ancalagon. Uso: build-llama.sh {upstream|tq3}
set -euo pipefail

case "${1:-}" in
  upstream) REPO=/home/lucas/git/llama.cpp ;;
  tq3)      REPO=/home/lucas/git/llama.cpp-tq3 ;;
  *) echo "uso: $0 {upstream|tq3}" >&2; exit 1 ;;
esac

cd "$REPO"
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON
cmake --build build --config Release -j "$(nproc)" -t llama-server
echo "OK: $REPO/build/bin/llama-server"
```

- [ ] **Step 2: Tornar executável e shellcheck**

`[MAC]`
```bash
chmod +x scripts/build-llama.sh
shellcheck scripts/build-llama.sh
```
Expected: shellcheck sem warnings (consistente com a convenção do repo).

- [ ] **Step 3: Copiar para o Anca**

`[MAC]`
```bash
scp scripts/build-llama.sh lucas@100.91.10.22:/tmp/build-llama.sh
ssh lucas@100.91.10.22 'chmod +x /tmp/build-llama.sh'
```
Expected: copiado.

- [ ] **Step 4: Commit**

`[MAC]`
```bash
git add scripts/build-llama.sh
git commit -m "build(llama): script reproduzível de build CUDA sm_89

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Atualizar e recompilar o upstream

**Files:** nenhum no repo (build no Anca).

- [ ] **Step 1: git pull e anotar novo commit**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 'cd /home/lucas/git/llama.cpp && git pull --ff-only && \
  git log -1 --format="novo upstream: %h %ci %s"'
```
Expected: avança de `b76429a` para HEAD novo. Anotar o hash. Se `git pull` falhar (conflito local), PARAR e reportar.

- [ ] **Step 2: Rebuild (10-20 min)**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 '/tmp/build-llama.sh upstream'
```
Expected: termina com `OK: /home/lucas/git/llama.cpp/build/bin/llama-server`. Se o build falhar, PARAR — o binário antigo segue intacto (Task 7 cobre rollback) — e reportar o erro.

- [ ] **Step 3: Sanity do binário novo**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 '/home/lucas/git/llama.cpp/build/bin/llama-server --version 2>&1 | head -2'
```
Expected: imprime versão/commit sem erro de biblioteca CUDA.

---

## Task 5: Benchmark pós-upstream (coder + gemma4)

**Files:** acumula em `/tmp/llama-bench-fase1.txt`.

- [ ] **Step 1: Bench coder (binário novo)**

`[MAC]`
```bash
make coder && sleep 3 && make status
ssh lucas@100.91.10.22 '/tmp/bench.sh "novo-coder"'
```
Expected: nova linha de tok/s. Comparar com `baseline-coder`.

- [ ] **Step 2: Bench gemma4 (binário novo)**

`[MAC]`
```bash
make gemma4 && sleep 3 && make status
ssh lucas@100.91.10.22 '/tmp/bench.sh "novo-gemma4"'
make off
```
Expected: nova linha. Comparar com `baseline-gemma4`.

- [ ] **Step 3: Tabela comparativa upstream**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 'grep -E "coder|gemma4" /tmp/llama-bench-fase1.txt'
```
Expected: 4 linhas (baseline+novo de cada). Calcular `novo/baseline` para os dois.

---

## Task 6: Atualizar fork TQ3 e benchmark (qwen36)

**Files:** acumula em `/tmp/llama-bench-fase1.txt`.

- [ ] **Step 1: git pull do fork e anotar commit**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 'cd /home/lucas/git/llama.cpp-tq3 && git pull --ff-only && \
  git log -1 --format="novo tq3: %h %ci %s"'
```
Expected: avança de `794c5dc`. Se falhar (fork divergiu/conflito), PARAR este Task, **não** afeta o upstream já decidido — registrar e pular para Task 7.

- [ ] **Step 2: Rebuild do fork (10-20 min)**

`[ANCA]`
```bash
ssh lucas@100.91.10.22 '/tmp/build-llama.sh tq3'
```
Expected: `OK: /home/lucas/git/llama.cpp-tq3/build/bin/llama-server`. Se falhar, PARAR este Task e ir ao rollback do TQ3 (Task 7).

- [ ] **Step 3: Bench qwen36 (perf)**

`[MAC]`
```bash
make qwen36 && sleep 3 && make status
ssh lucas@100.91.10.22 '/tmp/bench.sh "novo-qwen36"'
```
Expected: nova linha. Comparar com `baseline-qwen36`.

- [ ] **Step 4: Teste de QUALIDADE qwen36 (mesmo prompt ratelimiter)**

`[MAC]` — qwen36 ainda no ar:
```bash
ssh lucas@100.91.10.22 'curl -s http://127.0.0.1:1234/v1/chat/completions -d '"'"'{
  "messages":[{"role":"user","content":"Review this Python rate limiter for bugs. Be specific:\n\nimport time, threading\nclass RateLimiter:\n    def __init__(self, max_calls, period):\n        self.max_calls=max_calls; self.period=period\n        self.calls=[]; self.lock=threading.Lock()\n    def allow(self):\n        now=time.time()\n        with self.lock:\n            self.calls=[t for t in self.calls if now-t<self.period]\n        if len(self.calls)<self.max_calls:\n            with self.lock:\n                self.calls.append(now)\n            return True\n        return False\n    def remaining(self):\n        return self.max_calls-len(self.calls)"}],
  "max_tokens":700,"temperature":0.2}'"'"' | jq -r ".choices[0].message.content"' | tee /tmp/qual-novo-tq3.txt
make off
```
Expected: deve identificar os mesmos 3 bugs do baseline (TOCTOU/lock, `time.time()` não-monotônico, `remaining()` sem lock).

- [ ] **Step 5: Diff de qualidade baseline vs novo**

`[MAC]`
```bash
ssh lucas@100.91.10.22 'echo "=== BASELINE ==="; cat /tmp/qual-baseline-tq3.txt; \
  echo; echo "=== NOVO ==="; cat /tmp/qual-novo-tq3.txt'
```
Expected: revisão manual — o novo deve manter os 3 bugs críticos. Perda de algum = degradação de qualidade.

---

## Task 7: Decisão manter/reverter (por binário, independente)

**Files:** nenhum. Critério da spec §4: manter se `novo ≥ baseline×0.95` E (TQ3) qualidade preservada.

- [ ] **Step 1: Decidir upstream**

Avaliar `novo-coder/baseline-coder` e `novo-gemma4/baseline-gemma4`.
- Ambos `≥ 0.95` → **MANTER** upstream (não fazer nada; binário novo já está no lugar).
- Algum `< 0.95` → **REVERTER**:
```bash
ssh lucas@100.91.10.22 'cp -v /home/lucas/git/llama.cpp/build/bin/llama-server.bak-b76429a \
  /home/lucas/git/llama.cpp/build/bin/llama-server'
```
Registrar a decisão e os números.

- [ ] **Step 2: Decidir fork TQ3**

Avaliar `novo-qwen36/baseline-qwen36` E qualidade.
- `≥ 0.95` E 3 bugs mantidos → **MANTER**.
- Senão → **REVERTER**:
```bash
ssh lucas@100.91.10.22 'cp -v /home/lucas/git/llama.cpp-tq3/build/bin/llama-server.bak-794c5dc \
  /home/lucas/git/llama.cpp-tq3/build/bin/llama-server'
```
Registrar decisão e números.

- [ ] **Step 3: Smoke test final do que ficou**

`[MAC]` — subir cada service que foi mantido E o(s) revertido(s), confirmar health:
```bash
for m in coder gemma4 qwen36; do make $m && sleep 3 && make status; done
make off
```
Expected: os três sobem e respondem `:1234` health ok com o binário que ficou (novo ou revertido).

---

## Task 8: Documentar resultados

**Files:** Modify `benchmarks/TUNING.md`, `CLAUDE.md`

- [ ] **Step 1: Adicionar §8 ao TUNING.md**

`[MAC]` — acrescentar seção ao fim de `benchmarks/TUNING.md` com a tabela real preenchida:
```markdown
## 8. Atualização do llama.cpp — Fase 1 (2026-06-01)

Upstream `b76429a` → `<novo-hash>` (549 commits). Fork TQ3 `794c5dc` → `<novo-hash>`.
Método: prompt canônico, n_predict=400, T=0.2, melhor de 2 runs.

| Modelo | Baseline tok/s | Novo tok/s | Δ | Decisão |
|---|---|---|---|---|
| coder | <X> | <Y> | <±%> | mantido/revertido |
| gemma4 | <X> | <Y> | <±%> | mantido/revertido |
| qwen36 TQ3 | <X> | <Y> | <±%> | mantido/revertido |

Qualidade TQ3 (teste ratelimiter): <os 3 bugs mantidos? sim/não>.
```
Preencher `<...>` com os números reais coletados.

- [ ] **Step 2: Atualizar CLAUDE.md (só para binários mantidos)**

`[MAC]` — em `CLAUDE.md`, seção "Pré-requisitos no Ancalagon", atualizar a referência de
commit se o binário foi mantido. Se revertido, manter o commit antigo. Editar a linha relevante.

- [ ] **Step 3: Commit da documentação**

`[MAC]`
```bash
git add benchmarks/TUNING.md CLAUDE.md
git commit -m "docs(tuning): resultados da Fase 1 de atualização do llama.cpp

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Finalizar a branch

**Files:** nenhum.

- [ ] **Step 1: Revisar o diff da branch**

`[MAC]`
```bash
git log --oneline main..feat/update-llamacpp
git diff main..feat/update-llamacpp --stat
```
Expected: commits = spec + build-llama.sh + docs. Diff só em `docs/`, `scripts/`, `benchmarks/`, `CLAUDE.md`.

- [ ] **Step 2: Usar finishing-a-development-branch**

Invocar `superpowers:finishing-a-development-branch` para decidir merge/PR/cleanup.

---

## Self-Review (preenchido)

**Spec coverage:** baseline (Task 1) ✓, backup/rollback (Task 2, 7) ✓, upstream (Task 4-5) ✓,
fork TQ3 + qualidade (Task 6) ✓, critério manter/reverter (Task 7) ✓, script build (Task 3) ✓,
documentação (Task 8) ✓, fora-de-escopo respeitado (configs intocadas; driver não tocado) ✓.

**Placeholder scan:** os `<X>/<Y>/<novo-hash>` no Task 8 são valores a coletar em runtime
(corretos como tal, não são placeholders de instrução). Nenhum "TODO/implementar depois".

**Consistência:** nomes de label de bench (`baseline-coder` / `novo-coder` etc.) consistentes
entre Task 1, 5, 6 e 7. Paths de `.bak` consistentes entre Task 2 e 7. Endpoint `:1234` e
`/tmp/bench.sh` consistentes.
