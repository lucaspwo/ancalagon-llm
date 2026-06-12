# Design: skill `delegando-ancalagon`

**Data:** 2026-06-12
**Autor:** Lucas + Claude (brainstorming)
**Status:** spec — aguardando review antes do plano de implementação

## Problema

Tokens do Claude Code cloud são escassos e resetam em horário fixo. O Ancalagon
(RTX 4070 Ti SUPER, llama.cpp nativo na `:1234`) é um executor local ocioso a
maior parte do tempo. Hoje a delegação é manual e documentada em
[`docs/delegation.md`](../../delegation.md), mas não há um caminho **headless**
em que o Claude cloud terceirize trabalho sozinho, sem o Lucas conduzir uma TUI.

Objetivo: uma skill que permita ao Claude cloud delegar trabalho ao Ancalagon de
forma automática, cortando os tokens caros de **output** (geração de código) e,
no melhor caso, também as iterações intermediárias.

## Objetivos

- Delegar **geração one-shot** (caso 1): Claude monta briefing → Ancalagon gera
  código/texto → Claude aplica e revisa. Economiza output tokens.
- Delegar **iteração com tools** (caso 2): um Claude Code headless roda no Mac
  (tools reais, repo presente) com inferência na GPU do Ancalagon. Ele
  edita/roda/itera sozinho; o Claude cloud só lê resumo + `git diff`. Economia
  máxima.
- Garantir disponibilidade do Ancalagon antes de delegar (ligar, corrigir SO,
  subir modelo) sem intervenção manual quando possível.
- Proteger o hardware contra superaquecimento sustentado durante a carga.

## Não-objetivos

- **Caso 3 (operacional puro)** — tarefas idênticas repetitivas já são só
  `curl :1234`; não precisam de skill.
- **Decisões arquiteturais / cross-repo / PR** — permanecem no cloud, conforme
  `docs/delegation.md`. A skill não delega julgamento.
- **Caso 4 interativo (transição forçada conduzida pelo Lucas)** — fora do escopo
  desta skill, que é headless. Continua coberto por `srl-coder` manual.
- **Telemetria do conector 12VHPWR** — não há sensor exposto (ver Premissa P2).

## Arquitetura

Dois componentes, em repositórios de execução diferentes:

```
Mac (Glaurung)                              Ancalagon-Ubuntu (100.64.0.10)
~/.claude/skills/delegando-ancalagon/       systemd --user:
  SKILL.md   (instruções p/ Claude)           llama-coder.service   (sob demanda)
  anc-delegate (helper, roda no Mac)          llama-qwen36.service  (sob demanda)
       │                                      llama-gemma4.service  (sob demanda)
       │  caso 1: curl ───────────────────▶   :1234 (OpenAI-compat)
       │  caso 2: local-claude -p ────────▶   :1234 (inferência)
       │                                      gpu-guard.service  (PERSISTENTE, enabled)
       └─ preflight: ssh / WoL / reboot ──▶        │ nvidia-smi polling 5s
                                                   ▼ alerta→espera→corta
```

Fonte versionada neste repo; deploy via `make`. A skill em si é **global**
(`~/.claude/skills/`) porque o Lucas delega trabalho de qualquer projeto, não só
deste repo.

### Componente 1 — skill + helper (Mac)

```
skills/delegando-ancalagon/
  SKILL.md       # instruções: quando usar, heurística de caminho, formato de
                 # briefing, tratamento de falha, leitura do resultado
  anc-delegate   # bash: preflight + disparo + captura
```

Symlinkado para `~/.claude/skills/delegando-ancalagon` por `make install-skill`
(mesmo padrão de `install-gla`). O helper mora **dentro** da pasta da skill
(skill autocontida), invocado por caminho absoluto pela SKILL.md.

Subcomandos do `anc-delegate`:

