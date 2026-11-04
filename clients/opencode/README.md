# opencode + LLM local

Cliente recomendado para consumir tanto os services do **Ancalagon** (via Tailscale, GPU NVIDIA) quanto o `llama-server` local do **Glaurung** (M4 Pro, Metal). Dois providers no mesmo `opencode.json`.

## Instalação (Glaurung)

```bash
brew install sst/tap/opencode
# ou: npm i -g opencode-ai
```

## Caminho vigente: `llm-gateway` (Scatha)

Desde 2026-07-07 o `~/.config/opencode/opencode.json` real do Mac **não** aponta
direto para o Ancalagon — aponta para `http://llm.home.lab/v1` (`provider.ancalagon.options.baseURL`),
um gateway OpenAI-compatible (`homelab/compose/llm-gateway/`) rodando no Scatha (LXC 110) que:

- Acorda o Ancalagon sob demanda (SSH + WoL + `lmswitch`), sem precisar do `anc_lin_*` manual antes.
- Faz **hot-swap** de preset por-request: pedir `qwen38` com o `coder` carregado troca sozinho.
- Anuncia sempre os 4 aliases em `/v1/models`, acordado ou dormindo.

Não é preciso rodar `anc_lin_*` nem editar `opencode.json` para o dia a dia — é só usar
`/model ancalagon/<preset>` no `opencode` e o gateway resolve o resto (~20-70s no cold
start/troca, com heartbeat SSE cobrindo o timeout do cliente).

⚠️ **`ANC_MODELS` no `.env` do gateway precisa espelhar os presets do `lmswitch` deste
repo** — é a lista que ele anuncia, o allowlist do `/v1/chat/completions` **e** a lista
que detecta o preset ativo. Um preset novo aqui (`systemd/llama-*.service` + `bin/lmswitch`)
que não entrar em `ANC_MODELS` fica invisível ao gateway: ele passa a servir o modelo
carregado sob **qualquer** alias pedido, sem erro. Ver `homelab/compose/llm-gateway/README.md`.

## Scatha fora do ar: o mesmo gateway rodando no Mac

O `llm-gateway` é Python puro (`aiohttp`) e só precisa de SSH e HTTP até o Ancalagon, então roda no
próprio Mac via Tailscale. O comportamento continua o mesmo: escolher `/model ancalagon/<preset>` sobe
ou troca o preset sozinho.

```bash
make install-gateway-local    # LaunchAgent: 127.0.0.1:8090, sobe no login, KeepAlive
# no ~/.config/opencode/opencode.json: provider.ancalagon.options.baseURL = http://127.0.0.1:8090/v1
make uninstall-gateway-local  # ao voltar para o gateway do Scatha (e restaurar http://llm.home.lab/v1)
```

Wrapper: [`llm-gateway-local.sh`](llm-gateway-local.sh), que usa a `.venv` e o código de
`~/git/homelab/compose/llm-gateway` (`LLM_GATEWAY_DIR` sobrescreve). Log em
`~/Library/Logs/llm-gateway-local.log`. Validado em 2026-11-02: com nenhum preset ativo, o `coder` subiu
sozinho e o opencode corrigiu e rodou um script; a troca para `gemma4` funcionou a quente.

Limitações: o WoL é broadcast na LAN, então só acorda o Ancalagon suspenso se o Mac estiver na mesma
rede (via Tailscale ele precisa estar acordado). E não deixe os dois gateways em uso ao mesmo tempo:
cada um serializa as próprias trocas, mas não as do outro, então dois clientes pedindo modelos
diferentes ficam trocando de preset entre si.

## `opencode.json` deste diretório — fallback direto ao Ancalagon

Uso quando o Scatha/gateway estiver fora do ar, ou para bypassar o gateway de propósito.

> **Nota sobre o IP:** o `baseURL` do arquivo versionado usa `100.64.0.10` como placeholder (convenção do repo para artefatos públicos). O IP real do Ancalagon-Ubuntu na Tailscale é diferente — substitua ao instalar.
>
> **Não use symlink direto** — o placeholder iria junto. Copie e edite.

**A) Global** (afeta qualquer pasta no Mac):
```bash
mkdir -p ~/.config/opencode
cp opencode.json ~/.config/opencode/opencode.json
sed -i '' 's|100\.64\.0\.10|<IP_REAL>|' ~/.config/opencode/opencode.json
```

