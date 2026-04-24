# ancalagon-llm

## Visão Geral

Setup do Ancalagon (Ubuntu Server 24.04 dual-boot, RTX 4070 Ti SUPER 16 GB VRAM) como servidor LLM dedicado. Substitui LM Studio por `llama.cpp` nativo controlado por systemd, com dois presets mutuamente exclusivos. Consumido do Mac (Glaurung) via Tailscale em `100.91.10.22:1234`.

**Source of truth** dos artefatos instalados em `~/.config/systemd/user/llama-*.service` e `~/.local/bin/lmswitch` no Ancalagon — sempre edite aqui e faça `make install`, nunca edite direto no remoto.

## Arquitetura

```
Glaurung (Mac)                    Ancalagon-Ubuntu (100.91.10.22)
aliases no .zshrc                  systemd --user (Conflicts= entre os três):
  llcoder  ──ssh──▶                llama-coder.service   (upstream)
  llq36    ──ssh──▶                llama-qwen36.service  (fork TQ3)
  lloff    ──ssh──▶                lmstudio.service      (DISABLED)
  llstatus ──ssh──▶                     │
                                        ▼
                                   :1234 (OpenAI-compat)
                                        ▲
curl http://100.91.10.22:1234 ──────────┘
```

Porta **1234** (mesma do LM Studio — clientes OpenAI-compat existentes não trocam URL).

## Layout

```
systemd/
  llama-coder.service      # Qwen3-Coder-30B Q4_K_M, --n-cpu-moe 12
  llama-qwen36.service     # Qwen3.6-27B-TQ3_4S, fork turbo-tan/llama.cpp-tq3
bin/
  lmswitch                 # wrapper {coder|qwen36|off|status|logs}
scripts/
  install.sh               # scp + daemon-reload via Tailscale
benchmarks/
  TUNING.md                # dados empíricos (KV quant, ncmoe, TQ3, GPU saturada)
Makefile                   # make install|status|coder|qwen36|off|logs
```

## Decisões de design

- **Services mutuamente exclusivos** (`Conflicts=`) em vez de um único parametrizado. systemd garante atomicamente que só um roda — parametrizado exigiria lógica manual de stop/start e abriria janela de OOM.
- **Porta 1234 nos dois** (não 1234/1235). Clientes existentes não mudam URL; só um service ativo por vez faz conflito impossível.
- **Não habilitados por default** (`systemctl enable` não foi feito). VRAM é compartilhada com outras tarefas eventuais; usuário invoca sob demanda.
- **`--n-cpu-moe 12`** no coder. Flag de llama.cpp que o LM Studio não expõe: coloca só experts do MoE na CPU (attention/norm 100% GPU). Pico em `-ncmoe=12` com headroom; em produção com 32K ctx real ncmoe=10 seria o pico seguro, mas ctx em uso é quase sempre menor.
- **KV q4_0 no coder, q8_0 no qwen36**. Testado: no qwen3.6-27b com offload parcial, KV q4 causa fallback CUDA catastrófico (1 tok/s). No coder MoE com quase tudo na GPU, q4 funciona e economiza VRAM. **Nunca K≠V** — assimetria causa fallback em qualquer modelo.
- **TQ3_4S em vez de Q4_K_M** no qwen3.6. 13 GB cabe 100% GPU; qualidade indistinguível (testei em prompt com bug de concorrência + clock drift, identifica os 3 bugs críticos igual ao Q4_K_M).
- **Caminho absoluto** `/home/lucas/.local/bin/lmswitch` nos aliases do Mac. SSH não-interativo ignora `~/.local/bin` do PATH.

## Deploy

```bash
make install     # scp units + lmswitch, daemon-reload no Ancalagon
make status      # probe do service ativo + health na :1234
make coder       # sobe qwen3-coder
make qwen36      # sobe qwen3.6 TQ3 (mata coder)
make off         # para tudo
make logs        # journalctl -f do service ativo
```

Idempotente — `make install` reexecutado sobrescreve units + wrapper sem efeitos colaterais.

## Uso dos clients (Mac)

Aliases do `.zshrc` do Glaurung — controle + entrada no Claude Code:

```
llcoder && srl-coder    # qwen3-coder 30B MoE, ~80 tok/s
llq36 && srl-tq         # qwen3.6-27b TQ3, ~37 tok/s, 100% GPU, com reasoning
lloff                   # libera a GPU
```

