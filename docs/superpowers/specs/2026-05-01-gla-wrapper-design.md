# `gla` — wrapper único para LLM local + opencode (Glaurung)

**Data:** 2026-05-01
**Status:** spec aprovado, pendente de implementação
**Escopo:** Glaurung (Mac M4 Pro 24 GB) — Ancalagon não é tocado

## Motivação

Hoje, subir um modelo LLM local no Mac e usá-lo via opencode exige 3 passos manuais:

```bash
glau_lcpp_off          # garantir que nada está rodando
glau_mlx_up            # ou glau_lcpp_gemma4 / glau_lcpp_qwen36
opencode               # abrir TUI → /model glaurung-mlx/... (manual)
```

Erros frequentes:
- esquecer de matar o backend anterior → conflito de porta ou OOM
- esquecer o `/model X` no opencode → fica usando o provider anterior
- combinação MLX + llama.cpp simultânea → causou kernel panic do Mac em 2026-05-01 (panic em `IOGPUMemory.cpp:550`, ver conversa SpecStory)

O Ancalagon resolveu o problema equivalente com `Conflicts=` no systemd e wrapper `lmswitch`. Este spec replica essa UX no Mac, no nível certo (processo de usuário, não systemd), e renomeia os aliases para o prefixo `gla_*` por consistência com `anc_*`.

## Princípios de design

1. **Mutex local explícito.** Antes de subir qualquer backend, mata todos PIDs nas portas 1235 (llama.cpp) e 1236 (MLX). Sem pidfile (mente quando processo morre sem cleanup); checa `lsof` na porta direto.
2. **Caminho dourado curto, override explícito.** `gla gemma4` = MLX (vencedor do bench). `gla gemma4-lcpp` = override para llama.cpp.
3. **Reescrita atômica do `opencode.json`.** `jq` + `mv` no mesmo FS. Modelo escolhido vira o default do TUI sem digitar `/model X`.
4. **Glaurung-only.** Não orquestra Ancalagon. Mutex cross-machine via SSH adiciona pontos de falha (Tailscale offline, SSH lock) sem ganho proporcional para uso interativo.
5. **Server vive além do TUI.** `gla gemma4` é foreground; ao sair do opencode, o servidor LLM continua UP. Reabrir `opencode` é instantâneo. Para liberar GPU: `gla off`.

## Comando: catálogo

```
gla gemma4         # MLX, porta 1236, modelo glaurung-mlx/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit
gla qwen36         # MLX, porta 1236, modelo glaurung-mlx/mlx-community/Qwen3.6-27B-4bit
gla gemma4-lcpp    # llama.cpp Metal, porta 1235, modelo glaurung/gemma4
gla qwen36-lcpp    # llama.cpp Metal, porta 1235, modelo glaurung/qwen36
gla off            # mata 1235 + 1236, NÃO abre opencode
gla status         # imprime estado dos dois backends, NÃO abre opencode
```

## Fluxo

```
gla gemma4
  ├── _mutex(): mata PIDs em :1235 e :1236, espera porta livre (timeout 5s)
  ├── _start_backend(mlx, gemma4): nohup mlx_lm.server ... > /tmp/gla-mlx.log
  ├── _wait_ready(:1236, timeout 30s): poll GET /v1/models até 200 OK
  ├── _set_opencode_model(glaurung-mlx/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit):
  │     jq '.model = $m' opencode.json > .tmp && mv .tmp opencode.json
  └── exec opencode
```

Se qualquer passo antes do `exec opencode` falhar, aborta com mensagem clara e código ≠ 0. Servidor parcialmente subido NÃO é deixado rodando — `_mutex` é chamado de novo no cleanup trap.

## Mapa de modelos

Hardcoded no script — não é configurável (YAGNI; se surgir um terceiro modelo, edita-se a tabela).

| `gla <arg>` | backend | porta | model id no opencode.json |
|---|---|---|---|
| `gemma4` | MLX | 1236 | `glaurung-mlx/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit` |
| `qwen36` | MLX | 1236 | `glaurung-mlx/mlx-community/Qwen3.6-27B-4bit` |
| `gemma4-lcpp` | llama.cpp | 1235 | `glaurung/gemma4` |
| `qwen36-lcpp` | llama.cpp | 1235 | `glaurung/qwen36` |

## Estrutura de arquivos

```
clients/glaurung-llm/
  gla                    # script bash (executável, versionado)
  TUNING.md              # já existe
```

Instalação: target novo no `Makefile`:

```
install-gla:
	ln -sf $(PWD)/clients/glaurung-llm/gla $(HOME)/.local/bin/gla
```

`make install` (existente) **não** é alterado — instala artefatos do Ancalagon via SSH. `install-gla` é separado porque é puramente local.

## Rename `glau_*` → `gla_*`