**B) Por-projeto** (apenas dentro do diretório alvo):
```bash
cp opencode.json ~/git/<projeto>/opencode.json
sed -i '' 's|100\.64\.0\.10|<IP_REAL>|' ~/git/<projeto>/opencode.json
```

Confirmar IP real com `tailscale status | grep ancalagon-ubuntu`.

### Pré-condição: subir o modelo manualmente

Só se aplica a este fallback — o `llm-gateway` faz isso sozinho. `opencode` é cliente
puro; o provider direto só responde se algum service estiver ativo.

```bash
# do Mac, via SSH (alias do .zshrc)
anc_lin_coder    # ou anc_lin_qwen36 / anc_lin_qwen38 / anc_lin_gemma4 (flint: make flint)
anc_lin_status   # confirma :1234 respondendo
```

### Glaurung (local, M4 Pro)

Sob demanda — não há service systemd no macOS, sobe manualmente antes de abrir o `opencode`. Configs validadas empiricamente em [`clients/glaurung-llm/TUNING.md`](../glaurung-llm/TUNING.md). Só **um** modelo de cada vez (compartilham :1235).

**Gemma 4 26B-A4B-it (default — MoE, ~55 tok/s, ctx 80K):**

```bash
PIDS=$(lsof -tnP -iTCP:1235 -sTCP:LISTEN); [ -n "$PIDS" ] && kill $PIDS

nohup ~/git/llama.cpp/build/bin/llama-server \
  -m /Users/lucas/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf \
  --host 127.0.0.1 --port 1235 \
  -c 81920 -np 1 -ngl 99 -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --no-mmap --jinja --alias gemma4 \
  > /tmp/llama-server.log 2>&1 &

until curl -sf http://127.0.0.1:1235/v1/models > /dev/null; do sleep 1; done && echo ready
```

**Qwen3.6-27B (dense, raciocínio mais forte mas ~12 tok/s, ctx 48K):**

```bash
PIDS=$(lsof -tnP -iTCP:1235 -sTCP:LISTEN); [ -n "$PIDS" ] && kill $PIDS

nohup ~/git/llama.cpp/build/bin/llama-server \
  -m /Users/lucas/.lmstudio/models/lmstudio-community/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q4_K_M.gguf \
  --host 127.0.0.1 --port 1235 \
  -c 49152 -np 1 -ngl 99 -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --no-mmap --jinja --alias qwen3.6-27b \
  > /tmp/llama-server.log 2>&1 &

until curl -sf http://127.0.0.1:1235/v1/models > /dev/null; do sleep 1; done && echo ready
```

Para parar: `kill $(lsof -tnP -iTCP:1235 -sTCP:LISTEN)`.

### Glaurung MLX (porta 1236, troca dinâmica)

