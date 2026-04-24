# ancalagon-llm

Setup do Ancalagon (Ubuntu Server 24.04 dual-boot) como servidor LLM dedicado, otimizado para GPU RTX 4070 Ti SUPER (16 GB VRAM). Substitui LM Studio por `llama.cpp` nativo controlado por systemd, com três presets mutuamente exclusivos: Qwen3-Coder 30B (MoE upstream), Qwen3.6-27B (fork TQ3) e Gemma 4 26B-A4B-it (MoE upstream).

Consumido do Mac (Glaurung) via Tailscale em `100.91.10.22:1234`.

## Motivação

LM Studio estava deixando ~50% de tok/s na mesa: GPU util em 30-34% durante inferência, ~70W (de 285W TGP). Dois gargalos identificados:

1. **Offload parcial genérico** — LM Studio divide "N% das camadas na GPU". Para MoE isso é sub-ótimo: o que importa é colocar attention/norm na GPU e experts na CPU. A flag `-n-cpu-moe` do llama.cpp faz exatamente isso. LM Studio não expõe.
2. **Modelo maior que VRAM** — Qwen3.6-27B Q4_K_M tem 17 GB. Com TQ3_4S (3-bit ternary, fork `turbo-tan/llama.cpp-tq3`) cai para 13 GB e cabe 100% em GPU. Diferença: GPU util passa de 34% a 96%, power de 94W a 292W, throughput de 13.7 a 36.8 tok/s.

## Ganhos medidos

| Configuração | GPU util | Power | tok/s gen | pp tok/s |
|---|---|---|---|---|
| LM Studio — qwen3-coder Q4_K_M offload 0.80 | 30% | 67W | 64.5 | ~850 |
| **llama-server upstream — qwen3-coder `-ncmoe 10`** | 36% | 101W | **81.5** | **~1850** |
| LM Studio — qwen3.6-27b Q4_K_M offload 0.85 | 34% | 94W | 13.7 | ? |
| **llama-server TQ3 fork — Qwen3.6-27B-TQ3_4S** | **96%** | **292W** | **36.8** | **1266** |

Cross-machine via Tailscale: 96.4 tok/s gen no coder, 255ms round-trip em prompts pequenos.

## Arquitetura

```
Glaurung (Mac)                    Ancalagon-Ubuntu
                                  (100.91.10.22 / 192.168.1.8)
aliases:                          systemd --user:
  llcoder  ──────ssh─────▶        llama-coder.service ──┐
  llq36    ──────ssh─────▶        llama-qwen36.service ─┤
  llgemma4 ──────ssh─────▶        llama-gemma4.service ─┼─ Conflicts=
  lloff    ──────ssh─────▶        (lmstudio.service    ─┘  (only one up)
  llstatus ──────ssh─────▶        + disabled)
                                       │
                                       ▼
                                  :1234 (OpenAI-compat API)
                                       ▲
curl http://100.91.10.22:1234 ─────────┘
```

Porta **1234** (mesma do LM Studio — clientes existentes não precisam mudar URL).

## Componentes

### `systemd/llama-coder.service`

Upstream llama.cpp com Qwen3-Coder-30B-A3B-Instruct Q4_K_M. Flags:

- `--n-cpu-moe 12` — primeiras 12 camadas de experts na CPU, restante + attention/norm na GPU
- `-c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 16` (ctx 96K; prefere-se ncmoe maior para caber contexto longo vs ncmoe=12 com ctx menor — ver TUNING.md)
- Bind `0.0.0.0:1234`, `Conflicts=llama-qwen36.service lmstudio.service`

### `systemd/llama-qwen36.service`

Fork `turbo-tan/llama.cpp-tq3` com Qwen3.6-27B-TQ3_4S (13 GB, cabe 100% GPU).

- `-c 40960 -ngl 99 -fa 1 -ctk q8_0 -ctv q8_0 -t 12` (KV q8, não q4 — experiência mostra q4 causa fallback CUDA catastrófico nesse modelo; ctx limitado pela VRAM — 48K+ daria OOM com ~770 MiB de folga original)
- Mesmo `Conflicts=`

### `systemd/llama-gemma4.service`

Upstream llama.cpp com Gemma 4 26B-A4B-it Q4_K_M (16 GB em disco, MoE com 4B ativos). Mesmo binário do coder.

