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

Nesta etapa o service usava `ncmoe=12`, mirando o headroom maior (pico do bench).

**Em produção com 64K ctx** (desde que Claude Code system prompt + tools consome ~32K e 32K não dava margem pro user content): testado `ncmoe=12 + ctx=65536 + KV q4/q4` — cabe em **15.7 GiB / 175 MiB livres**, com 75.7 tok/s em prompt de 400 tokens (perda de ~5% vs 32K pelo KV cache maior). Config do `llama-coder.service` nesta etapa, superada depois pela subida para 96K.

**Config atual em produção (96K ctx):** `-c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 16`. Subir de 64K para 96K aumenta o KV cache, o que exigiu mover mais experts para a CPU (`ncmoe` 12 → 16) para caber nos 16 GiB — trocou-se ~2% de tok/s por +50% de contexto, justificado pelo system prompt do Claude Code consumir ~32K sozinho. **Fonte de verdade é o `ExecStart=` de [`systemd/llama-coder.service`](../systemd/llama-coder.service)**, não este texto: as linhas acima registram o histórico do sweep, não o estado corrente.

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

## 10. Updates de SO + migração de kernel — Fase 3 (2026-06-08)

### Updates não-held aplicados (higiene, sem reboot)
`apparmor` + `libapparmor1` (→ 4.0.1...0ubuntu0.24.04.7), `cloud-init` (→ 26.1-0ubuntu1~24.04.1),
`firmware-sof-signed` (→ 2023.12.1-1ubuntu1.11), `telnet` + `inetutils-telnet` (→ 2.5-3ubuntu4.2).
Aplicados via `apt install --only-upgrade` (sem soltar holds).

### Migração de kernel `6.8.0-111` → `6.8.0-124`
Driver 610 inalterado → **kernel é a única variável**. Baseline = números da Fase 2 (kernel 111).

| Modelo | k111 tok/s | k124 tok/s (melhor) | Δ |
|---|---|---|---|
| coder | 83.2 | 84.9 | +2% |
| gemma4 | 86.8 | 88.1 | +1.5% |
| qwen36 TQ3 | 39.3 | 39.25 | ~0% |

**Kernel não afeta a perf** (esperado) — números acompanham o 610. Variância nos MoE.

**DKMS:** autoinstall do `nvidia/610.43.02` para 6.8.0-124 (build + assinatura MOK)
disparado no `apt install` do kernel. `dkms status` lista 110/111/124.

**Suspend/resume S3 no kernel 124:** `make sleep`/`make wake` (WoL) — resume em ~12s,
`uptime -s` idêntico (S3 real), `nvidia-smi` limpo em 610. **OK no kernel novo.**

**Fallback:** kernel 6.8.0-111 mantido instalado (entrada no GRUB) com módulo nvidia 610
já buildado — boot de recuperação se o 124 falhar. Kernel stack re-held no 124.

### Pendências remanescentes (held por decisão)
- `cuda-toolkit` 13.2 → **13.3** (+2 config): só vale acoplado a rebuild do llama.cpp; isolado não muda nada.
- `dkms` → 3.4.1: framework de build; sem motivo para soltar.

Nenhuma outra pendência — stack nvidia uniforme em 610, kernel em 124, demais updates de SO aplicados.

## 11. Sanitização final — cuda-toolkit + dkms (2026-06-08)

Zeradas as últimas pendências de apt (sistema sem nada upgradável).

- **`dkms`** → 3.4.1. Módulos `nvidia/610.43.02` (110/111/124) **intactos** — upgrade do
  framework não rebuilda nem remove módulos já instalados.
- **`cuda-toolkit`** 13.2 → **13.3** (+2 config). Modelo side-by-side do CUDA: instala a
  árvore `/usr/local/cuda-13.3` **ao lado** da 13.2 (não remove), repointa o alternative
  `/usr/local/cuda` → 13.3. ~10 GB de disco (sobram ~40 GB).

**Smoke test pós-toolkit:** os binários do llama.cpp (compilados contra 13.2) sobem e
servem normalmente com o toolkit em 13.3 — coder a **84.2 tok/s**, geração coerente. Como
previsto: nada removido + sonames `.so.13` compatíveis. **Sem reboot.**

**Efeito colateral útil:** como `/usr/local/cuda` → 13.3, um futuro rebuild do llama.cpp
(via `scripts/build-llama.sh`) usará o 13.3. O 13.2 fica para os binários atuais.