| Comando | Caminho | Saída |
|---|---|---|
| `anc-delegate gen <briefing.md> [--model M]` | `curl :1234/v1/chat/completions` | resposta do modelo no stdout |
| `anc-delegate iter <briefing.md> [--cwd DIR] [--model M]` | `local-claude --backend remote --port 1234 -p` | resumo JSON (`--output-format json`) |
| `anc-delegate preflight [--model M]` | escada de disponibilidade | estado final + health |
| `anc-delegate health` | snapshot `nvidia-smi` + service ativo | JSON |

### Componente 2 — watchdog térmico (Ancalagon)

```
systemd/gpu-guard.service       # user unit, enabled (sobe no boot)
bin/gpu-guard                   # loop: nvidia-smi a cada 5s, escalonado
```

Deploy junto da infra existente via `make install-system`. Diferente dos
`llama-*.service` (sob demanda), o `gpu-guard` é **enabled** — o risco térmico
existe sempre que um modelo está carregado, inclusive quando o Lucas usa
`srl-coder` sem o cloud no loop. Polling de `nvidia-smi` é leve (custo
desprezível).

## Caminho 1 — geração one-shot (sem tools)

Quando: transformar uma spec fechada em código/texto **sem precisar executar
nada** (boilerplate, suíte de testes para código definido, conversão A→B,
refactor mecânico).

1. Claude cloud monta um **briefing autocontido** (formato de `docs/delegation.md`)
   a partir do que já leu no repo.
2. `anc-delegate gen briefing.md` → `curl` na `:1234`, sem tools, sem ponte de
   protocolo (robusto).
3. Claude cloud recebe o texto, **aplica os arquivos** via Edit/Write, mostra o
   diff e revisa.

Economia: os output tokens (geração) saem do cloud. Claude ainda gasta input
para montar briefing e ler o retorno.

## Caminho 2 — iteração com tools

Quando: a tarefa precisa **rodar/verificar/iterar** — "faça os testes passarem",
lint que corrige, debugging com ciclo tentativa-erro.

1. Claude cloud monta o briefing autocontido.
2. `anc-delegate iter briefing.md --cwd <repo>` →
   `local-claude --backend remote --port 1234 -p "<briefing>" --output-format json`.
   Isso lança um **Claude Code completo no Mac** (tools reais: Read/Edit/Bash, no
   diretório do repo) com toda a inferência na GPU do Ancalagon.
3. O agente headless edita/roda/itera sozinho. Claude cloud recebe um resumo
   curto, roda `git diff` para revisar e reporta.

Economia: máxima — nem as iterações intermediárias nem o output final consomem
tokens cloud; só o briefing inicial e a leitura do resumo.

## Heurística de escolha (na SKILL.md)

- Spec fechada → código/texto, **nada a executar** → **Caminho 1**.
- Precisa **executar/verificar/iterar** → **Caminho 2**.
- Briefing > **40K tokens** → recorte ruim; Claude para e re-planeja (guard-rail
  de `docs/delegation.md`).

## Preflight em escada (no `anc-delegate preflight`)

Antes de qualquer disparo, garantir saúde da `:1234`:

| Estado detectado | Ação |
|---|---|
| SSH ok + `uname`=Linux + service `llama-*` saudável | usa direto |
| Linux up, nenhum service ativo | sobe `coder` (default), espera health (~20–60s) |
| SSH timeout (suspenso / desligado) | WoL (`wakepc`/magic packet), espera boot, sobe modelo |
| Responde mas **é Windows** | **reboot automático** para Linux (ver Premissa P1), espera GRUB cair no Ubuntu, sobe modelo |
| Segue inalcançável após WoL + timeout | **para e reporta** — provável necessidade de acesso físico |

Política de service: se **já há** um `llama-*` ativo, **não troca** (respeita a
escolha do Lucas). Se precisa subir, usa **`coder`** (default da doc).
`--model {coder|qwen36|gemma4}` força um específico. **Nunca desliga** depois —
deixa para o Lucas via `lloff`/`make off`.