- `-c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 16 --jinja` (config inicial espelha a do coder; medido após primeiro boot — 57 tok/s gen, 10 GiB VRAM usada, 5.9 GiB livre — há folga pra baixar ncmoe e ganhar tok/s, ver `benchmarks/TUNING.md` §7)
- Bind `0.0.0.0:1234`, `Conflicts=llama-coder.service llama-qwen36.service lmstudio.service`

### `bin/lmswitch`

Wrapper que:
- Alterna entre services respeitando o `Conflicts=`
- Faz health-poll em `/health` após start (timeout 90s)
- `status` mostra state dos 3 services + probe :1234
- `logs` segue journal do service ativo

Uso:
```
lmswitch coder    # sobe qwen3-coder
lmswitch qwen36   # sobe qwen3.6 TQ3
lmswitch gemma4   # sobe gemma-4-26b
lmswitch off      # para tudo
lmswitch status
lmswitch logs
```

Tempos de start observados:
- coder (17 GB Q4_K_M): 57s primeira vez, ~20s com mmap cacheado
- qwen36 (13 GB TQ3_4S): 26s

## Instalação no Ancalagon

Pré-requisitos já presentes (ver memória `project_ancalagon_ubuntu`):
- `~/git/llama.cpp/build/bin/llama-server` compilado com CUDA sm_89
- `~/git/llama.cpp-tq3/build/bin/llama-server` idem
- Modelos em `~/.lmstudio/models/…/Q4_K_M.gguf` e `~/models/gguf/Qwen3.6-27B-TQ3_4S.gguf`

Instalação:
```bash
# Parar LM Studio (se ativo)
systemctl --user stop lmstudio.service
systemctl --user disable lmstudio.service

# Units
cp systemd/llama-coder.service systemd/llama-qwen36.service ~/.config/systemd/user/
systemctl --user daemon-reload

# Wrapper
cp bin/lmswitch ~/.local/bin/lmswitch
chmod +x ~/.local/bin/lmswitch

# Aliases (remoto, opcional)
cat >> ~/.zshrc <<'EOF'

alias llcoder="lmswitch coder"
alias llq36="lmswitch qwen36"
alias llgemma4="lmswitch gemma4"
alias lloff="lmswitch off"
alias llstatus="lmswitch status"
alias lllogs="lmswitch logs"
EOF
```

Services **não são habilitados por default** — boot não sobe nada. Usuário invoca sob demanda.

## Integração Mac (cliente Tailscale)

Já aplicado no `~/.zshrc` do Glaurung:

```zsh
export REMOTE_SSH_HOST="Ancalagon_Ubuntu-Tailnet"
export LCC_HOST="100.91.10.22"

# Controle dos services (ssh remoto → lmswitch)
alias llcoder='ssh "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch coder'
alias llq36='ssh "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch qwen36'
alias llgemma4='ssh "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch gemma4'
alias lloff='ssh "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch off'
alias llsleep='ssh "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch sleep'
alias llstatus='ssh "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch status'
alias lllogs='ssh -t "$REMOTE_SSH_HOST" /home/lucas/.local/bin/lmswitch logs'
export ANCALAGON_LLM_URL="http://${LCC_HOST}:1234/v1"

# Entrar no Claude Code apontando pro service ativo (local-claude em ~/git/local-claude)
# srl-coder usa backend `remote` (só conecta, não sobe instância) → aproveita tuning do service
alias srl-coder='specstory run claude -c "local-claude --backend remote --port 1234" --no-cloud-sync'
alias srl-tq='specstory run claude -c "local-claude --backend remote-llama --tq3" --no-cloud-sync'
alias srl='specstory run claude -c "local-claude --backend remote-llama" --no-cloud-sync'
```

Caminho absoluto no lmswitch é necessário — SSH não-interativo ignora `~/.local/bin`.

### Fluxo típico de uso

```zsh
# Trabalho em código (MoE rápido, ~80 tok/s)
llcoder && srl-coder

# Thinking/análise com reasoning (TQ3, ~37 tok/s, 100% GPU)
llq36 && srl-tq

# Liberar GPU (service parado, sistema ligado)
lloff

# Suspender o sistema inteiro (usa WoL do Mac para acordar)
llsleep
```

### Variante `_vpn` (via Mac Mini do Ricardo como bridge)

Para casos onde SSH direto do Mac para `Ancalagon_Ubuntu-Tailnet` não está viável (rede restrita, hop específico), existe o par simétrico via Mac Mini `100.91.10.28` (mesma LAN física do Ancalagon):