### Estado do Ancalagon em 2026-06-08 (pós Fases 1-4)
Snapshot daquela data — **superado**; o estado corrente está em § 13.

- llama.cpp upstream `8f83d6c` (v668), fork TQ3 `8ad7180` (v9674)
- Driver NVIDIA **610.43.02**, kernel **6.8.0-124**, CUDA default **13.3** (13.2 retido)
- `apt list --upgradable` = **0**. 27 pacotes held (nvidia/kernel/cuda/dkms pinados).
- Kernel 6.8.0-111 retido no GRUB como fallback.

## 12. Calibração térmica do `gpu-guard` (2026-06-12)

Medição para calibrar os limites do watchdog `gpu-guard` (`bin/gpu-guard`).
Carga: qwen36 (TQ3) sob inferência contínua (~2 min, loop de geração), o pior
caso térmico dos três services (maior util + power).

| Métrica | Idle | Carga sustentada |
|---|---|---|
| Temp do die | 44-46°C | **75-77°C (pico 77)** |
| Power | ~38W | **318-320W (pico 320)** |
| GPU util | 0% | 99% |
| Throttle reason | `0x0` | `0x4` (SW Power Cap) |

**Observações:**
- Power real medido = **320W**, acima dos 292W registrados na §6. A placa bate o
  power cap (`throttle 0x4`) sob carga plena — `0x4` é SW Power Cap, comportamento
  **normal**, não sinal térmico. Não confundir com `0x20`/`0x40` (thermal slowdown).
- Pico do die = **77°C** — saudável (AD103 tolera ~88°C; Tjmax ~90°C).

**Limites adotados no `gpu-guard`** (proxy temp+throttle — `nvidia-smi`/NVML não
expõem temperatura do conector 12VHPWR; ver design da skill delegando-ancalagon):
- `WARN_TEMP=82°C` — +5°C sobre o pico normal (77); sinaliza cooling degradado.
- `CRIT_TEMP=86°C` sustentado por `HOLD=30s` → corta o `llama-*.service` ativo.
  Fica antes do HW thermal slowdown (~87-88°C), com margem para o corte agir.
- O default antigo (WARN 78) era próximo demais do pico normal — falsos positivos.

## 13. Janela completa de atualização — SO + kernel + driver + llama.cpp (2026-08-12)

Uma única janela cobrindo tudo que estava pendente: faixa segura de pacotes, kernel,
driver NVIDIA e os dois binários do `llama.cpp`. Baseline de referência = janela de
2026-07-20 (kernel `6.8.0-136`, `libcublas-13-3` → 13.6.0.2; registrada só em memória,
não neste arquivo): coder ~80-87 tok/s, prefill do coder 1835 tok/s.

### O que foi aplicado

| Faixa | De | Para |
|---|---|---|
| Faixa segura `/noble` (17 pkgs) | — | `apport`/`python3-apport` 2.28.3, `libgit2-1.7` 1.7.2...3.1, stack `systemd` **255.4-1ubuntu8.16 → .17** (security), `linux-firmware` ...2.29 |
| Kernel | `6.8.0-136` | **`6.8.0-137`** |
| Driver `nvidia-open` | `610.43.02` | **`610.57.04`** |
| llama.cpp upstream | `8f83d6c` (v668) | **`84e908c6`** (build 1503) — 835 commits |
| Fork TQ3 | `8ad718007` (v9674) | **`58ad80ffb`** (v10369) — 823 commits |
| CUDA | 13.3 | **intocado** (held; 0 upgradable) |

