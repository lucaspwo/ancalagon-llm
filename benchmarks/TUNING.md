# Tuning benchmarks — dados empíricos

Hardware: Ryzen 5 7600X (6c/12t) + RTX 4070 Ti SUPER (16 GB VRAM), Ubuntu 24.04, CUDA 13.2.

Metodologia: prompt fixo ("Explain quantum entanglement in 5 paragraphs", 400 max_tokens, T=0.2) para throughput real; `llama-bench` para varreduras de parâmetros.

## 1. KV cache quantization (LM Studio)

Armadilha crítica: o LM Studio esconde o toggle `checked` do KV quant em JSON. O formato minimalista é silenciosamente ignorado.

| Formato | Comportamento |
|---|---|
| `"value": "q4_0"` | Ignorado → KV fica f16 |
| `"value": {"checked": true, "value": "q4_0"}` | Aplica de verdade |

### Impacto quant (Qwen3-Coder 30B @ 32K ctx, offload 0.70)

| K/V | VRAM | tok/s |
|---|---|---|
| f16/f16 (baseline) | 14.86 GiB | 51.5 |
| q8_0/q8_0 | 13.83 GiB | 49.2 |
| q4_0/q4_0 | 13.30 GiB | 48.7 |
| **q8_0/q4_0 assimétrico** | 13.56 GiB | **3.16** |

**Nunca usar K e V com quants diferentes** — fallback CUDA catastrófico (provavelmente falta kernel flash-attn otimizado para esse par). Mesmo padrão observado no Qwen3.6 em 32K/0.80 q4/q4: cai a 1.22 tok/s.

### Ganho do q4 simétrico com offload maior

VRAM liberada permite subir offload:

| Ctx | Offload | K/V | VRAM | tok/s |
|---|---|---|---|---|
| 32K | 0.70 | q4_0/q4_0 | 13.3 GiB | 48.7 |
| **32K** | **0.80** | **q4_0/q4_0** | **15.2 GiB** | **61.8** |
| 64K | 0.70 | q4_0/q4_0 | 14.0 GiB | 48.6 |

## 2. `-n-cpu-moe` (llama.cpp nativo)

Flag não exposta no LM Studio. Em MoE, coloca **apenas experts** na CPU, mantendo attention/norm/shared 100% na GPU.

Qwen3-Coder 30B-A3B, `llama-bench` tg128 @ sem ctx loaded (VRAM só pesos):

| ncmoe | tok/s |
|---|---|
| 48 (todos experts CPU) | 42.9 |
| 40 | 49.7 |
| 32 | 58.1 |
| 24 | 69.5 |
| 20 | 77.6 |
| 18 | 82.6 |
| 16 | 86.8 |
| 14 | 86.2 |
| **12** | **96.5 (pico)** |
| 10 | 91.0 |
| 8 | 89.2 |
| 6 | 83.5 |
| 4 | OOM |

**Em produção com 32K ctx** (KV ocupa ~860 MiB extra): `ncmoe=10` é o pico seguro (81.5 tok/s, 15.5 GiB VRAM, 500 MiB folga). `ncmoe=8` OOM com 32K; só cabe com 16K.

O service usa `ncmoe=12` pensando em headroom maior (pico do bench).

**Em produção com 64K ctx** (desde que Claude Code system prompt + tools consome ~32K e 32K não dava margem pro user content): testado `ncmoe=12 + ctx=65536 + KV q4/q4` — cabe em **15.7 GiB / 175 MiB livres**, com 75.7 tok/s em prompt de 400 tokens (perda de ~5% vs 32K pelo KV cache maior). Esta é a config atual do `llama-coder.service`.

## 3. ubatch sweep

Testado com `ncmoe=12`, `pp4096+tg128`:

| ubatch | pp512 tok/s | tg128 tok/s | pp4096+tg128 tok/s |
|---|---|---|---|
| 256 | 1070 | 64.6 | 567 |
| **512 (default)** | **1827** | **82.2** | 778 |
| 1024 | 1848 | 85.2 | 1390 |
| 2048 | 1850 | 84.3 | 1587 |

Default 512 já satura prompt processing. ubatch 1024 dá ~2% em pp e, curiosamente, subiu tg em alguns runs (variance dentro do ±). Não vale mudar.

## 4. CPU thread pool

Ryzen 7600X 6c/12t. Default LM Studio = 9 (75% do SMT), usar 12 (SMT completo) → +5-8% em MoE.

Configurado via `llm.load.llama.cpuThreadPoolSize` no preset LM Studio e `-t 12` no llama.cpp.

## 5. Fork TQ3 vs upstream (Qwen3.6-27B)