Aplicado a **aliases/funções zsh e arquivos de log apenas**. Não renomeia providers opencode, nome da máquina, nem diretórios de código.

### `~/.zshrc` (linhas 262-361)

| Antes | Depois |
|---|---|
| `_GLAU_LCPP_LOG` | `_GLA_LCPP_LOG` |
| `_glau_lcpp_kill` | `_gla_lcpp_kill` |
| `glau_lcpp_qwen36` | `gla_lcpp_qwen36` |
| `glau_lcpp_gemma4` | `gla_lcpp_gemma4` |
| `glau_lcpp_off` | `gla_lcpp_off` |
| `glau_lcpp_logs` | `gla_lcpp_logs` |
| `glau_lcpp_status` | `gla_lcpp_status` |
| `_GLAU_MLX_LOG` | `_GLA_MLX_LOG` |
| `_glau_mlx_kill` | `_gla_mlx_kill` |
| `glau_mlx_up` | `gla_mlx_up` |
| `glau_mlx_off` | `gla_mlx_off` |
| `glau_mlx_logs` | `gla_mlx_logs` |
| `glau_mlx_status` | `gla_mlx_status` |
| `glau_off` | `gla_off` |
| `glau_status` | `gla_status` |
| comentários do header (`#   glau_*`) | `#   gla_*` |

### Arquivos de log

| Antes | Depois |
|---|---|
| `/tmp/glau-lcpp.log` | `/tmp/gla-lcpp.log` |
| `/tmp/glau-mlx.log` | `/tmp/gla-mlx.log` |

### Repositório

Nenhum arquivo do repo referencia os aliases `glau_*` textualmente (verificado por `grep -rn 'glau_' --include='*.md' --include='*.json'`). Todas as menções a `glaurung` no repo são ao **provider opencode** (`glaurung`, `glaurung-mlx`) ou ao nome da máquina — não tocados pelo rename.

Sem alias de compatibilidade. Migração one-shot — terminais antigos rodam `source ~/.zshrc` ou abrem nova shell.

## Tratamento de erro

| Cenário | Comportamento |
|---|---|
| Porta ainda ocupada após 5s de kill | `gla` aborta, código 1, mensagem indica PID que não morreu |
| Backend não fica ready em 30s | `gla` mata o que subiu, aborta, mensagem indica path do log |
| `jq` falha (config inválido) | `gla` aborta ANTES de matar backend antigo (validação first), preserva opencode.json |
| `opencode.json` ausente em `~/.config/opencode/` | `gla` aborta com mensagem explícita |
| `mlx_lm.server` ou `llama-server` não no PATH | `gla` aborta antes de qualquer kill |
| Argumento desconhecido (`gla foo`) | imprime catálogo, código 1 |

`set -euo pipefail` no script. Trap em `EXIT` faz cleanup do `$tmpfile` do jq se ainda existir.

## Decisões explícitas (non-goals)

- **Não detecta** se já está rodando o modelo pedido — sempre mata e re-sobe. Custo: ~10s extras de carga. Ganho: previsibilidade (sem código condicional, sem state).
- **Não restaura** o modelo anterior do opencode.json no exit. O usuário escolheu este modelo; permanece como default até o próximo `gla X`.
- **Não tenta** rodar MLX e llama.cpp simultâneos. A combinação foi causa de kernel panic em 24 GB unificada (Memory ID 0xff, `IOGPUMemory.cpp:550 underflow`); `gla` torna isso impossível por design.
- **Sem flag `--no-tui`** para "só subir backend". Para esse caso, os aliases `gla_lcpp_*` / `gla_mlx_*` continuam existindo no `.zshrc`. `gla` é o atalho integrado; aliases são as primitivas.

## Critérios de sucesso

1. `gla gemma4` em terminal limpo → opencode abre com Gemma 4 MLX selecionado, em ≤ 30s.
2. `gla qwen36-lcpp` após `gla gemma4` → mata MLX, sobe llama.cpp Qwen36, opencode reabre com modelo correto.
3. `gla off` em qualquer estado → ambas portas livres, GPU liberada, opencode não é aberto.
4. Após `gla X`, abrir `opencode` direto (sem wrapper) usa o último modelo escolhido.
5. Reboot não deixa servidor zumbi — `gla` em sistema novo funciona.

## Referências cruzadas

- `clients/glaurung-llm/TUNING.md` — bench que justifica MLX como default
- `bin/lmswitch` (Ancalagon) — padrão equivalente em systemd, fonte das ideias
- Conversa SpecStory `2026-05-01_13-16-17Z-quero-configurar-o-qwen3.md` — origem da config
- Panic report `/Library/Logs/DiagnosticReports/panic-full-2026-05-01-151153.0002.panic` — incidente que motivou o mutex explícito
