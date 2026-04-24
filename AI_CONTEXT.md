# AI_CONTEXT — ancalagon-llm

Bootstrap de contexto para assistentes (humanos ou LLMs) que vão trabalhar neste repo sem histórico prévio. Seguir a convenção dos projetos Intellissis: cada repo tem um `AI_CONTEXT.md` enxuto que cabe como primeiro turn de uma sessão Claude/Qwen/etc.

> **Para quem consome isto via Ancalagon** (`srl-coder` ou `curl`): leia primeiro [`docs/delegation.md`](docs/delegation.md), especialmente a seção "Boas práticas para quem recebe uma tarefa".

## O que este repo faz

Provisionamento operacional do **Ancalagon-Ubuntu** como servidor LLM local dedicado, exposto via Tailscale em `100.91.10.22:1234` com API OpenAI-compatível. Substitui a instalação anterior baseada em LM Studio por `llama.cpp` nativo controlado por systemd.

Não inclui: compilação do `llama.cpp`, download de modelos, configuração de Tailscale, ou código do Mac client (`local-claude`). Ver "O que NÃO está aqui" em [`CLAUDE.md`](CLAUDE.md).

## Hardware e ambiente

- Máquina: Ancalagon (dual-boot Windows + Ubuntu Server 24.04)
- GPU: NVIDIA RTX 4070 Ti SUPER, 16 GB VRAM, CUDA 13.2
- CPU: Ryzen 5 7600X (6c/12t)
- Acesso: SSH por chave a `Ancalagon_Ubuntu-Tailnet` (Tailscale `100.91.10.22`, LAN `192.168.1.8`)

## Arquitetura em uma tela

```
Glaurung (Mac)                        Ancalagon-Ubuntu
aliases .zshrc                         systemd --user (Conflicts= entre si):
  llcoder  ──ssh──▶                    llama-coder.service   (upstream)
  llq36    ──ssh──▶                    llama-qwen36.service  (fork TQ3)
  lloff    ──ssh──▶                    lmstudio.service      (DISABLED)
  srl-coder                                 │
  srl-tq                                    ▼
                                       :1234 (OpenAI-compat)
                                            ▲
curl http://100.91.10.22:1234 ──────────────┘
```

Dois services mutuamente exclusivos (`Conflicts=`), ambos na :1234. LM Studio service foi desabilitado em `2026-04-22` e **não deve voltar** — a razão está em [`benchmarks/TUNING.md`](benchmarks/TUNING.md) (LM Studio subutilizava GPU em ~35% de utilização vs 96% com llama.cpp nativo + quant TQ3).

## Artefatos mantidos por este repo

| Arquivo | O que é | Onde vai |
|---|---|---|
| `systemd/llama-coder.service` | user unit — Qwen3-Coder 30B MoE, `--n-cpu-moe 16`, KV q4/q4, ctx 96K | `~/.config/systemd/user/` no Ancalagon |
| `systemd/llama-qwen36.service` | user unit — Qwen3.6-27B TQ3_4S (fork), KV q8/q8, ctx 32K | idem |
| `bin/lmswitch` | wrapper com subcomandos `coder\|qwen36\|off\|status\|logs` | `~/.local/bin/` no Ancalagon |
| `scripts/install.sh` | deploy idempotente via scp + daemon-reload | — (roda do Mac) |
| `Makefile` | targets `install`/`coder`/`qwen36`/`off`/`status`/`logs` | — |

## Decisões não-óbvias

1. **Mesma porta 1234 nos dois services** (não 1234/1235). `Conflicts=` garante exclusão mútua, clientes existentes não trocam URL.
2. **`--n-cpu-moe 16` no coder, não `--n-cpu-moe 12`** (que seria o pico de tok/s). Trocou-se ~2% de velocidade por +50% de contexto (64K → 96K), porque o system prompt do Claude Code sozinho já consome ~32K.
3. **KV q4/q4 no coder, q8/q8 no qwen36**. No qwen3.6 com offload parcial, K≠V quebra CUDA flash-attn e cai para 1 tok/s. No coder MoE quase tudo na GPU, q4 simétrico funciona e libera VRAM.
4. **TQ3_4S em vez de Q4_K_M no qwen3.6**. 13 GB cabe 100% GPU; qualidade perceptível equivalente (validado contra bug de rate-limiter com concorrência + clock drift).
5. **Services NÃO são `enabled`**. Boot limpo não sobe nada; Lucas invoca sob demanda. Decisão consciente — VRAM é compartilhada com outras tarefas eventuais.

## Estado atual (2026-04-24)

- Services rodando com `ctx=96K` no coder, `ctx=32K` no qwen36
- Documentação em 3 arquivos: `README.md` (arquitetura), `CLAUDE.md` (visão para futuras sessões Claude), `docs/delegation.md` (charter para delegação do cloud para Ancalagon)
- Mac `.zshrc` tem aliases `llcoder`/`llq36`/`lloff`/`llstatus`/`lllogs` (controle) e `srl-coder`/`srl-tq`/`srl` (entrada no Claude Code)
- `lmstudio.service` stopped + disabled no Ancalagon (conflito de VRAM e porta com os llama services)

## Como testar uma mudança

```bash
# Editar aqui (systemd/, bin/)
# Deploy via scp + daemon-reload
make install

# Restart do service afetado
make coder     # ou make qwen36

# Verificar saúde
make status

# Bench rápido: prompt de "quantum entanglement 5 paragraphs", 400 tokens
# Thresholds de regressão:
#   coder: <55 tok/s = regressão
#   qwen36: <25 tok/s = regressão
```

## Próximos passos potenciais

Não planejados, só registrados como ideias que surgiram durante o tuning:

- **Quant mais agressivo do coder** (Q3_K_M ou IQ3_M) se quisermos ctx >96K no mesmo hardware
- **Observabilidade**: endpoint Prometheus ou log estruturado para auditoria de uso
- **Integração com Open WebUI** para conversa web direta sem Claude Code

## Onde mais procurar

- [`CLAUDE.md`](CLAUDE.md) — guia para futuras sessões do Claude Code; inclui threshold de regressão e "O que NÃO está aqui"
- [`docs/delegation.md`](docs/delegation.md) — charter de delegação cloud↔Ancalagon, boas práticas universais para qualquer assistente, e tratamento de Ancalagon offline
- [`benchmarks/TUNING.md`](benchmarks/TUNING.md) — dados empíricos que levaram às configs atuais (KV quant armadilha, sweep `-ncmoe`, TQ3 vs Q4_K_M)
- `~/.claude/projects/-Users-lucas/memory/project_ancalagon_ubuntu.md` — memória Claude com histórico completo de setup do Ancalagon (drivers NVIDIA, MOK, compilação llama.cpp, modelos)
