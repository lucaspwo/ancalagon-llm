# Manutenção — ancalagon-llm

## Arquitetura

Este repo é **infraestrutura operacional**, não uma aplicação: é o conjunto de units systemd, scripts shell e um Makefile que transformam o Ancalagon (Ubuntu Server 24.04 dual-boot, RTX 4070 Ti SUPER 16 GB) num servidor LLM local dedicado, expondo uma API OpenAI-compatível na porta `1234` via Tailscale.

Seis presets de modelo rodam como units systemd `--user` no Ancalagon: cinco via `llama.cpp` (`llama-coder`, `llama-qwen36`, `llama-qwen38`, `llama-gemma4`, `llama-flint`) e um via o engine [Colibrì](https://github.com/JustVugg/colibri) (`colibri-qwen36`, Qwen3.6-35B-A3B com tier CUDA de experts em VRAM). Todos com `Conflicts=` cruzado entre si e com `lmstudio.service` — systemd garante atomicamente que só um está ativo por vez, sem lógica manual de stop/start. `bin/lmswitch` (também no Ancalagon, deployado por este repo) é o wrapper que troca de preset e faz health-check; ele não assume `llama.cpp` — só que o preset serve `/health` e `/v1/chat/completions` em `:1234`.

Do lado do Mac (Glaurung), aliases no `.zshrc` chamam `ssh <remote> lmswitch <subcomando>` — o Makefile deste repo espelha os mesmos subcomandos como `make coder`/`make qwen36`/`make qwen38`/etc. para quem prefere rodar do checkout local. Um segundo componente Mac-side, `clients/glaurung-llm/gla`, replica a mesma UX (mutex de porta + start + troca de modelo) para rodar inferência **localmente** no Mac (llama.cpp Metal ou MLX), sem depender do Ancalagon.

Um terceiro componente, `skills/delegando-ancalagon/`, é uma skill do Claude Code (instalada no Mac) que usa o helper `anc-delegate` para delegar trabalho de código ao Ancalagon de forma headless — liga a máquina, sobe o modelo certo e roda geração one-shot (`gen`) ou uma sessão `local-claude` com tools (`iter`), economizando tokens do Claude Code cloud.

## Mapa de módulos/pastas

| Caminho | Responsabilidade |
|---|---|
| `systemd/llama-*.service` | Units `--user` dos quatro presets `llama.cpp` (fonte de verdade — deploy via `make install`, nunca editar direto no Ancalagon) |
| `systemd/colibri-qwen36.service` | Unit `--user` do 5º preset, engine Colibri (não `llama.cpp`) — tier CUDA, `COLI_ALLOW_INSECURE_BIND=1` |
| `systemd/gpu-guard.service` | Unit `--user` **persistente** (enabled) do watchdog térmico |
| `systemd/99-wol.yaml` | Override netplan que arma Wake-on-LAN na `eno1` |
| `systemd/console-setup` | `/etc/default/console-setup` — fonte do console TTY (ver `docs/console-setup.md`) |
| `bin/lmswitch` | Wrapper que troca entre os cinco presets, faz health-poll, mostra status/logs (roda no Ancalagon) |
| `bin/gpu-guard` | Watchdog térmico da GPU — loop de `nvidia-smi`, corta o service ativo em superaquecimento sustentado |
| `bin/videoswitch` | Toggle de DPMS do console físico via `/sys/class/graphics/fb0/blank` |
| `bin/videoswitch-reblank` + `systemd/90-videoswitch-reblank.rules` | Hook udev (`drm change HOTPLUG=1`) que reapaga o `fb0` quando o hotplug do monitor religa a saída depois de um `videoswitch off` |
| `bin/bootwin` | Reboot one-shot para Windows via `efibootmgr -n` (BootNext) |
| `scripts/install.sh` | Deploy idempotente (scp + daemon-reload) dos units + wrappers para o Ancalagon |
| `scripts/setup-system.sh` | Aplica pré-requisitos de sistema (WoL, `nvidia-suspend/resume/hibernate` se o driver ainda os trouxer, fonte do console, `gpu-guard` habilitado) |
| `scripts/build-llama.sh` | Build do `llama.cpp` (referência; compilação real é manual no Ancalagon) |
| `scripts/bench-presets.py` | Benchmark A/B dos presets (decode + prefill), roda no Ancalagon; método em `benchmarks/TUNING.md` §16 |
| `clients/glaurung-llm/gla` | Wrapper Mac-side: sobe backend local (llama.cpp Metal ou MLX) + abre `opencode` já configurado |
| `clients/glaurung-llm/TUNING.md` | Dados de tuning do lado Mac (não commitado até esta rodada — ver nota de cobertura no relatório) |
| `clients/opencode/opencode.json` | Template de config do `opencode` com os providers `ancalagon/*`, `glaurung/*`, `glaurung-mlx/*` |
| `skills/delegando-ancalagon/anc-delegate` | Helper de delegação headless (preflight + `gen`/`iter`/`health`) |
| `skills/delegando-ancalagon/SKILL.md` | Definição da skill Claude Code (roteamento Caminho 1 vs Caminho 2) |
| `benchmarks/TUNING.md`, `benchmarks/POWER.md` | Dados empíricos brutos por trás das flags atuais |
| `docs/delegation.md` | Charter de delegação cloud↔Ancalagon (três modos de uso, boas práticas) |
| `docs/console-setup.md` | Detalhes da configuração de fonte do console TTY |
| `Makefile` | Todos os `make <target>` — camada fina sobre `ssh` + os scripts de `bin/` |

## Onde ficam as funções-chave

- `bin/lmswitch:27` — `wait_ready()` — poll de até 90s (ou o timeout opcional do 3º argumento) no `/health` do service recém-iniciado, aborta se o service cair
- `bin/lmswitch:50` — `ALL_SERVICES` + `stop_all()` — lista única dos seis nomes de service, usada por todo case que precisa parar os outros antes de subir
- `bin/lmswitch:58` — `case "$COMMAND" in` — dispatch dos subcomandos `coder|qwen36|qwen38|gemma4|flint|colibri|off|sleep|status|logs` (o `flint` espera até 180 s: `wait_ready` aceita timeout opcional; o GGUF de 25 GB levou 75 s a frio)
- `bin/lmswitch:94` — case `sleep|suspend` — para todos os services (via `stop_all`) e dispara `sudo -n systemctl suspend` destacado com `nohup … & disown` para não bloquear a sessão SSH
- `bin/gpu-guard:12` — `WARN_TEMP`/`CRIT_TEMP` — limiares 82°C/86°C calibrados empiricamente (pico normal do die = 77°C sob 320W)
- `bin/gpu-guard:22` — `active_service()` — descobre qual dos seis presets está ativo (`llama-flint` entrou em 2026-11-02) (renomeada de `active_llama` em 2026-09-27 ao corrigir uma lacuna real: a lista estava presa em três nomes — coder/qwen36/gemma4 — e nunca ganhara o `qwen38`, então o watchdog térmico não conseguia cortar esse preset sob superaquecimento; corrigida junto com a entrada do `colibri-qwen36`)
- `bin/gpu-guard:28` — loop principal — polling de `nvidia-smi` a cada `INTERVAL` (5s default), escalona WARN (loga) → CRIT sustentado por `HOLD` (30s) → `systemctl --user stop` do service ativo
- `bin/videoswitch:23` — `require_fb()` — valida que `/sys/class/graphics/fb0/blank` existe antes de qualquer operação
- `bin/videoswitch:30` — dispatch `off|on|status` — escreve em `fb0` via `sudo -n sh -c` e persiste último estado em `/run/videoswitch.state` (o driver `nvidia-drm` retorna vazio na leitura)
- `bin/videoswitch-reblank:22` — loop de reapagar (10 × 0,5 s após cada uevent de hotplug DRM), só se `/run/videoswitch.state` for `off`; conta só conectores `connected` (os desconectados também reportam `dpms=On`)
- `bin/bootwin:13` — parse do `efibootmgr` para achar a entry "Windows Boot Manager"
- `bin/bootwin:21` — extração do `BootNum` via `awk` (valida regex hex de 4 dígitos antes de usar)
- `bin/bootwin:42` — `efibootmgr -n "$WIN_ID"` + `systemctl reboot` destacado (one-shot — firmware consome `BootNext` e o boot seguinte volta ao default)
- `scripts/install.sh:14` — `scp` dos quatro `systemd/llama-*.service` mais `colibri-qwen36.service` para `~/.config/systemd/user/` no Ancalagon
- `scripts/install.sh:19` — `scp` de `lmswitch`/`videoswitch`/`bootwin` para `~/.local/bin/` + `chmod +x` remoto
- `scripts/install.sh:24` — `sudo install` do `videoswitch-reblank` em `/usr/local/bin/` e da regra em `/etc/udev/rules.d/` + `udevadm control --reload`
- `scripts/setup-system.sh:31` — habilita `nvidia-suspend/resume/hibernate.service` só se existirem (pré-requisito do `lmswitch sleep` no driver antigo; a série 615 não os traz mais — o suspend é interno ao driver com `PreserveVideoMemoryAllocations=1`. Até 2026-11-02 a ausência abortava o script inteiro)
- `scripts/setup-system.sh:50` — instala `systemd/99-wol.yaml` em `/etc/netplan/` + `netplan apply`
- `scripts/setup-system.sh:75` — instala `gpu-guard` em `~/.local/bin/`, a unit em `~/.config/systemd/user/` e faz `enable --now`
- `clients/glaurung-llm/gla:16` — `_pids_on_port()` / `:20` `_kill_port()` — descoberta e kill de processo por porta TCP via `lsof`
- `clients/glaurung-llm/gla:47` — `_mutex()` — garante que as portas `1235` (llama.cpp) e `1236` (MLX) estão livres antes de subir um novo backend
- `clients/glaurung-llm/gla:56` — `_start_lcpp_qwen36()` / `:68` `_start_lcpp_gemma4()` — sobem `llama-server` local com as flags tuned (KV q8/q8, `--no-mmap --jinja`)
- `clients/glaurung-llm/gla:80` — `_start_mlx()` — sobe `mlx_lm.server` (lazy load — só carrega modelo na 1ª chamada de `/v1/chat/completions`)
- `clients/glaurung-llm/gla:103` — `_set_opencode_model()` — reescreve `.model` no `opencode.json` via `jq`
- `clients/glaurung-llm/gla:159` — `cmd_run()` — orquestra pre-flight (valida `opencode`/`jq`/config antes de matar o backend antigo) → mutex → start → wait → grava model → `exec opencode`
- `skills/delegando-ancalagon/anc-delegate:36` — `active_service()` — SSH remoto, descobre qual `llama-*.service` está ativo no Ancalagon
- `skills/delegando-ancalagon/anc-delegate:45` — `ensure_model()` — se já há service ativo e saudável, não troca; senão sobe via `lmswitch`
- `skills/delegando-ancalagon/anc-delegate:59` — `wake_and_wait()` — manda `wakeonlan` e faz poll de SSH até `BOOT_TIMEOUT` (120s)
- `skills/delegando-ancalagon/anc-delegate:87` — `preflight()` — escada completa: SSH-Linux vivo? → WoL → Windows-alcançável (reboot forçado)? → erro terminal (não retenta em loop)
- `skills/delegando-ancalagon/anc-delegate:113` — `gen()` — Caminho 1: `curl` one-shot em `/v1/chat/completions`, aborta se o briefing passar de ~40K tokens estimados
- `skills/delegando-ancalagon/anc-delegate:150` — `iter()` — Caminho 2: dispara `local-claude --backend remote -p <briefing> --output-format json` no Mac, inferência remota no Ancalagon
- `skills/delegando-ancalagon/anc-delegate:179` — `health_snapshot()` — JSON com service ativo + temperatura/potência/throttle via `nvidia-smi` remoto

## Fluxos de dados

**Troca de preset (uso normal, do Mac):**
`anc_lin_coder` (alias) → `ssh Anc_U-T lmswitch coder` → `bin/lmswitch:58` dispatch → `stop_all()` para os outros cinco services → `systemctl --user start llama-coder.service` → `wait_ready()` faz poll em `:1234/health` → confirma pronto.

**Deploy de mudança em unit/script:**
Editar `systemd/*.service` ou `bin/*` neste repo → `make install` → `scripts/install.sh` copia via `scp` para `~/.config/systemd/user/` e `~/.local/bin/` no Ancalagon → `systemctl --user daemon-reload` remoto → `make coder`/`make qwen36`/`make qwen38`/`make gemma4`/`make colibri` para reiniciar com a nova config.

**Watchdog térmico:**
`gpu-guard.service` (persistente, sobe no boot) → `bin/gpu-guard` faz loop de `nvidia-smi` → em CRIT sustentado por 30s, chama `systemctl --user stop` no preset ativo, `llama-*` ou `colibri-qwen36` (descoberto via `active_service()`) → o preset cai, GPU esfria; usuário decide se sobe de novo.

**Delegação headless (cloud → Ancalagon):**
Claude Code cloud monta um briefing autocontido → `anc-delegate preflight` garante `:1234` saudável (escada SSH/WoL/reboot Windows) → `anc-delegate gen` (curl one-shot, sem tools) ou `anc-delegate iter` (sobe `local-claude` headless no Mac com inferência remota) → resposta/diff volta para o cloud revisar e integrar.

## Receitas de mudança comuns

**Adicionar um novo preset de modelo:**
1. Criar `systemd/<engine>-<nome>.service` seguindo o padrão dos cinco existentes: `Conflicts=` contra os outros cinco (quatro `llama-*` + `colibri-qwen36` + `lmstudio`), `Type=simple`, `ExecStart` apontando para o binário certo — não precisa ser `llama-server`; `colibri-qwen36.service` roda um engine totalmente diferente (Colibrì) e só precisa satisfazer `:1234` + `/health` + `/v1/chat/completions`.
2. Adicionar `Conflicts=<engine>-<nome>.service` nos outros cinco `.service` existentes (systemd não infere simetria).
3. Adicionar o nome à array `ALL_SERVICES` e o subcomando em `bin/lmswitch:58` (novo case, `stop_all` já para os outros antes de subir).
4. Adicionar o `scp` do novo unit em `scripts/install.sh:14` e o target `make <nome>` no `Makefile`.
5. Rodar `make install` e testar com `make <nome>` + `make status`.
6. Se o preset for um engine novo (não `llama.cpp`), confirmar que `bin/gpu-guard:22` (`active_service()`) já lista o novo nome — senão o watchdog térmico não sabe cortá-lo sob superaquecimento. Esta lista **não** se autoatualiza a partir do `verbs.json`/`lmswitch`; é uma cópia manual, e por isso mesmo ficou 2 presets atrasada antes desta rodada (faltava o `qwen38`).

**Mudar a janela de contexto (`-c`) de um preset:**
1. Editar o valor de `-c` no `ExecStart=` do `.service` correspondente em `systemd/`.
2. Verificar se a mudança exige ajustar `--n-cpu-moe` junto — o KV cache cresce linear com o contexto; mais contexto = menos VRAM livre = precisa mover mais experts pra CPU (ver tabela de tradeoff em `benchmarks/TUNING.md`).
3. Atualizar `clients/opencode/opencode.json` (`limit.context` do provider correspondente) para casar com o novo `-c` — ver `clients/opencode/README.md` § "Limites configurados".
4. `make install` + reiniciar o preset + `make status`.

**Ajustar os limiares térmicos do watchdog:**
1. Editar `WARN_TEMP`/`CRIT_TEMP`/`HOLD` em `bin/gpu-guard:12-14` (ou setar via env `GPU_GUARD_WARN_TEMP`/`GPU_GUARD_CRIT_TEMP`/`GPU_GUARD_HOLD` no unit, se preferir não hardcodar).
2. `make install-system` (reinstala `gpu-guard` + reload da unit) ou `scp bin/gpu-guard` manual + `systemctl --user restart gpu-guard.service`.
3. Validar com `journalctl --user -u gpu-guard.service -f` durante uma carga sustentada.

**Adicionar um novo `make <target>`:**
1. Adicionar o target no `Makefile` (padrão: `@ssh $(REMOTE) /home/lucas/.local/bin/<script> <args>` para operações remotas).
2. Se o alvo chama um script novo em `bin/`, adicionar o `scp` correspondente em `scripts/install.sh`.

## Build / Test / Lint / Deploy

- **Build**: não há build deste repo em si — os binários `llama-server` (upstream e fork TQ3) são compilados manualmente no Ancalagon, fora do escopo deste repo (`scripts/build-llama.sh` é referência, não automatizado por `make`).
- **Test**: não há suíte de testes automatizada. Validação é manual: `make status` + um benchmark rápido de referência (`scripts/bench-presets.py`; prompt fixo "Explain quantum entanglement in 5 paragraphs", 400 tokens) comparado contra os thresholds de regressão documentados em `AI_CONTEXT.md` § "Como testar uma mudança" (coder <55 tok/s, qwen36 <25 tok/s, qwen38 <25 tok/s, gemma4 <40 tok/s, colibri <19 tok/s = regressão).
- **Lint**: os scripts em `bin/` são shellcheck-clean por convenção (`set -euo pipefail`, tudo entre aspas) — não há hook automatizado, rodar `shellcheck bin/*` manualmente antes de commitar mudanças em shell.
- **Deploy**: `make install` (units + wrappers), `make install-system` (pré-requisitos de sistema, uma vez por máquina), `make install-gla` / `make install-skill` (componentes Mac-side). Todos idempotentes — reexecutar sobrescreve sem efeito colateral.

## Gotchas e decisões de design

- **Citações da config envelhecem em silêncio após um sweep de tuning.** Cada `--n-cpu-moe`/`-c` aparece em vários lugares além do `ExecStart=`: o `Description=` do próprio unit, as tabelas de `AI_CONTEXT.md` e `AGENTS.md`, o `make coder` do `README.md`, os "config atual" de `benchmarks/TUNING.md` e `POWER.md`, e o `limit.context` de `clients/opencode/opencode.json`. Já divergiram em quatro pontos simultaneamente (corrigido em 31/jul/2026) — inclusive um `Description=` contradizendo o `ExecStart=` do mesmo arquivo, e o `AI_CONTEXT.md` registrando para o gemma4 o `ncmoe=16` que o próprio sweep havia descartado em favor de `8`. Ao mudar uma flag, atualize as citações **no mesmo commit**; ao investigar um preset, confie apenas no `ExecStart=` (ou `systemctl --user cat <unit>`). Varredura rápida: `git grep -nE "ncmoe|n-cpu-moe|ctx=|98304|40960" -- '*.md'` contra `grep ExecStart systemd/llama-*.service`.
- **Services NÃO são `enabled`** (nem os quatro `llama-*`, nem o `colibri-qwen36`, nem no boot). Decisão consciente: VRAM é recurso compartilhado com tarefas eventuais (fine-tuning, testes), então o boot fica limpo e a escolha de preset é sempre explícita. Exceção: `gpu-guard.service` **é** `enabled` — o risco térmico existe sempre que qualquer modelo está carregado, incluindo sessões sem o cloud no loop.
- **Mesma porta `1234` nos cinco presets.** Não é 1234/1235/1236 — `Conflicts=` já garante exclusão mútua, então manter a porta fixa evita que qualquer cliente precise trocar de URL ao trocar de modelo.
- **KV cache assimétrico (K≠V) causa fallback catastrófico no Qwen3.6-27B** — testado e reproduzido: cai para ~1 tok/s. Por isso `llama-qwen36.service` usa `q8_0` em ambos; nunca reduzir só um dos dois lados sem testar de novo.
- **`nvidia-smi` não expõe a temperatura do conector 12VHPWR.** `gpu-guard` é proxy temp+throttle (die temp), não uma medição direta do plug — limitação consciente, documentada em `benchmarks/TUNING.md` §thermal.
- **`videoswitch off` corta o sinal de verdade** (validado fisicamente em 2026-11-02: os conectores vão a `dpms=Off` e os monitores apagam), **mas o hotplug desfaz**: o monitor DisplayPort, ao entrar em sono profundo, derruba o HPD; o `nvidia-drm` vê hotplug, o fbcon refaz o modeset e religa a saída (medido: 11 s e ~160 s depois do `off`, com `nv_drm_handle_hotplug_event` no `dmesg`). Por isso existe o `videoswitch-reblank` (regra udev). Sintoma de regressão: `make video-status` mostra `last set: off` mas `cat /sys/class/drm/card2-*/dpms` dá `On` num conector `connected`; o helper loga em `journalctl -t videoswitch-reblank`. O `setupcon` (passo de fonte do `make install-system`) religa a saída **sem** hotplug — o `setup-system.sh` reapaga logo depois se o estado for `off`. Validado em campo: a regra reapagou hotplugs reais às 20:19 de 2026-11-02.
- **Caminho absoluto obrigatório nos aliases SSH do Mac** (`/home/lucas/.local/bin/lmswitch`, não `lmswitch` via `$PATH`) — sessões SSH não-interativas não carregam o `PATH` customizado do shell interativo.
- **`bootwin` é one-shot por design** — o firmware UEFI consome o `BootNext` no boot seguinte e volta ao `BootOrder` default (Ubuntu). Não há necessidade de "desarmar" depois.
- **`gla` (Mac-side) usa mutex de processo via `lsof`/`kill`, não systemd** — não há `Conflicts=` equivalente no macOS; a exclusão mútua entre `llama.cpp` (porta 1235) e MLX (porta 1236) é garantida manualmente pelo script antes de cada start (`_mutex()` em `clients/glaurung-llm/gla:47`).
- **`opencode.json` versionado usa IP placeholder** (`100.64.0.10`) — o IP Tailscale real do Ancalagon é diferente por máquina; ao instalar, substituir com `sed` conforme `clients/opencode/README.md`.

## Dependências e integrações

- **Tailscale** — conectividade Mac↔Ancalagon; MagicDNS (`ancalagon-ubuntu`) é usado por `anc-delegate`, IP fixo é usado nos aliases legados do `.zshrc`.
- **llama.cpp upstream + fork `turbo-tan/llama.cpp-tq3`** — compilados manualmente no Ancalagon (CUDA sm_89), fora do escopo deste repo. Pré-requisito não gerenciado.
- **Modelos GGUF** — baixados manualmente para `~/.lmstudio/models/…` e `~/models/gguf/…` no Ancalagon. Não versionados aqui.
- **`opencode`** (Mac) — cliente TUI que consome a API OpenAI-compatível dos presets, tanto via Ancalagon quanto via backends locais do `gla`.
- **`local-claude`** (repo separado, `~/git/local-claude/`) — implementa os backends `remote`/`remote-llama`/`llama`/`lmstudio`/`apfel` usados pelos aliases `srl-coder`/`srl-tq`/`srl` e pelo `anc-delegate iter`.
- **Claude Code (skill `delegando-ancalagon`)** — instalada via symlink em `~/.claude/skills/` pelo `make install-skill`; consome `anc-delegate` para delegação headless.
- **sudoers `/etc/sudoers.d/lucas-nopasswd`** — `NOPASSWD: ALL` para o usuário `lucas` no Ancalagon, necessário para `lmswitch sleep`, `videoswitch`, `bootwin` operarem sem prompt via SSH. Instalado manualmente fora deste repo (uso pessoal, máquina não compartilhada).
- **MLX (`mlx_lm.server`)** — dependência Python opcional no Mac (venv `~/.venvs/mlx/`), usada pelo backend `gemma4`/`qwen36` (sem sufixo `-lcpp`) do `gla`.