```zsh
alias wakepc_vpn='ssh -t lucas@100.91.10.28 "zsh -ilc wakepc"'
alias llsleep_vpn='ssh -o ConnectTimeout=10 lucas@100.91.10.28 \
  "ssh -o ConnectTimeout=5 lucas@192.168.1.8 /home/lucas/.local/bin/lmswitch sleep"'
```

O Mac Mini faz broadcast WoL na LAN (único lugar onde magic packet alcança o Ancalagon) e, pra suspend, SSH via IP local `192.168.1.8`. Dependência: Mac Mini ligado + chave SSH do `100.91.10.28` instalada para `lucas@192.168.1.8` (foi instalado em 2026-04-24).

### Pré-requisitos no Ancalagon

O `llsleep` exige três pré-requisitos no Ancalagon, aplicados por `make install-system`:
- `/etc/sudoers.d/lucas-nopasswd` (NOPASSWD — feito manualmente na primeira vez)
- `nvidia-suspend/resume/hibernate.service` habilitados (driver `nvidia-open` falha suspend sem eles)
- `/etc/netplan/99-wol.yaml` armando WoL na eno1 (default é desarmado)

Depois do wake via WoL os services **não sobem automaticamente** (`enabled` continua off) — rodar `llcoder` ou `llq36` conforme o caso.

**Por que `srl-coder` usa `--backend remote` e não `--backend remote-llama`?**
`remote-llama` sobe uma *nova* instância via SSH com flags default (`-ngl 99` apenas — sem `--n-cpu-moe`). Para o Qwen3-Coder 30B MoE isso dá OOM ou inferência muito lenta. `remote` apenas conecta ao server existente, aproveitando as flags tuned do `llama-coder.service` (`--n-cpu-moe 16`, KV q4/q4, 96K ctx). Mesma razão pela qual o modelo **não aparece no listing do `srl`**: o `local-claude` lista só `$REMOTE_MODELS_DIR=~/models/gguf/` e o Qwen3-Coder vive em `~/.lmstudio/models/...` — mas isso é irrelevante quando se usa `srl-coder`, porque ele nem tenta listar, só conecta ao :1234.

## `benchmarks/`

Dados brutos do tuning que levaram a essas configs (KV quant wrapper, ncmoe sweep, ubatch sweep, GPU util telemetry). Ver `benchmarks/README.md`.

## Decisões arquiteturais

**Por que services mutuamente exclusivos (`Conflicts=`) e não um único service parametrizado?**
`Conflicts=` garante atomicamente que só um está rodando — systemd para o outro antes de subir o novo. Um único service + env var exigiria lógica manual de parar/restart e abriria janela onde ambos poderiam rodar em erro de OOM. `Conflicts=` faz isso grátis.

**Por que ambos na porta 1234?**
Mesma porta do LM Studio; clientes OpenAI-compat existentes (Claude Code, Open WebUI, scripts) continuam funcionando sem mudar URL. Troca é transparente.

**Por que `TQ3_4S` em vez de Q3_K_M upstream?**
Testei: TQ3 gera 36.8 tok/s, cabe 13 GB, qualidade perceptível equivalente ao Q4_K_M no mesmo modelo (valida bugs de concorrência e clock drift num rate-limiter bugado com precisão igual). Upstream Q3_K_M nunca foi testado mas não valeria o download — TQ3 já cumpre o papel.

**Por que não habilitar auto-start?**
VRAM é compartilhada com outras tarefas eventuais (sessões de fine-tuning, testes). Subir automaticamente no boot força escolha que nem sempre é desejada. Invocação explícita é clara.

## Tuning descoberto e não óbvio

Consolidado em `benchmarks/TUNING.md`. Resumo:
- KV quant no LM Studio exige wrapper `{checked:true, value:"q4_0"}` — sem isso o campo é silenciosamente ignorado (cache fica em f16)
- K e V assimétricos (K=q8 V=q4) → fallback CUDA catastrófico no qwen3-coder (3 tok/s)
- `-ncmoe 12` é o pico empírico no Qwen3-Coder 30B (ncmoe=10 em produção por segurança de VRAM)
- ubatch default 512 já satura; subir para 1024/2048 dá <2% de ganho
- cpuThreadPoolSize=12 (SMT completo no Ryzen 7600X 6c/12t) vs default 9 → +5-8% em MoE