Provider alternativo `glaurung-mlx` usa `mlx_lm.server` da Apple. Comparado ao llama.cpp Metal: +14% no Gemma 4 e +37% no Qwen3.6 dense (números medidos em [TUNING.md § MLX](../glaurung-llm/TUNING.md#mlx--comparação-empírica)). Trade-off: keys mais longos no `/model` (repo HF completo, não alias curto), e qualidade levemente inferior em raciocínio matemático formal (K-quants do GGUF preserva precisão melhor em alguns casos).

**Suba sem `--model`** — um server serve os 2 modelos, troca on-the-fly conforme o `/model` no TUI:

```bash
PIDS=$(lsof -tnP -iTCP:1236 -sTCP:LISTEN); [ -n "$PIDS" ] && kill $PIDS

nohup ~/.venvs/mlx/bin/mlx_lm.server \
  --host 127.0.0.1 --port 1236 \
  --log-level INFO \
  > /tmp/mlx-server.log 2>&1 &

until curl -sf http://127.0.0.1:1236/v1/models > /dev/null; do sleep 1; done && echo ready
```

Pré-requisito: venv MLX em `~/.venvs/mlx/` (criar com `python3 -m venv ~/.venvs/mlx && ~/.venvs/mlx/bin/pip install mlx-lm`) e modelos baixados em `~/.cache/huggingface/hub/` (`hf download mlx-community/Qwen3.6-27B-4bit` etc).

A primeira request com cada modelo dispara o load (~6-7s); trocar com `/model` faz unload do anterior + load do novo (~7s extra; total ~14s por troca).

Para parar: `kill $(lsof -tnP -iTCP:1236 -sTCP:LISTEN)`.

### Wrapper formal

Wrapper formal (estilo `lmswitch` do Ancalagon) que orquestre os dois servidores (1235 + 1236) será adicionado depois — por enquanto é manual.

## Selecionando o modelo dentro do opencode

```bash
opencode
# dentro do TUI:
/model ancalagon/coder       # remoto, MoE 30B
/model ancalagon/qwen36      # remoto, dense 27B TQ3
/model ancalagon/gemma4      # remoto, MoE 26B
/model ancalagon/flint       # remoto, MoE 40B-A2.5B, ctx 128K — o melhor agente (TUNING.md §18)
/model glaurung/qwen36       # local llama.cpp, dense 27B Q4_K_M Metal (raciocínio, ~12 tok/s)
/model glaurung/gemma4       # local llama.cpp, MoE 26B-A4B Q4_K_M Metal (~55 tok/s, ctx 80K)
/model glaurung-mlx/mlx-community/Qwen3.6-27B-4bit                            # local MLX dense (~13.7 tok/s)
/model glaurung-mlx/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit            # local MLX MoE (~57 tok/s)
```

O `name` do model em `opencode.json` deve casar com o que está atualmente carregado. No Ancalagon, o `lmswitch` garante isso (services `Conflicts=`); no Glaurung, só rodar a inicialização de `glaurung/qwen36` acima carrega o modelo certo.

## Limites configurados

| Provider/model           | ctx     | output | Notas                                               |
|--------------------------|---------|--------|-----------------------------------------------------|
| ancalagon/coder          | 98 304  | 32 768 | Casamento com `-c 98304` do `llama-coder.service`   |
| ancalagon/qwen36         | 40 960  | 16 384 | Casamento com `-c 40960` do `llama-qwen36.service`  |
| ancalagon/gemma4         | 98 304  | 32 768 | Casamento com `-c 98304` do `llama-gemma4.service`  |
| ancalagon/flint          | 131 072 | 32 768 | Casamento com `-c 131072` do `llama-flint.service`  |
| **glaurung/qwen36**      | **49 152** | **16 384** | **llama.cpp Metal — M4 Pro 24 GB; teto antes de swap. Ver TUNING.md** |
| **glaurung/gemma4**      | **81 920** | **16 384** | **llama.cpp Metal — MoE 4B ativos, ctx maior viável. Ver TUNING.md** |
| **glaurung-mlx/mlx-community/Qwen3.6-27B-4bit** | 49 152 | 16 384 | MLX (Apple-native) — Qwen3.6 dense; +37% vs llama.cpp |
| **glaurung-mlx/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit** | 81 920 | 16 384 | MLX (Apple-native) — Gemma 4 MoE; +14% vs llama.cpp |

Se mexer em `-c` nos `.service` (Ancalagon) ou no comando manual (Glaurung), ajustar `limit.context` aqui.

## Pré-prompt de regras para os modelos locais: [`AGENTS.md`](AGENTS.md)

9 regras contra os erros que os modelos locais cometem como agente: mexer em teste para passar, mudar a saída
numa refatoração, reler o repo até estourar o contexto, usar `git stash`/`checkout` no repo do usuário. As
duas últimas foram observadas no benchmark de 2026-11-04 ([`benchmarks/TUNING.md` §20](../../benchmarks/TUNING.md)).
Ali a v1 não mudou o acerto (efeito teto), custou +28% a +82% de tempo e rendeu +60-75% de testes de
regressão. A v2, que é a deste arquivo, ainda não foi medida.

Para usar em toda sessão do opencode sem copiar o arquivo (testado: o opencode lê caminho absoluto e o
request mostra `Instructions from: …/clients/opencode/AGENTS.md`), no `~/.config/opencode/opencode.json`:

```json
"instructions": ["/Users/lucas/git/apps_mac/ancalagon-llm/clients/opencode/AGENTS.md"]
```

Isto **soma** com o `AGENTS.md` de cada projeto (não substitui). Para um projeto só, copie o arquivo para a
raiz dele. Remeça com `benchmarks/agentic/matrix.sh <preset> <tag>` ao mexer nas regras.

## Skills do Claude Code no opencode: `make sync-opencode-skills`

O opencode já lê sozinho `~/.claude/skills/` e `~/.agents/skills/` (as suas, as AWS e as da Anthropic). O
[`sync-claude-skills.sh`](sync-claude-skills.sh) cobre o resto com symlinks, sem editar o `opencode.json`:

- **skills dos plugins habilitados no Claude Code** (superpowers ×15, frontend-design), via
  `~/.config/opencode/claude-plugins/<plugin>`, que aponta para o caminho com versão do cache e é refeito a
  cada execução. **Rode de novo depois de atualizar plugins no Claude Code.**
- **`create-prd` e `generate-tasks`** (`disable-model-invocation: true`): viram commands
  (`~/.config/opencode/commands/`), para usar como `/create-prd` na TUI.
- **links quebrados** em `~/.claude/skills`: só reporta. Hoje são `delegando-intellibuild` e
  `registrando-demandas`, que apontam para o `intellissis-infra`, não clonado nesta máquina.

Depois de sincronizar: `opencode service stop` (o próximo `opencode` sobe o serviço de novo, já com a config
nova). Medido em 2026-11-04 capturando o request: **66 skills** (eram 50), e a lista
`<available_skills>` passou de ~35K para ~39K caracteres (~10K tokens por request, que pesam no `qwen38`
com 40K).

Ficam de fora:
- **o bootstrap do superpowers** (o `using-superpowers` injetado em toda sessão, como faz o hook do Claude
  Code). O plugin nativo dele para o opencode (`"plugins": [<dir local>]`) travou o `opencode run` no 2.2.5.
  Para religar o bootstrap sem o plugin, acrescente em `instructions`:
  `"/Users/lucas/.config/opencode/claude-plugins/superpowers/skills/using-superpowers/SKILL.md"` (+~3K
  caracteres; ele empurra "invoque skills antes de tudo", o que gasta contexto nos modelos locais).
- **as skills embutidas no binário do Claude Code** (`code-review`, `simplify`, `init`, `security-review`…), que não são arquivos.

Armadilhas do opencode 2.2.5 vistas aqui:
- **O `opencode run` usa um serviço em background** (`opencode serve --service`), que fica com a config de
  quando subiu. `opencode service restart` disparado de outro processo deixou o serviço travando todo
  `run`. Já `opencode service stop`, deixando o próximo comando subir o serviço, resolveu.
  `--standalone` contorna o serviço.
- **O `opencode run` não expande slash commands**: `"/create-prd x"` vai literal para o modelo. Os commands só
  funcionam na TUI. O carregamento deles na TUI **não foi conferido**.
- **Um diretório `.opencode/` no projeto travou o `run`** (com qualquer conteúdo). Prefira a config global.

## Quando usar cada provider

| Caso | Provider |
|---|---|
| Mac em casa, Ancalagon ligado | `ancalagon/*` (3× mais rápido que local, ctx maior) |
| Avião / sem rede / Tailscale fora | `glaurung-mlx/*` (default offline) |
| Privacidade total (nada sai do dispositivo) | `glaurung-mlx/*` ou `glaurung/*` |
| Velocidade local máxima | `glaurung-mlx/*` (MoE Gemma 57 tok/s, dense Qwen 13.7 tok/s) |
| Raciocínio formal / matemática crítica | `glaurung/qwen36` (llama.cpp Q4_K_M — K-quants preserva precisão melhor que MLX 4-bit uniforme) |
| Trocar entre Qwen e Gemma sem reiniciar server | `glaurung-mlx/*` (single server, dynamic load) |
| Métricas precisas (`timings.predicted_per_second`) | `glaurung/*` (llama.cpp expõe nativo; MLX só tem `usage`) |
| Tarefa pesada (refactor grande, ctx >50K, prompts longos) | `ancalagon/flint` (ctx 128K, tool calling nativo; 6/6 no benchmark agêntico de 2026-11-04, inclusive o refactor byte a byte — TUNING.md §20) — `coder`/`gemma4` como alternativa |
| Bugfix curto e localizado | `ancalagon/flint`; o `qwen38` também resolve, ~2× mais lento, mas **não aguenta sessão longa** (ctx 40K dividido entre 4 slots, TUNING.md §20) |

## Por que opencode e não pi.dev

- `pi.dev` exige escrever uma extensão TypeScript chamando `pi.registerProvider(...)` para qualquer endpoint custom — mais código, mais cerimônia.
- `opencode` aceita o endpoint OpenAI-compatible direto via `@ai-sdk/openai-compatible` no JSON.
- Para uso interativo casado com `lmswitch`, `opencode` é drop-in. `pi.dev` ganha se o objetivo for embutir o agente em scripts via RPC/SDK.