**DKMS/Secure Boot:** `nvidia/610.57.04` construído para os 4 kernels presentes
(110/124/136/**137**) e **autoassinado** pela `ancalagon Secure Boot Module Signature key`
(sha512) — sem reassinatura manual, como na janela de julho. Pós-reboot: Secure Boot
enabled, 4 módulos nvidia carregados. Kernel `6.8.0-136` retido no GRUB como fallback.

### A/B do fork TQ3 (`perf/tq3-4s-decode-round2`)

Única variável = versão do binário: os dois lados rodados **após** o reboot (mesmo kernel
-137, mesmo driver 610.57.04), máquina em `load average 0.00`, flags idênticas ao
`ExecStart` de `llama-qwen36.service`, cold-start descartado, 3 runs cada.

| qwen36 TQ3 | v9674 (08/jun) | v10369 (12/ago) | Δ |
|---|---|---|---|
| decode | 38.50 tok/s (38.49-38.51) | **39.74 tok/s** (39.74-39.74) | **+3.2%** |
| VRAM | 15424 MiB | 15038 MiB | **−386 MiB** |
| Power | 317 W | 264 W | **−53 W** |
| GPU util | 87% | 99% | +12 p.p. |

Ganho pequeno mas **real** — ranges disjuntos e variância intra-lado praticamente nula.
Chama atenção mais o perfil energético: +3% de throughput consumindo **53 W a menos**.

### Benchmark final dos 3 presets (via systemd, config real do repo)

| Preset | decode tok/s | range | threshold | prefill (prompt 1.5K) |
|---|---|---|---|---|
| coder | **84.57** | 82.35-85.72 | <55 | 2283 tok/s |
| qwen36 TQ3 | **39.73** | 39.72-39.73 | <25 | 1316 tok/s |
| gemma4 | **85.83** | 85.22-87.02 | <40 | 2410 tok/s |

Nenhuma regressão: coder estável vs 20/jul (80-87), qwen36 +1% vs § 9/§ 10 (39.3),
gemma4 −2.6% vs o pico de § 10 (88.1) mas dentro da faixa histórica (84.4-88.1).

### Armadilhas encontradas (valem para a próxima janela)

- **Prompt cache reuse invalida a medição de prefill.** O `prompt_per_second` do prompt
  canônico despencou de 252 → 39.6 tok/s no build novo, o que parece regressão de 84%.
  Não é: o `prompt_n` caiu de **21 → 4 tokens** — o build novo reaproveita o KV cache das
  requisições anteriores e só reprocessa o sufixo. Com 4 tokens o número é overhead fixo,
  não throughput. Medir prefill **exige prefixo único por rodada** (nonce no início do
  prompt) e prompt longo; foi assim que saíram os 1316-2410 tok/s da tabela acima.
- **Backup do `llama-server` sozinho não serve para rollback.** Desde a reestruturação em
  shared libs (§ 8), o executável tem ~18 KB e resolve `libggml-cuda.so` & cia. por rpath.
  O backup precisa ser do `build/bin` inteiro (~184 MB por repo) — guardado **fora** de
  `build/`, que o rebuild limpo apaga. Aqui: `build-bin-bak-20260812/` nos dois repos.
- **`scripts/build-llama.sh` falhava quando invocado por SSH** — `/usr/local/cuda/bin` não
  entra no `$PATH` de sessão não-interativa e o cmake aborta com
  `No CMAKE_CUDA_COMPILER could be found`. Corrigido no mesmo commit com
  `-DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc` explícito (+ `rm -rf build`: o cache do
  cmake envelhece mal ao pular 800+ commits). Mesmo padrão do gotcha de caminho absoluto
  do `CLAUDE.md`.
- **`-fa` mudou de assinatura no upstream** — agora é `[on|off|auto]` e o log não imprime
  mais a linha de flash attention, então não dá para confirmar pelo journal. O `-fa 1` dos
  três services **segue correto**: `common_arg_utils::is_truthy()` (`common/arg.cpp:1274`)
  aceita `"1"` junto com `on`/`enabled`/`true` e mapeia para `LLAMA_FLASH_ATTN_TYPE_ENABLED`.
  Não cai em `auto`. Verificar isso na fonte a cada sweep grande de upstream.

### Suspend/resume S3 com o driver 610.57.04

O caminho historicamente frágil do `nvidia-open` (§ 9), testado com o alvo padrão do
Makefile: `make sleep` → `make wake`.

- **Resume em 12s**, `uptime -s` idêntico ao pré-suspend (**S3 real**, não reboot).
- `nvidia-smi` limpo em 610.57.04; **0 erros nvidia** no journal do boot.
- **Inferência real pós-resume** (o que `nvidia-smi` sozinho não prova): coder mediu
  **74.3 tok/s** logo após o resume e **79.3 tok/s** com o load assentando — a mesma
  assinatura de cold-start da § 8 (73.5 → 78-79), não regressão do S3. Bem acima do
  threshold de 55.
- **`make wake` validado como está** (broadcast `255.255.255.255`). No cold boot desta
  janela o host demorou ~2 min para responder e chegamos a repetir o pacote com
  broadcast dirigido — mas o teste S3 mostra que o alvo padrão funciona; a demora era
  tempo de boot, não pacote perdido. **Não mexer no Makefile.**

### Estado do Ancalagon em 2026-08-12 (corrente)
- llama.cpp upstream `84e908c6` (build 1503), fork TQ3 `58ad80ffb` (v10369)
- Driver NVIDIA **610.57.04**, kernel **6.8.0-137**, CUDA **13.3** (held)
- `apt list --upgradable` = **0**; kernel/nvidia re-held (23 pacotes) após o upgrade
- Kernel `6.8.0-136` retido no GRUB como fallback; `build-bin-bak-20260812/` para rollback
  dos binários
- **Não feito, por decisão:** `do-release-upgrade` 24.04 → 26.04 LTS (`Prompt=lts` já
  oferece) e qualquer CUDA > 13.3 — ambos exigem janela e A/B próprios.

## 14. Adição do preset Qwen3.8-27B (2026-08-16)

O Qwen3.8-27B saiu em 13-14/ago/2026 (Apache 2.0, 28B densos, 64 camadas, 262k de
contexto nativo, com vision encoder). Entrou como **quarto preset**, sem substituir o
`qwen36` — os dois convivem em disco (13 GiB cada).

### Não foi preciso recompilar o llama.cpp

Confirmado por três vias independentes antes de baixar qualquer coisa:

| Evidência | Resultado |
|---|---|
| `config.json` oficial do `Qwen/Qwen3.8-27B` | `model_type: "qwen3_5"` / `Qwen3_5ForConditionalGeneration` |
| `strings libllama.so` do fork TQ3 (`58ad80ffb`) | `qwen35` presente na lista de arquiteturas |
| GGUF do Qwen3.6 já em produção | `general.architecture = qwen35` |

Ou seja, o modelo novo **reusa a arquitetura Qwen3.5**, cuja code path já roda nesta
máquina desde abril. Rebuild descartado com evidência, não por suposição.

### Escolha do quant

Âncora: o TQ3_4S do `qwen36` ocupa **13 GiB** de pesos e cabe 100% na GPU com `-c 40960`
e KV `q8_0`. Alvo, portanto, ~13 GiB. Escolhido **IQ3_M** (13,90 GB decimais = **12,94
GiB**), de `bartowski/Qwen3.8-27B-GGUF`. Fallback IQ3_XS (12,41 GiB) não foi necessário.

> **Atenção às unidades:** o HuggingFace reporta GB decimais e o `ls -lh` mostra GiB —
> "13G" no `ls` ≈ 13,96 GB no HF. Confundir os dois faz um quant parecer caber quando não cabe.
> `Q3_K_M` (13,61 GiB) e acima provavelmente estouram.

### Medições (flags idênticas ao `qwen36`, load average 0.13 = sem contenção)

| Métrica | Qwen3.8-27B IQ3_M | Qwen3.6-27B TQ3_4S |
|---|---|---|
| Decode | **39,2 – 40,3 tok/s** | 39,73 tok/s |
| Prefill (`prompt_n=4634`) | **1650,6 tok/s** | — |
| VRAM | **14918 / 16376 MiB** (~1,4 GiB livres) | — |

Modelo mais novo, throughput equivalente, e ainda sobrou VRAM.

### Armadilhas registradas

- **Prefill com prompt curto mente.** Com `prompt_n=35` o mesmo servidor mediu 141 tok/s;
  com `prompt_n=4634`, 1650 tok/s. O setup domina prompts curtos — sempre medir prefill
  com prompt longo e `cache_prompt: false`.
- **`W model has unused tensor blk.64.nextn.*`** — é a cabeça de Multi-Token Prediction
  (MTP), que o llama.cpp ignora. Benigno: não afeta correção, só não há aceleração
  especulativa.
- **`W common_fit_params: failed to fit params to free device memory: n_gpu_layers
  already set by user to 99, abort`** — é **warning, não erro**. Só avisa que não vai
  auto-ajustar porque `-ngl` foi fixado. Fácil de confundir com falha ao varrer o log com
  `grep -i error`.
- **`mmproj` (vision) não baixado** — custa VRAM que não sobra e o preset serve o endpoint
  de código na `:1234`.
- Requantizar para TQ3_4S no fork é viável a partir do **Q8_0** (29 GB); o **bf16
  (54,66 GB) não cabe** nos 37 GB livres de disco.