TQ3_4S = 3-bit ternary quant, 4-slot packing. Fork `turbo-tan/llama.cpp-tq3` (upstream ainda não suporta).

Modelo: `YTan2000/Qwen3.6-27B-TQ3_4S` (13.0 GB vs 17.5 Q4_K_M).

| Backend | Modelo | VRAM | GPU util | Power | tok/s gen | pp tok/s |
|---|---|---|---|---|---|---|
| LM Studio | Q4_K_M 32K/0.85 q4/q4 | 15.8 | 34.3% | 94W | 13.7 | ? |
| llama-server upstream | Q4_K_M -ngl 50 | 13.5 | 25.8% | 77W | 11.2 | ? |
| **TQ3 fork** | **TQ3_4S** | 14.8 | **96.5%** | **292W** | **36.8** | **1266** |

Breakdown VRAM do TQ3 (do log do servidor):
```
CUDA0 15911 MiB total = 12615 (model) + 1686 (context) + 495 (compute) + 343 unaccounted
Free: 770 MiB
```

Folga apertada mas estável em operação contínua.

### Qualidade percebida (caso ratelimiter)

Teste: código Python com bug de concorrência + bug de wall clock. TQ3_4S identifica:
1. TOCTOU / lock granularity (race condition fora do lock)
2. `time.time()` não-monotônico causando rejection storm em NTP jump
3. `remaining()` sem sync + cleanup

Output idêntico em qualidade ao Q4_K_M do mesmo modelo. Ternary quant não degrada o raciocínio nesse tipo de tarefa.

## 6. Baseline de "GPU saturada"

Para calibrar o que é "GPU trabalhando de verdade", rodei Qwen3.5-9B Q4_K_M (7.2 GB, 100% GPU):

- GPU util: 91.7%
- Power: 217W
- tok/s: 90.5

Os modelos grandes em offload parcial do LM Studio ficavam em 30-34% util / 70-95W — confirmação objetiva de que CPU era gargalo. TQ3_4S 100% GPU hoje: 96.5% util / 292W, ainda melhor que o 9B (que é pequeno demais pra saturar compute).

## 7. Gemma 4 26B-A4B-it Q4_K_M — primeiro benchmark (2026-04-24)

Modelo novo adicionado como terceiro preset (`llama-gemma4.service`, alternativa ao coder). llama.cpp upstream, config **idêntica à do `llama-coder`** como ponto de partida:

```
-c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 16 --jinja
```

### Medições

Prompt curto ("Explain quantum entanglement in exactly 5 paragraphs", 400 out):

| Métrica | Valor |
|---|---|
| Gen tok/s | **57.2** |
| Prefill tok/s (24-tok prompt) | 126 |
| GPU util pico | 41% |
| VRAM usada | 10.0 GiB (10016 MiB) |
| VRAM livre | 5.9 GiB (5905 MiB) |
| Power pico | 83 W |

Prefill longo (12.015 tokens, prompt repetitivo):

| Métrica | Valor |
|---|---|
| Gen tok/s (após prefill) | 49.2 |
| Prefill tok/s | **1939.7** |
| VRAM usada | 10.1 GiB (10064 MiB) |
| VRAM livre | 5.8 GiB (5849 MiB) |

### Comparação com `llama-coder` no mesmo config

| | gen tok/s (curto) | VRAM usada | VRAM livre |
|---|---|---|---|
| llama-coder (Qwen3-Coder-30B-A3B) | 78 | 15.4 GiB | 559 MiB |
| **llama-gemma4 (Gemma 4 26B-A4B)** | **57** | **10.0 GiB** | **5905 MiB** |

Gemma 4 é ~27% mais lento em geração (consistente com 4B active vs 3B active — mais compute por token) mas usa **5.4 GiB a MENOS** de VRAM no mesmo config.

### Oportunidade de tuning (não aplicada neste commit)

Com 5.9 GiB livres, `ncmoe=16` está folgado demais para esse modelo — muitos experts na CPU sem necessidade. Baixar ncmoe para algo como **8 ou 4** deveria mover experts de volta pra GPU e ganhar tok/s (a regra "cada bump de ctx exige bump proporcional de ncmoe" vale invertida: com ctx já cabendo, menos ncmoe = mais GPU = mais tok/s, até onde VRAM aguentar).

Teste empírico pendente. Regra do repo: ship com config funcional, otimizar em PR separado após medir.

### Threshold de regressão

Piso sugerido: **40 tok/s gen** no prompt curto (57 × 0.7). Abaixo disso, investigar: `nvidia-smi` (VRAM ocupada por outro processo?), versão do llama.cpp upstream, consistência do modelo GGUF.