- `llcoder`/`llq36`/`lloff`/`llstatus`/`lllogs` → `ssh` + `lmswitch` (controlam os services)
- `srl-coder` → `local-claude --backend remote --port 1234` (só conecta, reaproveita tuning do service)
- `srl-tq` → `local-claude --backend remote-llama --tq3` (sobe instância via SSH; legacy, usa porta 8091 e binário do fork em `~/git/llama.cpp-tq3/`)
- `srl` → `local-claude --backend remote-llama` (sobe instância via SSH; legacy, lista modelos de `~/models/gguf/`)

**Importante**: `srl` e `srl-tq` sobem **nova instância** do llama-server (porta 8091), enquanto `srl-coder` apenas conecta ao service na 1234. Não rode `srl` enquanto `llama-coder.service` ou `llama-qwen36.service` estão ativos — a nova instância vai competir por VRAM e provavelmente dar OOM. A mesma restrição vale para misturar `llcoder` com `llq36` — os services têm `Conflicts=`, mas `srl`/`srl-tq` não estão sob esse controle.

**Qwen3-Coder não aparece no `srl`** porque vive em `~/.lmstudio/models/` (fora do `$REMOTE_MODELS_DIR=~/models/gguf/`). Isso é intencional: não queremos que o `srl` suba sem `--n-cpu-moe` e rode devagar. Use sempre `llcoder && srl-coder` para esse modelo.

## Pré-requisitos no Ancalagon (não gerenciados por este repo)

- `/home/lucas/git/llama.cpp/build/bin/llama-server` compilado com CUDA sm_89
- `/home/lucas/git/llama.cpp-tq3/build/bin/llama-server` (fork `turbo-tan/llama.cpp-tq3` compilado com mesmas flags)
- Modelos:
  - `/home/lucas/.lmstudio/models/lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`
  - `/home/lucas/models/gguf/Qwen3.6-27B-TQ3_4S.gguf`
- `lmstudio.service` do user systemd: **stopped + disabled** (conflito por VRAM + porta)

Build do llama.cpp upstream e do fork não fazem parte deste repo — ver `project_ancalagon_ubuntu.md` na memória para histórico de setup.

## Performance de referência (para detectar regressões)

Medido em `benchmarks/TUNING.md`. Hardware: Ryzen 5 7600X + RTX 4070 Ti SUPER.

| Service | tok/s gen | pp tok/s | GPU util | Power | VRAM |
|---|---|---|---|---|---|
| llama-coder | 81.5 (prompt 32K) / ~95 (prompt curto) | ~1850 | 36% | 101W | 15.5 GiB |
| llama-qwen36 | 36.8 | 1266 | 96% | 292W | 14.8 GiB |

Cross-machine via Tailscale: 96.4 tok/s gen / 255ms round-trip em prompts pequenos.

Se `make status` + um bench curto (5-par quantum entanglement, 400 tokens) der menos de **60 tok/s no coder** ou **25 tok/s no qwen36**, há regressão — checar primeiro: `nvidia-smi` (GPU ocupada por outro processo?), `journalctl --user -u llama-$MODELO.service` (erro na boot do service), versão do llama.cpp (recompilação do fork pode ter quebrado).

## Convenções

- Shellcheck-clean no `lmswitch` (set -euo pipefail, quote everything)
- Arquivos `.service` sem dependências extras (não referenciam outros units além dos `Conflicts=`)
- Makefile targets mapeiam 1:1 aos subcomandos do lmswitch (exceto `install`)
- Sem dependências externas além das já presentes no Ancalagon (curl, jq, systemd, python3)

## Memórias relacionadas

- `~/.claude/projects/-Users-lucas/memory/project_ancalagon_ubuntu.md` — setup completo do Ancalagon (hardware, drivers, modelos, MOK, Tailscale, rede)
- `~/.claude/projects/-Users-lucas/memory/reference_ancalagon_llm_repo.md` — ponteiro para este repo

## O que NÃO está aqui

- Compilação do llama.cpp / fork TQ3 (manual no Ancalagon)
- Download de modelos (manual no Ancalagon)
- Configuração do Tailscale
- `~/git/local-claude/` — fonte do `local-claude`, que implementa os backends `remote`, `remote-llama`, `llama`, `lmstudio`, `apfel`. Repo separado
- Aliases do Mac `.zshrc` (vivem em `~/.zshrc` do Glaurung — adicionados manualmente, não sincronizados por este repo; documentados aqui e no README para referência)
