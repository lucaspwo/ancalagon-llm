# ancalagon-llm

## Visão Geral

Setup do Ancalagon (Ubuntu Server 24.04 dual-boot, RTX 4070 Ti SUPER 16 GB VRAM) como servidor LLM dedicado. Substitui LM Studio por `llama.cpp` nativo controlado por systemd, com dois presets mutuamente exclusivos. Consumido do Mac (Glaurung) via Tailscale em `100.91.10.22:1234`.

**Source of truth** dos artefatos instalados em `~/.config/systemd/user/llama-*.service` e `~/.local/bin/lmswitch` no Ancalagon — sempre edite aqui e faça `make install`, nunca edite direto no remoto.

## Arquitetura

```
Glaurung (Mac)                    Ancalagon-Ubuntu (100.91.10.22)
aliases no .zshrc                  systemd --user (Conflicts= entre os quatro):
  llcoder  ──ssh──▶                llama-coder.service   (upstream)
  llq36    ──ssh──▶                llama-qwen36.service  (fork TQ3)
  llgemma4 ──ssh──▶                llama-gemma4.service  (upstream)
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
  llama-coder.service      # Qwen3-Coder-30B Q4_K_M, --n-cpu-moe 16
  llama-qwen36.service     # Qwen3.6-27B-TQ3_4S, fork turbo-tan/llama.cpp-tq3
  llama-gemma4.service     # Gemma 4 26B-A4B-it Q4_K_M, --n-cpu-moe 16
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
- **`--n-cpu-moe 16`** no coder. Flag de llama.cpp que o LM Studio não expõe: coloca só experts do MoE na CPU (attention/norm 100% GPU). Pico de tok/s ficaria em `ncmoe=12`, mas o service usa 16 porque 96K de ctx (necessário pro Claude Code) só cabe nessa config — ncmoe=12 topava em 64K de ctx e isso estourava com user content +30K-50K. Troca-se ~2% de tok/s (76→78) por +50% de ctx.
- **KV q4_0 no coder, q8_0 no qwen36**. Testado: no qwen3.6-27b com offload parcial, KV q4 causa fallback CUDA catastrófico (1 tok/s). No coder MoE com quase tudo na GPU, q4 funciona e economiza VRAM. **Nunca K≠V** — assimetria causa fallback em qualquer modelo.
- **TQ3_4S em vez de Q4_K_M** no qwen3.6. 13 GB cabe 100% GPU; qualidade indistinguível (testei em prompt com bug de concorrência + clock drift, identifica os 3 bugs críticos igual ao Q4_K_M).
- **Caminho absoluto** `/home/lucas/.local/bin/lmswitch` nos aliases do Mac. SSH não-interativo ignora `~/.local/bin` do PATH.

## Deploy

```bash
make install     # scp units + lmswitch, daemon-reload no Ancalagon
make status      # probe do service ativo + health na :1234
make coder       # sobe qwen3-coder
make qwen36      # sobe qwen3.6 TQ3 (mata coder)
make gemma4      # sobe gemma-4-26b (mata os outros)
make off         # para services (mantém máquina ligada)
make sleep       # para services + suspende o sistema (wake via WoL)
make logs        # journalctl -f do service ativo
```

`make sleep` depende de:
- `/etc/sudoers.d/lucas-nopasswd` com `lucas ALL=(ALL) NOPASSWD: ALL` (decisão consciente — uso pessoal)
- `nvidia-suspend.service`/`nvidia-resume.service`/`nvidia-hibernate.service` **habilitados** (driver `nvidia-open` precisa deles para preservar VRAM em S3 — sem isso `systemd-suspend` falha com "NVRM: PreserveVideoMemoryAllocations ...")
- `/etc/netplan/99-wol.yaml` com `wakeonlan: true` na eno1 (NIC vem com WoL desarmado por padrão)

Todos os três são aplicados por `make install-system` (deploy de `systemd/99-wol.yaml` + `scripts/setup-system.sh`). `NOPASSWD` foi instalado out-of-band na primeira vez.

Acordar após `make sleep`: `make wake` (ou alias `wakepc` no Mac) manda o magic packet via LAN. Uptime contínuo pós-wake confirma resume de S3 (não reboot).

Idempotente — `make install` reexecutado sobrescreve units + wrapper sem efeitos colaterais.

## Uso dos clients (Mac)

Aliases do `.zshrc` do Glaurung — controle + entrada no Claude Code:

```
llcoder && srl-coder    # qwen3-coder 30B MoE, ~80 tok/s
llq36 && srl-tq         # qwen3.6-27b TQ3, ~37 tok/s, 100% GPU, com reasoning
llgemma4                # gemma 4 26B-A4B MoE, ~57 tok/s (alternativa ao coder — ver TUNING §7)
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
  - `/home/lucas/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf`
- `lmstudio.service` do user systemd: **stopped + disabled** (conflito por VRAM + porta)

Build do llama.cpp upstream e do fork não fazem parte deste repo — ver `project_ancalagon_ubuntu.md` na memória para histórico de setup.

## Performance de referência (para detectar regressões)

Medido em `benchmarks/TUNING.md`. Hardware: Ryzen 5 7600X + RTX 4070 Ti SUPER.