Regra de falha (de `docs/delegation.md`): se `ssh`/`curl` falha na primeira
tentativa em um estado não-recuperável, **reporta na hora** com o sintoma exato.
Sem polling silencioso em loop.

## Watchdog térmico `gpu-guard`

Loop a cada **5s** lendo via `nvidia-smi --query-gpu`:
`temperature.gpu`, `temperature.memory`, `power.draw`, `clocks_throttle_reasons.active`.

Dois níveis, escalonado:

- **warning** — métrica acima do limite-W: loga em journal + grava estado em
  `/run/gpu-guard.state`. Não interrompe.
- **critical** — métrica acima do limite-C **sustentada por `HOLD` segundos
  contínuos**: para o `llama-*.service` ativo (`systemctl --user stop`),
  registra o motivo. Evita corte por pico transitório; protege se o calor não
  cede.

Limites (`limite-W`, `limite-C`, `HOLD`) serão **medidos empiricamente** na
implementação — subir cada modelo, observar temp/power em regime sustentado, e
calibrar acima do normal mas abaixo do throttle do driver (~88–90 °C Tjmax).
Referência atual de regime normal (`TUNING.md`): `qwen36` = 292 W / 96 % util —
**power alto sozinho não é anomalia**, a métrica primária é **temperatura
sustentada + throttle**.

Quando o `gpu-guard` corta um service durante uma delegação em curso, o
`anc-delegate` detecta a queda da `:1234`, aborta e reporta ao Claude cloud (que
reporta ao Lucas) — não retenta cegamente.

## Premissas a validar na implementação

- **P0 — `claude -p` headless funciona contra a `:1234`.** O `srl-coder`
  interativo funciona; `-p` só repassa ao mesmo `claude` CLI. Validar logo no
  início com `local-claude --backend remote --port 1234 -p "diga olá"`. Se
  falhar, o Caminho 2 degrada para "prepara o pacote, Lucas conduz".
- **P1 — existe canal remoto headless para o Windows.** Reboot automático
  Windows→Linux exige SSH/WinRM no Windows. A doc só cita RealVNC (GUI) +
  `shutdown /r` manual. Se não houver canal headless, o reboot "automático" é
  impossível sem o Lucas e degrada para "reporta necessidade de ação". O nó
  Windows `.23` no Tailscale é historicamente instável (memória
  `reference_ancalagon_windows_tailscale_unreachable`).
- **P2 — sem telemetria do conector 12VHPWR.** `nvidia-smi`/NVML não expõem
  temperatura do plug. O watchdog protege contra superaquecimento do **chip** e
  detecta **throttle/power anômalo** como *proxy* — não mede o conector. Decisão
  consciente do Lucas (proxy temp+throttle só).

## Instalação (make targets)

- `make install-skill` — symlinka `skills/delegando-ancalagon/` →
  `~/.claude/skills/delegando-ancalagon` (novo).
- `make install-system` — estendido para deployar `systemd/gpu-guard.service` +
  `bin/gpu-guard` e dar `systemctl --user enable --now gpu-guard`.

## Decisões registradas

| # | Decisão | Razão |
|---|---|---|
| D1 | Dois caminhos (curl p/ geração, `local-claude -p` p/ iteração) | Ferramenta certa por tipo; curl evita a ponte de protocolo onde não precisa |
| D2 | Skill global, fonte versionada neste repo | Lucas delega de qualquer projeto; padrão `install-gla` |
| D3 | Helper dentro da pasta da skill | Skill autocontida |
| D4 | Não trocar service ativo; default `coder`; nunca desligar | Respeita escolha do Lucas; `coder` é o default da doc |
| D5 | `gpu-guard` persistente + enabled | Risco térmico independe de quem disparou a carga |
| D6 | Critical escalonado (alerta→espera→corta) | Evita corte por pico transitório, protege se o calor persiste |
| D7 | Proxy temp+throttle (sem sensor de conector) | Limitação de hardware aceita (P2) |
| D8 | Reboot Windows→Linux automático | Escolha do Lucas; condicionado a P1 (canal headless) |
