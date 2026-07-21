# Tuning — Glaurung (M4 Pro 24 GB)

Hardware: MacBook Pro M4 Pro (10P+4E, 14 cores), 24 GB unified memory, macOS 25.4 (Darwin), Metal 4.
Binário: `~/git/llama.cpp/build/bin/llama-server` HEAD `b8995-05e141a6b` (cmake `-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON`).

Metodologia: prompt fixo ("Explique entropia em mecânica estatística em 200 tokens", `max_tokens=250`, `T=0`), warmup + medido. Resultado em `tok/s` da chave `timings` da resposta OpenAI-compat.

Resumo executivo (top engine por modelo):

| Modelo | Engine recomendado | gen tok/s | ctx útil | Quando usar |
|---|---|---|---|---|
| Gemma 4 26B-A4B-it MoE | MLX 4-bit (ou llama.cpp Q4_K_M) | **57 / 50** | 80K (llama.cpp) | Default — rápido + ctx grande |
| Qwen3.6-27B dense | **MLX 4-bit** (llama.cpp 37% mais lento) | **13.7** | dinâmico | Raciocínio mais forte; só MLX dá throughput tolerável |

Detalhes em [§ MLX](#mlx--comparação-empírica). Comparação justa: mesmo prompt, mesmo `max_tokens=500`, wall-clock medido.

## Qwen3.6-27B (dense)

Modelo: `lmstudio-community/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q4_K_M.gguf` (15 GB).

### Configuração final

```
~/git/llama.cpp/build/bin/llama-server \
  -m /Users/lucas/.lmstudio/models/lmstudio-community/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q4_K_M.gguf \
  --host 127.0.0.1 --port 1235 \
  -c 49152 \
  -np 1 \
  -ngl 99 \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --no-mmap \
  --jinja \
  --alias qwen3.6-27b
```

**Performance medida:** prompt 47 tok/s | gen 11.6 tok/s.

Porta **1235** porque o LM Studio segura a 1234. Se for desativar o LM Studio depois, pode mover pra 1234 (alinha com convenção do Ancalagon).

## Decisões de design

### `--no-mmap` é obrigatório (não opcional)

Em unified memory, mmap atrapalha o Metal a contabilizar working set:

| mmap | gen tok/s | Δ |
|---|---|---|
| **off** (`--no-mmap`) | **11.1** | — |
| on (default) | 7.1 | **−36%** |

Hipótese: o Metal driver vê páginas como "potencialmente paginadas" e adiciona overhead de validação de residência por kernel dispatch. Com `--no-mmap`, o modelo é carregado num bloco anônimo e o Metal trata como working-set fixo.

### KV cache q8_0 simétrico

| K/V | gen tok/s | Memória relativa |
|---|---|---|
| f16/f16 | 10.7 | 1.0× (baseline) |
| **q8_0/q8_0** | **11.1** | 0.5× |
| q4_0/q4_0 | (não testado — risco de degradação como no Ancalagon) | 0.25× |

q8_0 é marginalmente mais rápido que f16 (provavelmente cabe melhor em cache L1/L2 da Apple GPU) e libera metade da memória do KV. Permite ctx 48K em 24 GB total.

**Nunca K≠V** — mesma regra aplica do Ancalagon (no Linux/CUDA confirmado catastrófico, no Metal não testado mas não há motivo pra arriscar).

### Flash attention `-fa on`: neutro

| `-fa` | gen tok/s | prompt tok/s |
|---|---|---|
| off | 11.1 | 46.6 |
| **on** | **11.1** | 43.2 |

Sem ganho de gen, prompt levemente pior dentro do ruído. Mantemos **on** porque o Metal kernel de FA reduz alocação de attention buffers (relevante quando ctx grande).

### `-np 1` (single slot)

Default `n_parallel=auto` resolve pra 4 slots, e cada slot reserva memória de attention buffers próprios. Em VRAM apertada do M4 Pro, isso causou **OOM no warmup** com ctx 8K (`recommendedMaxWorkingSetSize=19069 MB` é o teto Metal). Com `-np 1`, ctx 8K passa folgado e até 56K cabe.

Para uso single-user (Claude Code, opencode), 1 slot basta.

## Ctx vs estabilidade (empírico)

| ctx | gen tok/s | Estado |
|---|---|---|
| 4096 | 11.1 | OK |
| 6144 | 11.2 | OK |
| 8192 | 10.2 | OK |
| 12288 | 10.5 | OK |
| 16384 | 11.0 | OK |
| 24576 | 11.1 | OK |
| 32768 | 11.4 | OK |
| **49152** | **11.6** | **Sweet spot — folga confortável** |
| 57344 | 11.0 | No limite, sem folga pro sistema |
| 61440 | 4.4 | **Swap começando** — degradação severa |
| 65536 | 2.2 | Swap pesado, **flickering visível no terminal** |

**Regra prática:** ficar em **48K**. macOS precisa de ~5-6 GB livres para Spotlight/WindowServer/navegador/terminal sem stress; 56K rouba essa folga. 60K+ entra em swap, e como GPU compartilha unified memory, o compositor sofre — flickering = sinal claro de saturação.

## Por que não mais tok/s?

Generation é **bandwidth-bound** no M4 Pro:

- Bandwidth memória: ~273 GB/s
- Modelo Q4_K_M: ~16 GB ativos por token gerado
- Teto teórico: 273 ÷ 16 ≈ **17 tok/s**
- Atingido: 11.6 tok/s = **68% do teto**

Para chegar em 80-90% precisaria reduzir overhead Metal (improvável sem mudança upstream) ou usar quant menor (Q3_K_M libera bandwidth + working set, mas perde qualidade — não testado). Threads/batch só afetam prompt processing, que já está saturado em ~47 tok/s.

## Comparação com Ancalagon (referência cross-machine)

| Modelo | Ancalagon (4070 Ti SUPER) | Glaurung (M4 Pro) | Razão |
|---|---|---|---|
| Qwen3.6-27B dense | 36.8 tok/s gen, 100% GPU | 11.6 tok/s gen | ~3.2× pela bandwidth (672 vs 273 GB/s) |
| Ctx útil | 32K (TQ3_4S, 100% GPU) | 48K (Q4_K_M, KV q8_0) | Glaurung tem mais ctx absoluto, mas a ~⅓ da velocidade |

Glaurung **complementa** o Ancalagon: bom pra trabalhar offline (avião, sem rede) e pra prompts curtos onde 11 tok/s é tolerável. Não substitui.

## Threshold de regressão

Se `tok/s gen < 9` em prompt curto (~40 tokens entrada, 200 saída) com a config acima: regressão.

Checklist:
- `lsof -nP -iTCP:1235` — algum processo zombie segurando porta?
- `vm_stat | head -8` — `Pages free` < 200K (3.2 GB)? sistema sob pressão de memória
- `sysctl vm.swapusage` — swap em uso indica saturação
- Versão do llama.cpp (`llama-server --version` — comparar com `b8995-05e141a6b`)
- Outro processo grande ativo (Slack, Chrome com 50 abas, Xcode build...) — Activity Monitor

## Pendente (Qwen)

- Testar com modelo real grande de contexto (preencher 30K+ do ctx) — atualmente só validado com prompts curtos
- Comparar Q4_K_M vs Q4_K_S (talvez 1-2% mais rápido por arquivo menor)
- Avaliar `lmstudio-community` vs `unsloth` Q4_K_M (variantes de imatrix)
- Power draw / temperatura sustentada durante geração longa (M4 Pro thermal throttle?)

---

## Gemma 4 26B-A4B-it (MoE, 4B ativos)

Modelo: `lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf` (16 GB).

A arquitetura MoE muda completamente a economia. Por token, só ~4B parâmetros ativos são lidos (~2-3 GB efetivos no Q4_K_M), então o teto bandwidth-bound passa de ~17 tok/s (Qwen dense 16 GB) pra ~90-110 tok/s (Gemma 4 active ~3 GB). Atingimos 55 tok/s = ~55% do teto.

Adicional: Gemma usa **sliding window attention + global attention intercalado**. KV cache cresce muito mais lentamente que num dense, o que permite ctx 80K confortável (vs 48K do Qwen) com a mesma RAM.

### Configuração final

```
~/git/llama.cpp/build/bin/llama-server \
  -m /Users/lucas/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf \
  --host 127.0.0.1 --port 1235 \
  -c 81920 \
  -np 1 \
  -ngl 99 \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --no-mmap \
  --jinja \
  --alias gemma4
```

**Performance medida:** prompt 161 tok/s | gen 55.1 tok/s.

### Ctx vs estabilidade (empírico)

| ctx | gen tok/s | prompt tok/s | Estado |
|---|---|---|---|
| 8 192 | 54.1 | 194.1 | OK |
| 16 384 | 55.3 | 193.3 | OK |
| 32 768 | 55.0 | 193.9 | OK |
| 49 152 | 53.8 | 195.4 | OK |
| 65 536 | 55.0 | 196.0 | OK |
| **81 920** | **55.1** | **161.0** | **Sweet spot — folga confortável** |
| 90 112 | 51.0 | 183.3 | No limite, OK |
| 94 208 | 37.5 | 158.3 | **Swap parcial** — degradação |
| 98 304 | 13.3 | 115.7 | Swap pesado, evitar |

Throughput **plano até ~88K** — confirmação visual de que o KV cache não é o bottleneck (sliding window funciona). A queda em 92K+ é por working set Metal estourar com modelo + KV + compute buffers.

### Comparação Qwen vs Gemma no mesmo hardware

| Métrica | Qwen3.6-27B dense | Gemma 4 26B-A4B MoE | Razão |
|---|---|---|---|
| prompt tok/s | 47 | 161 | 3.4× |
| gen tok/s | 11.6 | 55.1 | **4.7×** |
| ctx útil | 48K | 80K | 1.7× |
| Modelo (GB Q4_K_M) | 15 | 16 | similar |

**Por que tão diferente?** No dense, cada token gerado lê o modelo todo (16 GB). No MoE com 4B ativos por token, só ~3 GB efetivos. Bandwidth do M4 Pro (273 GB/s) é dividida pela mesma carga, então throughput é proporcional ao trabalho real por token.

### Threshold de regressão (Gemma)

Se `tok/s gen < 45` em prompt curto com config 80K: regressão. Checklist é o mesmo do Qwen (vm_stat, swap, llama.cpp version, processos pesados).

### Comparação cross-machine (Gemma 4)

| | Glaurung (M4 Pro 24 GB) | Ancalagon (4070 Ti SUPER 16 GB) |
|---|---|---|
| gen tok/s (prompt curto) | 55 | 84 |
| ctx útil | 80K | 96K (com `--n-cpu-moe 8`) |
| Razão | 0.65× | 1.0× |

Glaurung está em 65% do Ancalagon — bem melhor que a razão de 0.32 que tínhamos no Qwen3.6 dense. Em modelos MoE, a desvantagem de bandwidth do Mac é parcialmente compensada por unified memory: experts inativos ficam na mesma memória dos ativos, sem overhead de transferência (no Ancalagon, `--n-cpu-moe` move pra RAM CPU e isso atravessa PCIe quando é roteado).

### Pendente (Gemma)

- Testar `--n-cpu-moe N` no Mac — em unified memory provavelmente é neutro (nada migra de fato), mas pode liberar working set Metal
- Speculative decoding com modelo draft pequeno
- Comparar com versão MLX 4-bit (ver seção MLX)

---

## MLX — comparação empírica

MLX é o framework próprio da Apple para Apple Silicon. Comparações diretas executadas no mesmo hardware, mesmo prompt ("Explique entropia em 200 tokens"), método wall-clock com `max_tokens=500` (TTFT diluído):

| Modelo | Engine | Quant | wall (500 tok) | overall tok/s | gen pure (timings) | Δ vs llama.cpp |
|---|---|---|---|---|---|---|
| Gemma 4 26B-A4B (MoE) | **MLX** | 4-bit | 8.76 / 8.91s | **56–57** | ~57 | **+14%** |
| Gemma 4 26B-A4B (MoE) | llama.cpp Metal | Q4_K_M | 10.02 / 10.37s | 48–50 | 50.7 | baseline |
| Qwen3.6-27B (dense) | **MLX** | 4-bit | 36.4 / 37.1s | **13.5–13.7** | ~13.7 | **+37%** |
| Qwen3.6-27B (dense) | llama.cpp Metal | Q4_K_M | 47.8 / 49.9s | 10.0–10.5 | 9.6 | baseline |

**Ganho MLX é muito maior em dense (+37%) do que em MoE (+14%).** Hipótese: MLX otimiza matmul puro com kernels Metal escritos especificamente para Apple Silicon; em MoE, o gargalo desloca pra routing/expert dispatch, onde a diferença entre engines praticamente some. Outra possível componente: GGUF Q4_K_M usa K-quants com super-blocks de quantização mista (Q5/Q6 em layers críticas), que adiciona overhead de descompressão no Metal — mais visível em dense onde o matmul domina o tempo.

### Setup MLX

```bash
# venv dedicado (Python 3.14 funciona)
python3 -m venv ~/.venvs/mlx
~/.venvs/mlx/bin/pip install mlx-lm

# baixar modelo (15 GB; vai pra ~/.cache/huggingface/hub/)
~/.venvs/mlx/bin/hf download lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit

# subir servidor OpenAI-compat (lazy load — primeira request carrega o modelo)
nohup ~/.venvs/mlx/bin/mlx_lm.server \
  --model lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit \
  --host 127.0.0.1 --port 1236 \
  > /tmp/mlx-server.log 2>&1 &

# para parar: kill $(lsof -tnP -iTCP:1236 -sTCP:LISTEN)
```

Uso pelo opencode: adicionar provider `glaurung-mlx` apontando pra `http://127.0.0.1:1236/v1` (modelo id é o repo HF completo: `lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit`).

### Versões MLX disponíveis no HF

| Modelo | Repositório | Quant | Tamanho |
|---|---|---|---|
| Gemma 4 26B-A4B | **`lmstudio-community/gemma-4-26B-A4B-it-MLX-4bit`** ✅ testado | 4-bit | 15 GB |
| Gemma 4 26B-A4B | `mlx-community/gemma-4-26b-a4b-it-4bit` | 4-bit | similar |
| Gemma 4 26B-A4B | `mlx-community/gemma-4-26b-a4b-it-nvfp4` | nvfp4 | menor |
| Qwen3.6-27B | `mlx-community/Qwen3.6-27B-4bit` | 4-bit | ~15 GB |
| Qwen3.6-27B | `unsloth/Qwen3.6-27B-UD-MLX-MXFP4` | MXFP4 | ~15 GB |
| Qwen3.6-27B | `unsloth/Qwen3.6-27B-MLX-8bit` | 8-bit | não cabe em 24 GB |

### Tradeoffs

| Aspecto | llama.cpp Metal | MLX |
|---|---|---|
| Performance Gemma MoE | 50 tok/s gen (medido) | **57 tok/s gen (medido, +14%)** |
| Maturidade do servidor | `llama-server` robusto, ctx configurável, flash attn, KV quant explícita | `mlx_lm.server` simples, ctx dinâmico, sem KV quant exposto |
| Quantizações | Q3/Q4/Q5/Q6/Q8/K-quants/imatrix | 4-bit, 8-bit, nvfp4, MXFP4 |
| Lazy load | Não (carrega no startup, ~5-10s) | Sim (primeiro request carrega ~6-7s) |
| Métricas | `timings` nativo (prompt/gen tok/s) | `usage` apenas, throughput via wall-clock |
| Ecossistema | Universal (Mac/Linux/Windows) | Apple Silicon only |
| Integração com este repo | Já alinhado (Ancalagon usa llama.cpp) | Bifurca o stack |
| Stack runtime | Binário C++ standalone | Python venv + dependências (~700 MB) |

### Recomendação atualizada (após bench Qwen)

**Decisão revisada por modelo:**

1. **Qwen3.6-27B dense → MLX vence claramente.** +37% é mudança de classe (10 → 13.7 tok/s). Para um modelo já no limite de tolerância de uso interativo, isso é a diferença entre desistir e usar. Vale subir `mlx_lm.server` quando usar Qwen.
2. **Gemma 4 26B-A4B MoE → llama.cpp continua viável.** +14% é nice-to-have mas não muda a experiência (50 → 57 tok/s — ambos rápidos). Se o stack único importar mais que os 14%, ficar no llama.cpp é defensável.
3. **Cross-machine consistency**: para o Ancalagon (CUDA Linux), llama.cpp segue mandatório — MLX é Apple-only. O setup pode ser híbrido: `ancalagon/*` via `llama.cpp` Tailscale, `glaurung-mlx/qwen36` via MLX local, `glaurung/gemma4` via llama.cpp local.
4. **Para automação/scripts**: llama.cpp — métricas nativas (`timings`), startup determinístico, sem lazy load.

### Ranking final no Glaurung (M4 Pro 24 GB)

| Posição | Modelo + engine | gen tok/s | Quando |
|---|---|---|---|
| 1 | **Gemma 4 + MLX** | ~57 | Default — rápido + boa qualidade Gemma |
| 2 | Gemma 4 + llama.cpp | ~50 | Se manter stack único |
| 3 | Qwen3.6 + MLX | ~13.7 | Quando precisar do raciocínio Qwen — única opção tolerável |
| 4 | Qwen3.6 + llama.cpp | ~10 | Evitar — MLX é 37% melhor |

### Tentativas que NÃO funcionaram (M4 Pro 24 GB)

#### MXFP4 (`unsloth/Qwen3.6-27B-UD-MLX-MXFP4`) — OOM

Quantização híbrida (MXFP4 nas MLPs + 8-bit nas self_attn) com tamanho final de **24 GB no disco** — excede o `recommendedMaxWorkingSetSize` do Metal (~19 GB) no M4 Pro de 24 GB. Servidor carrega o modelo, mas morre com `OutOfMemory` no primeiro decode:

```
libc++abi: terminating due to uncaught exception of type std::runtime_error:
  [METAL] Command buffer execution failed:
  Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)
```

MXFP4 viável apenas em Macs com 32 GB+ unified memory (M4 Pro 36 GB / M4 Max / M3 Ultra). Em hardware compatível, espera-se ganho menor que o salto MLX 4-bit já obtido — a maior parte do trabalho fica em MXFP4 (mesma footprint que 4-bit) mas com overhead de mistura de precisão.

#### Speculative decoding — sem draft viável

Tentado com Qwen3.6-27B + Qwen3-0.6B e Gemma 4 26B-A4B + Gemma 4 E2B. **Nenhum funciona:**

| Target | Draft | Falha |
|---|---|---|
| Qwen3.6-27B (vocab 248320) | Qwen3-0.6B (vocab 151936) | tokenizers incompatíveis — token IDs em espaços diferentes |
| Gemma 4 26B-A4B-it MoE | Gemma 4 E2B-it dense | **arquitetura incompatível** — `ValueError: Received 140 parameters not in model`. Target tem expert weights, draft tem self-attn padrão (k_norm/k_proj/v_proj). Mesmo tokenizer (vocab 262144) não basta. |

Speculative decoding precisa que **target e draft compartilhem arquitetura de attention** (mesmas projeções, mesmas dimensões de heads, mesmo padrão MoE/dense). Famílias Qwen3.6 e Gemma 4 não publicaram versões pequenas com arquitetura compatível ao membro grande:

| Família | Tamanhos disponíveis | Variação arquitetural |
|---|---|---|
| Qwen3.6 | 27B (dense), 35B-A3B (MoE) | sem variante <27B |
| Gemma 4 | E2B/E4B (dense), 26B-A4B (MoE), 31B (dense) | sem MoE pequeno na família |

Speculative só viável quando aparecer um Qwen3.6-mini-dense ou Gemma-4-A4B-mini com arquitetura idêntica ao 27B/26B respectivamente.

### Comparação de qualidade (Qwen3.6-27B, mesma pergunta T=0)

Pergunta usada: cálculo de AMAT em hierarquia de cache 3 níveis com hit rates absolutos + identificar incoerência + implementação Python. Respostas integrais salvas em `/tmp/quality-comparison/{llama-cpp-q4km,mlx-4bit}.md` durante o bench.

| Engine | AMAT calculado | Fórmula usada | Análise da incoerência |
|---|---|---|---|
| **llama.cpp Q4_K_M** | **17 ns** ✓ | `H_i · (T_1 + T_2 + ... + T_i)` — **cumula latências** corretamente (acertar Li exige passar por L1..L(i-1) primeiro) | Discute hit rates condicionais vs absolutos, identifica soma 0.97, conclui consistente |
| MLX 4-bit | 13 ns ✗ | `H_i · L_i` — **fórmula simplista**, ignora travessia | Análise circular: "não há incoerência... mas há..." sem conclusão clara |

**llama.cpp Q4_K_M deu resposta tecnicamente mais correta neste caso.** A interpretação cumulativa é o padrão em arquitetura de computadores (Hennessy & Patterson cap. 2). A fórmula MLX não está errada se assumirmos lookup paralelo, mas o enunciado descreve hierarquia tradicional sequencial.

**Por que diverge?** Quantizações diferentes:
- **GGUF Q4_K_M** (K-quants): super-blocks de 256 valores, mistura inteligente — algumas matrizes em Q5/Q6 onde precisão importa mais (attention output, layer norms críticas)
- **MLX 4-bit** (`group_size=64`, affine quantization simples): quantização uniforme, sem mistura

Para tarefas matemáticas/lógicas, K-quants pode preservar precisão melhor. Em chat/código geral, diferença raramente é perceptível.

### Recomendação sobre qualidade

| Caso de uso | Engine recomendado |
|---|---|
| Chat geral, brainstorm, escrita | MLX (velocidade vence; qualidade equivalente) |
| Código (gerar/revisar/refactor) | MLX (na maioria dos casos); voltar ao llama.cpp se notar regressão |
| **Matemática, raciocínio formal, prova** | **llama.cpp Q4_K_M** (precisão superior em casos sensíveis) |
| Validação de resposta crítica | Rodar nos dois engines e comparar — ou descer pro Ancalagon |

### Provider opencode

`glaurung-mlx` adicionado em `clients/opencode/opencode.json` apontando `127.0.0.1:1236`. Detalhe arquitetural relevante:

- `mlx_lm.server` **não faz aliasing** do campo `model` (diferente do llama.cpp com `--alias`). Cliente envia o **path real** (repo HF ou diretório local), o server tenta carregar.
- Logo, os keys no JSON são os **repo IDs completos** (`mlx-community/Qwen3.6-27B-4bit` etc), não nomes curtos.
- Vantagem: subir o servidor **sem `--model`** faz com que ele sirva qualquer MLX em `~/.cache/huggingface/hub/`. Trocar entre Qwen e Gemma é só `/model glaurung-mlx/<outro>` no TUI — descarrega o anterior, carrega o novo (~7s).
- `/v1/models` lista automaticamente os MLX baixados — opencode descobre os modelos disponíveis sem config extra.

### Pendente

- Avaliar perplexity quantitativamente em test set comum (nats/byte) — ranking de qualidade objetivo
- Testar variantes DWQ (`mlx-community/Qwen3.6-27B-4bit-DWQ`) — quant melhorado pela comunidade MLX
- Wrapper `glswitch` (estilo `lmswitch` do Ancalagon) para subir/parar os dois servers (1235 + 1236) e mostrar status