| Service | tok/s gen | pp tok/s | GPU util | Power | VRAM |
|---|---|---|---|---|---|
| llama-coder (96K ctx, ncmoe=16) | 77.8 (prompt curto) / 1129 pp (96K prefill) | ~1130 | 36% | 100W | 15.4 GiB (559 MiB livres) |
| llama-qwen36 | 36.8 | 1266 | 96% | 292W | 14.8 GiB |
| llama-gemma4 (96K ctx, ncmoe=16) | 57 (prompt curto) / 49 (12K prefill) | 1940 (12K prefill) | 41% | 83W | 10.0 GiB (5.9 GiB livres — há folga) |

Cross-machine via Tailscale: 96.4 tok/s gen / 255ms round-trip em prompts pequenos.

Se `make status` + um bench curto (5-par quantum entanglement, 400 tokens) der menos de **55 tok/s no coder**, **25 tok/s no qwen36** ou **40 tok/s no gemma4**, há regressão — checar primeiro: `nvidia-smi` (GPU ocupada por outro processo?), `journalctl --user -u llama-$MODELO.service` (erro na boot do service), versão do llama.cpp (recompilação do fork pode ter quebrado).

### Ctx vs tok/s tradeoff (empírico)

| ctx | ncmoe | VRAM livre | tok/s gen | Nota |
|---|---|---|---|---|
| 32K | 12 | ~850 MiB | 82 | Explodia com prompt do Claude Code |
| 64K | 12 | 175 MiB | 76 | Explodia com user content >30K |
| **96K** | **16** | **559 MiB** | **78** | **Atual — suficiente p/ Claude Code real** |
| 128K | 16 | — | OOM no compute buffer | |
| 128K | 20 | 1.1 GiB | 9 | Metade do modelo migra pra CPU — atravessa PCIe a cada token |

**Regra: cada bump de ctx requer bump proporcional de ncmoe.** O KV cache cresce linear com ctx; liberar VRAM exige mover mais experts pra CPU. Mas ncmoe>=20 é o limite útil — acima disso a fração CPU vira maior que GPU e os tokens ficam serializados no PCIe.

Para contexto >96K nesse hardware teria que quantizar o modelo mais agressivamente (Q3_K_M ou similar) — não testado.

## Convenções

- Shellcheck-clean no `lmswitch` (set -euo pipefail, quote everything)
- Arquivos `.service` sem dependências extras (não referenciam outros units além dos `Conflicts=`)
- Makefile targets mapeiam 1:1 aos subcomandos do lmswitch (exceto `install`)
- Sem dependências externas além das já presentes no Ancalagon (curl, jq, systemd, python3)

## Papel do Ancalagon na rotina

O Ancalagon **complementa, não substitui** as sessões Claude Code do cloud. Tem memória finita (96K) e não possui tools avançadas (Git, MCP, memória entre conversas). É um executor local especializado.

Três modos de uso previstos, com guidance detalhado em [`docs/delegation.md`](docs/delegation.md):

1. **Planejar aqui, executar lá** — recortar escopo no cloud, passar briefing autocontido para Ancalagon executar
2. **Transição forçada** — quando o cloud esgota tokens, usar `AI_CONTEXT.md` do projeto como bootstrap de uma sessão local via `srl-coder`
3. **Operacional rotineiro** — tarefas repetitivas via `curl` direto na `:1234`

Regras que valem sempre:
- Conversas >10 turnos com Ancalagon degradam; reset com `AI_CONTEXT.md` atualizado é melhor que iterar em contexto sujo
- Briefing maior que 40K tokens = recorte foi mal; volta pro planejamento
- Decisões arquiteturais / cross-repo / PR: nunca no Ancalagon

## Memórias relacionadas

- `~/.claude/projects/-Users-lucas/memory/project_ancalagon_ubuntu.md` — setup completo do Ancalagon (hardware, drivers, modelos, MOK, Tailscale, rede)
- `~/.claude/projects/-Users-lucas/memory/reference_ancalagon_llm_repo.md` — ponteiro para este repo

## Arquivos de orientação deste repo (por ordem de densidade)

- [`AI_CONTEXT.md`](AI_CONTEXT.md) — bootstrap enxuto (1 página). Primeiro turn ideal para uma sessão nova
- [`CLAUDE.md`](CLAUDE.md) (este arquivo) — guia para trabalhar no repo, inclui threshold de regressão e decisões
- [`README.md`](README.md) — arquitetura detalhada, ganhos medidos, instalação
- [`docs/delegation.md`](docs/delegation.md) — charter cloud↔Ancalagon + boas práticas universais + tratamento de offline
- [`benchmarks/TUNING.md`](benchmarks/TUNING.md) — dados empíricos por trás das configs
- [`benchmarks/POWER.md`](benchmarks/POWER.md) — consumo de energia GPU por estado (dormente / idle / inference)

## O que NÃO está aqui

- Compilação do llama.cpp / fork TQ3 (manual no Ancalagon)
- Download de modelos (manual no Ancalagon)
- Configuração do Tailscale
- `~/git/local-claude/` — fonte do `local-claude`, que implementa os backends `remote`, `remote-llama`, `llama`, `lmstudio`, `apfel`. Repo separado
- Aliases do Mac `.zshrc` (vivem em `~/.zshrc` do Glaurung — adicionados manualmente, não sincronizados por este repo; documentados aqui e no README para referência)
