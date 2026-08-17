# opencode + LLM local

Cliente recomendado para consumir tanto os services do **Ancalagon** (via Tailscale, GPU NVIDIA) quanto o `llama-server` local do **Glaurung** (M4 Pro, Metal). Dois providers no mesmo `opencode.json`.

## Instalação (Glaurung)

```bash
brew install sst/tap/opencode
# ou: npm i -g opencode-ai
```

## Uso do `opencode.json` deste diretório

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

## Pré-condição: subir o modelo

`opencode` é cliente puro — o provider só responde se algum service estiver ativo.

### Ancalagon (remoto via Tailscale)

```bash
# do Mac, via SSH (alias do .zshrc)
anc_lin_coder    # ou anc_lin_qwen36 / anc_lin_qwen38 / anc_lin_gemma4
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
| **glaurung/qwen36**      | **49 152** | **16 384** | **llama.cpp Metal — M4 Pro 24 GB; teto antes de swap. Ver TUNING.md** |
| **glaurung/gemma4**      | **81 920** | **16 384** | **llama.cpp Metal — MoE 4B ativos, ctx maior viável. Ver TUNING.md** |
| **glaurung-mlx/mlx-community/Qwen3.6-27B-4bit** | 49 152 | 16 384 | MLX (Apple-native) — Qwen3.6 dense; +37% vs llama.cpp |
| **glaurung-mlx/lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit** | 81 920 | 16 384 | MLX (Apple-native) — Gemma 4 MoE; +14% vs llama.cpp |

Se mexer em `-c` nos `.service` (Ancalagon) ou no comando manual (Glaurung), ajustar `limit.context` aqui.

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
| Tarefa pesada (refactor grande, ctx >50K, prompts longos) | `ancalagon/coder` ou `ancalagon/gemma4` (3× tok/s do Mac, ctx 96K) |

## Por que opencode e não pi.dev

- `pi.dev` exige escrever uma extensão TypeScript chamando `pi.registerProvider(...)` para qualquer endpoint custom — mais código, mais cerimônia.
- `opencode` aceita o endpoint OpenAI-compatible direto via `@ai-sdk/openai-compatible` no JSON.
- Para uso interativo casado com `lmswitch`, `opencode` é drop-in. `pi.dev` ganha se o objetivo for embutir o agente em scripts via RPC/SDK.
