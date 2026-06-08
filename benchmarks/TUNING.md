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

Modelo novo adicionado como terceiro preset (`llama-gemma4.service`, alternativa ao coder). llama.cpp upstream, config inicial **idêntica à do `llama-coder`** como ponto de partida (ajustada depois — ver sweep abaixo):

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

### Sweep de `--n-cpu-moe` (2026-04-24)

Após o primeiro boot confirmou-se que ncmoe=16 estava folgado demais (5.9 GiB livres ociosos). Sweep empírico completo mantendo ctx=98304 fixo:

| ncmoe | gen tok/s (curto) | gen tok/s (pós-prefill longo) | VRAM usada idle | VRAM livre idle | VRAM livre min sob carga | Status |
|---|---|---|---|---|---|---|
| 0 | — | — | — | — | — | ❌ OOM (tentava alocar 16 GB no modelo, só há 15.9 GiB VRAM total) |
| 4 | **101** | 64 (48K prefill) | 15.3 GiB | 271 MiB | **107 MiB** | ⚠️ Aguenta 48K mas folga apertada — risco real em 80-96K |
| **8** | **84** | **60** (60K prefill) | **13.5 GiB** | **2115 MiB** | **1877 MiB** | ✅ **Sweet spot — 3.4x mais folga que coder opera** |
| 12 | 63 | — | 11.6 GiB | 4051 MiB | — | Conservador, sem ganho sobre 16 proporcional à VRAM cedida |
| 16 | 57 | 49 (12K prefill) | 10.0 GiB | 5905 MiB | — | Config inicial, subutiliza GPU |

Tendência não-linear — 16→12 ganha 6 tok/s por 4 experts movidos pra GPU, 12→8 ganha 21 tok/s, 8→4 ganha 17 tok/s. Não é commutativa porque a computação MoE passa a saturar a GPU e o ganho marginal de mover mais experts diminui; o limite real é o **modelo completo cabendo em VRAM** (falha em ncmoe=0) mais margem para compute scratchpad e CUDA graphs.

### Config adotado

```
-c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 8 --jinja
```

**Ganhos vs config inicial (ncmoe=16):**
- +47% em geração curta (57 → 84 tok/s)
- +22% em geração após prefill longo (49 → 60 tok/s)
- +25% em prefill tok/s (1940 → 2420)
- Mais rápido que o coder em gen curto (84 vs 78) — Gemma 4 26B A4B é mais lento por token isolado (4B active vs 3B) mas o offload menos agressivo compensa

**Por que não ncmoe=4:** pp tok/s seria 3790 (2x!) e gen curto 101, mas no stress test com prefill de 48K sobraram apenas 107 MiB livres. Claude Code chegando em 80-90K provavelmente estoura compute buffer. Troca-se +20% de throughput por risco concreto de crash.

### Threshold de regressão

Piso sugerido: **60 tok/s gen** no prompt curto (84 × 0.7). Abaixo disso, investigar: `nvidia-smi` (VRAM ocupada por outro processo?), versão do llama.cpp upstream, consistência do modelo GGUF.

## 8. Atualização do llama.cpp — Fase 1 (2026-06-08)

Upstream `b76429a` (2026-04-22) → `8f83d6c` (2026-06-08, version 668), **667 commits**.
Fork TQ3 `794c5dc` (2026-04-21) → `8ad7180` (2026-06-08, version 9674), **841 commits**
(o fork rebaseou no upstream master de 2026-06-07).

Método: prompt canônico `"Explain quantum entanglement in exactly 5 paragraphs"`,
`n_predict=400`, `T=0.2`, melhor de 2 runs. Configs dos services intocadas (única
variável = versão do binário). Backups `.bak-<commit>` mantidos no Anca para rollback.

| Modelo | Baseline tok/s | Novo tok/s | Δ | Decisão |
|---|---|---|---|---|
| coder | 78.7 | 78.7¹ | ~0% | **mantido** |
| gemma4 | 86.7 | 84.4 | −2.6% | **mantido** |
| qwen36 TQ3 | 36.7 | 39.3 | **+7.0%** | **mantido** |

¹ A 1ª medição do coder logo após boot deu 73.5 (−6.7%), mas era **cold-start**:
remedição estável deu 78.0/78.7/79.9 (≈ baseline). Lição: descartar a 1ª medição
pós-boot do service.

Qualidade TQ3 (teste ratelimiter, 3 bugs críticos): **3/3 mantidos** — TOCTOU/lock
granularity, `remaining()` sem lock + lista stale, e `time.time()` não-monotônico
(o build novo sugeriu `time.monotonic()` explicitamente; o baseline desta run pegou
só 2/3, dentro da variância de reasoning a T=0.2). **Quant TQ3 não degradou.**

Nota operacional: o upstream recente reestruturou o `llama-server` em bibliotecas
compartilhadas (`libllama-server-impl.so`, `libllama-common.so`, `libmtmd.so`) — o
binário em `build/bin/llama-server` agora é fino (~18 KB) e resolve as `.so` irmãs via
rpath. Os `.bak` antigos (binários autossuficientes de ~9-13 MB) seguem válidos para
rollback. VRAM por modelo inalterada vs baseline.

**Decisão: ambos os binários mantidos** (upstream e fork decididos independentemente,
ambos ≥ 0.95× baseline; TQ3 ainda ganhou perf). Driver NVIDIA 595→610 fica para a Fase 2.

## 9. Atualização do driver NVIDIA — Fase 2 (2026-06-08)

Driver `nvidia-open` `595.71.05` → `610.43.02` (repo CUDA ubuntu2404). Kernel mantido
em `6.8.0-111` (holds do kernel preservados) e binários do llama.cpp inalterados
(os da Fase 1) — **driver é a única variável**. Baseline = números da Fase 1 (driver 595).

Método: mesmo prompt canônico, `n_predict=400`, `T=0.2`; descartado o cold-start
pós-boot, melhor de 3 runs estáveis.

| Modelo | Baseline 595 tok/s | 610 tok/s (melhor) | Δ | Decisão |
|---|---|---|---|---|
| coder | 78.7 | 83.2 | +5.7% | **mantido** |
| gemma4 | 84.4 | 86.8 | +2.8% | **mantido** |
| qwen36 TQ3 | 39.3 | 39.3 | ~0% | **mantido** |

Leitura: o model 100% GPU (qwen36, bandwidth-bound) ficou **flat**, como esperado —
banda de VRAM é hardware fixo. Os MoE-offload (coder/gemma4) mostraram leve ↑, no topo
da faixa de variância; não tratar como ganho garantido. **Confirma a premissa da spec:
ganho de perf do driver ≈ 0 neste hardware.** VRAM por modelo inalterada vs 595.

**Suspend/resume S3 (preocupação específica do nvidia-open):** testado `make sleep` →
`make wake` (WoL). Resume em ~12s, `uptime -s` idêntico (S3 real, não reboot), `nvidia-smi`
volta limpo em 610. **O caminho frágil histórico está saudável no 610.**

**DKMS:** módulos `nvidia/610.43.02` construídos para 6.8.0-110 e 6.8.0-111, assinados
com a MOK existente (Secure Boot OK). `nvidia-suspend/resume/hibernate` seguem enabled.

**Decisão: 610 mantido.** Sem regressão de perf, S3 funcional, DKMS+MOK ok. Stack nvidia
re-held (travada no 610). Rollback disponível: `.deb` do 595.71.05 em cache + repo serve 595.
Justificativa do update foi higiene + suporte a modelos novos (perf ~0, como previsto) —
não regrediu, então mantido.
