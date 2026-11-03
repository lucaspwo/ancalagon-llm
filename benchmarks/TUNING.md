# Tuning benchmarks — dados empíricos

Hardware: Ryzen 5 7600X (6c/12t) + RTX 4070 Ti SUPER (16 GB VRAM), Ubuntu 24.04. CUDA/kernel/driver mudam a cada janela de manutenção — versões vigentes na seção mais recente (hoje §16: CUDA 13.4).

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

**Config em produção até 2026-11-02 (96K ctx):** `-c 98304 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 --n-cpu-moe 16` (desde então `-t 6 --n-cpu-moe 17 -ub 2048 -b 2048` — §19). Subir de 64K para 96K aumenta o KV cache, o que exigiu mover mais experts para a CPU (`ncmoe` 12 → 16) para caber nos 16 GiB — trocou-se ~2% de tok/s por +50% de contexto, justificado pelo system prompt do Claude Code consumir ~32K sozinho. **Fonte de verdade é o `ExecStart=` de [`systemd/llama-coder.service`](../systemd/llama-coder.service)**, não este texto: as linhas acima registram o histórico do sweep, não o estado corrente.

## 3. ubatch sweep

Testado com `ncmoe=12`, `pp4096+tg128`:

| ubatch | pp512 tok/s | tg128 tok/s | pp4096+tg128 tok/s |
|---|---|---|---|
| 256 | 1070 | 64.6 | 567 |
| **512 (default)** | **1827** | **82.2** | 778 |
| 1024 | 1848 | 85.2 | 1390 |
| 2048 | 1850 | 84.3 | 1587 |

Default 512 já satura prompt processing. ubatch 1024 dá ~2% em pp e, curiosamente, subiu tg em alguns runs (variance dentro do ±). Não vale mudar.

> **Revisto em 2026-11-02 (§18/§19):** a conclusão olhou só pp512. A coluna pp4096 já mostrava ~2× com ubatch 2048, e o opencode/Claude Code mandam turnos de 14-32K. Os três presets MoE passaram a `-ub 2048`.

## 4. CPU thread pool

Ryzen 7600X 6c/12t. Default LM Studio = 9 (75% do SMT), usar 12 (SMT completo) → +5-8% em MoE.

Configurado via `llm.load.llama.cpuThreadPoolSize` no preset LM Studio e `-t 12` no llama.cpp.

> **Revisto em 2026-11-02 (§19):** no llama.cpp atual (b12061) com experts na CPU, `-t 6` (núcleos físicos) dá +2-4% de decode sobre `-t 12` em flint, coder e gemma4; `-t 8` fica no meio. Os três passaram a `-t 6`.

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

## 15. Adição do preset Colibri — Qwen3.6-35B-A3B (2026-09-27)

Quinto preset, e o primeiro que **não é `llama.cpp`**: o engine [Colibrì](https://github.com/JustVugg/colibri)
(C puro, streaming de experts MoE via RAM/VRAM/disco). Modelo `Qwen3.6-35B-A3B` (MoE, 3B ativos,
arquitetura "Gated Attention + Gated DeltaNet" — **diferente** da do `Qwen3.6-27B-TQ3_4S` denso já em
produção; não é redundante). Container pré-convertido `Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64`
(int4-gs64, ~22 GB), baixado para `/mnt/black/colibri/qwen36_i4_gs64` (NVMe de jogos — o disco de
sistema tinha só 24 GB livres e o NV3 que sobrava morreu, ver memória `project-kingston-nv3-falha`).

### Descoberta: o tier CUDA não ativa por padrão

`coli serve` sozinho roda **100% CPU** (~0,6 tok/s) mesmo com o binário compilado `CUDA=1`. O log
denuncia: `[qtier] cap=8 != n_experts=256 -> tier disabled (needs full RAM residency)`. O tier CUDA
promove experts de RAM pra VRAM, mas só ativa quando `--cap` (slots de cache por camada) **igual**
a `n_experts` (256 aqui) — ou seja, com residência total em RAM primeiro. `--auto-tier --cap 256
--gpu 0` resolve; o log de sucesso mostra `[gpu] MoE experts -> CUDA VRAM tier`.

### Descoberta: bind em 0.0.0.0 exige opt-in explícito de segurança

`refusing to bind 0.0.0.0 beyond localhost without COLI_API_KEY set (set
COLI_ALLOW_INSECURE_BIND=1 to override)` — guard upstream do Colibrì, ausente no `llama-server`.
Decisão consciente (Lucas, 2026-09-27): `COLI_ALLOW_INSECURE_BIND=1`, mesma paridade de ameaça dos
`llama-*.service` (rede confiável = Tailscale/LAN, API sem autenticação nos cinco presets).

### Medição (prompt canônico, 3 runs, cold-start descartado)

| Run | tempo total | completion_tokens | tok/s |
|---|---|---|---|
| 1 (cold-start, descartado) | 15,30 s | 400 | — |
| 2 | 14,58 s | 400 | 27,43 |
| 3 | 14,51 s | 398 | 27,44 |

**Baseline: ~27,4 tok/s**, estável entre runs (Δ 0,01 pp). GPU sob carga: **36-39% util, 85-145 W,
50 °C**, ~14,15 GiB VRAM (7142 de 10240 experts residentes, mais o trunk — lm_head, projeções
DeltaNet — promovido pelo `--auto-tier`). Threshold de regressão adotado: **19 tok/s** (70% do
baseline, mesmo critério do `gemma4` em §7).

### Comparação com os presets llama.cpp existentes

| Preset | Modelo | tok/s | VRAM | Nota |
|---|---|---|---|---|
| qwen36 (TQ3) | Qwen3.6-27B denso | 39,7 | ~15,0 GiB | 100% residente, sem streaming |
| **colibri** | **Qwen3.6-35B-A3B MoE** | **27,4** | **~14,15 GiB** | **70% dos experts em VRAM, resto RAM** |

Mais lento que o `qwen36` (modelo maior, MoE com parte dos experts fora da VRAM), mas é um modelo e
uma técnica de inferência **diferentes** — não compete pelo mesmo caso de uso, é uma alternativa a
explorar (ver `docs/superpowers` se um plano formal for aberto depois).

### Config adotada

```
COLI_CUDA=1 COLI_GPUS=0 CUDA_EXPERT_GB=auto OMP_NUM_THREADS=6 OMP_WAIT_POLICY=PASSIVE
OMP_PROC_BIND=close COLI_ALLOW_INSECURE_BIND=1 COLI_ALLOWED_HOSTS=ancalagon-ubuntu,ancalagon.local
coli serve --model /mnt/black/colibri/qwen36_i4_gs64 --host 0.0.0.0 --port 1234 \
  --auto-tier --cap 256 --gpu 0
```

**Fonte de verdade é o `ExecStart=`/`Environment=` de [`systemd/colibri-qwen36.service`](../systemd/colibri-qwen36.service)**, não este texto.
`OMP_WAIT_POLICY` era `ACTIVE` até 2026-11-02 e virou `PASSIVE`; `COLI_ALLOWED_HOSTS` entrou na mesma
data (ver §17).

## 16. Janela de atualização — faixa segura + kernel 6.8.0-147 + CUDA 13.4.3 (2026-10-16)

**Estado de partida:** kernel `6.8.0-146`, driver `nvidia-open` **`615.71.09`**, CUDA **13.4**
(`/usr/local/cuda` → `cuda-13.4`). A migração 13.3 → 13.4 / `-137` → `-146` / `610.57.04` →
`615.71.09`, feita entre setembro e outubro de 2026, **não foi registrada aqui** — esta seção fixa o
estado a partir de agora. O `llama-server` linka `libcudart`/`libcublas`/`libcublasLt` de
`cuda-cudart-13-4`/`libcublas-13-4`. Os 88 holds (`*-13-4`, `nvidia-*`, metapacotes `linux-*`)
fazem um `apt-get upgrade` simples respeitar a política sozinho.

### O que mudou

| Faixa | Pacotes | Reboot |
|---|---|---|
| Segura (`apt-get upgrade`, holds intactos) | 41 — systemd 255.4-1ubuntu8.**18**, openssh 13.**20**, curl, sudo, libxml2, libx11, libpng, libarchive, apparmor, bind9, tzdata… (maioria `noble-security`) + **tailscale 1.102.5 → 1.104.1** | não |
| Kernel | `6.8.0-146` → **`6.8.0-147`** | sim |
| CUDA | `13.4.2` → **`13.4.3`**: metapacotes, nvcc (V13.4.92), nsight, `libcusolver` 12.3.5.3. **`libcublas`/`cudart` sem update** | — |

Nenhum pacote da faixa segura está na cadeia `ldd` do `llama-server` (libc6, libstdc++6, libgcc-s1,
libgomp1, cudart, cublas, libnvidia-compute). O DKMS construiu `nvidia/615.71.09` para o `-147` e
**autoassinou** com a `ancalagon Secure Boot Module Signature key` — o `sig_key` do módulo bateu com o
serial da MOK enrolled antes do reboot (checagem da memória `project_ancalagon_mok_apagada`). Os 17
pacotes atualizados foram re-held; snapd 2.77.1 ficou adiado por phasing.

### A/B

Script: [`scripts/bench-presets.py`](../scripts/bench-presets.py), rodado no próprio Ancalagon.
Decode = média de 3 runs após 1 descartado (prompt canônico, 400 tokens, **T=0**); prefill = prompt
de ~2.1K tokens com `cache_prompt:false` (`prompt_n` conferido ≈ 2.1K — evita a armadilha do §13).
Antes = `-146` com uptime ~15 min; depois = `-147` logo após o reboot, coder por último.

| Preset | decode `-146` | decode `-147` | Δ | prefill `-146` | prefill `-147` | VRAM |
|---|---|---|---|---|---|---|
| coder | 87.65 (87.16-88.01) | **88.79** (88.77-88.82) | +1.3% | 1771 | 1778 | 15174 MiB |
| qwen36 TQ3 | 39.75 (39.74-39.76) | **39.72** (39.72-39.72) | −0.1% | 1341 | 1340 | 15038 MiB |
| qwen38 | 40.09 (40.08-40.10) | **40.08** (40.06-40.09) | 0.0% | 1499 | 1497 | 14936 MiB |
| gemma4 | 84.60 (83.01-85.73) | **82.68** (80.85-83.71) | −2.3% | 2127 | 2151 | 13916 MiB |
| colibri | 36.02 (35.25-36.90) | **35.93** (34.73-36.92) | −0.2% | — | — | 14154 MiB |

**Sem regressão.** O −2.3% do gemma4 é ruído: os ranges se sobrepõem, o prefill subiu 1.1% e o run
de 80.85 caiu com load 4.9 minutos após o boot (mesmo efeito de contenção pós-boot do offload MoE já
visto no coder). **Confirmado:** re-run com a carga assentada (uptime 11 min, load 0.14) deu
gemma4 **84.70** (84.11-85.16), prefill 2108 — igual ao `-146`; colibri 36.27. VRAM idêntica nos
cinco presets.

### Armadilhas

- **Colibri exige `model` no payload.** Sem o campo, `/v1/chat/completions` devolve
  **404 `model_not_found`** (`The model None does not exist`) — o `llama-server` ignora o campo, então
  um bench escrito contra os `llama-*` quebra só no quinto preset. O script lê o id de `/v1/models`.
- **Colibri: 36 tok/s aqui vs 27.4 no §15.** O §15 media tempo de parede com outro payload; este
  script também usa tempo de parede, mas com T=0 e prompt via chat. O `/v1/chat/completions` do
  `coli serve` não devolveu `timings` nesta janela; o C do engine (`qwen36.c:651`) tem um bloco com
  formato **diferente** do llama (`tokens_per_sec`, não `predicted_per_second`) — o script só usa
  `timings` no formato llama e cai no tempo de parede no resto, para não misturar métodos em silêncio.
  **Compare o Colibri só contra números do mesmo script.** O threshold de 19 tok/s continua valendo.
- **Coder no primeiro run pós-boot oscila** (62 → 88 tok/s em runs consecutivos na tentativa
  descartada desta janela) — daí 4 runs com o 1º descartado, e o coder por último na ordem.

## 17. Janela de atualização — faixa segura + driver 615.71.10; Colibri sob opencode (2026-11-02)

**Estado de partida:** kernel `6.8.0-147`, driver `nvidia-open` `615.71.09`, CUDA 13.4.3, 88 holds.
Nenhum kernel nem pacote CUDA novo disponível.

### O que mudou

| Faixa | Pacotes | Reboot |
|---|---|---|
| Segura (`apt-get upgrade`, holds intactos) | 31 — `liblzma5`/`xz-utils`, `zlib1g`, `ca-certificates`, glib 2.80.0-6ubuntu3.**10**, ghostscript, git 2.43.0-1ubuntu7.**4**, libnss3, libprotobuf, python3-jwt, snapd 2.**77.1**, tmux, xserver-xorg-core, cloud-init, ubuntu-pro-client 38 + **tailscale 1.104.1 → 1.104.4** (maioria `noble-security`) | não |
| Driver (held → unhold → re-hold) | `nvidia-open` e companhia (19 pkgs) `615.71.09` → **`615.71.10`** + `dkms` 3.4.3 → 3.4.4 | sim |

O driver **está** na cadeia `ldd` do `llama-server` (`libcuda.so.1` vem de `libnvidia-compute`), daí o
A/B. O DKMS construiu `nvidia/615.71.10` para os 4 kernels e **autoassinou** pela MOK: o `sig_key` do
módulo do `-147` (`6A:55:41…`) bateu com o serial de `MOK.der` e a chave seguia enrolled, conferido
**antes** do reboot. Pós-reboot: Secure Boot enabled, 4 módulos `nvidia` carregados, `nvidia-smi` em
615.71.10. `.deb` de rollback do 615.71.09 (19 pacotes, 322 MB) em `~/nvidia-rollback/` no Anc, com a
lista em `~/nvidia-rollback/PKGS`. O re-hold voltou a 88 holds, com 0 pendências.

### A/B (`scripts/bench-presets.py`, mesmo método do §16)

Antes = 615.71.09, uptime ~3 min, load 0.65; depois = 615.71.10, uptime 3 min, load 0.08.

| Preset | decode antes | decode depois | Δ | prefill antes | prefill depois | VRAM |
|---|---|---|---|---|---|---|
| coder | 88.94 (88.81-89.00) | **89.14** (89.12-89.15) | +0.2% | 1785 | 1821 | 15174 MiB |
| qwen36 TQ3 | 39.73 (39.72-39.74) | **39.72** (39.72-39.72) | 0.0% | 1339 | 1337 | 15038 MiB |
| qwen38 | 40.09 (40.08-40.11) | **40.07** (40.06-40.09) | 0.0% | 1499 | 1497 | 14936 MiB |
| gemma4 | 82.98 (81.09-85.82) | **84.73** (83.54-86.36) | +2.1% | 2112 | 2108 | 13916 MiB |
| colibri | 36.03 (35.10-36.86) | **36.20** (35.61-36.89) | +0.5% | — | — | 14154 MiB |

**Sem regressão.** Ranges sobrepostos em todos os presets; VRAM idêntica.

### Opencode do Mac direto na `:1234` (sem o `llm-gateway`)

Tarefa: corrigir um `- 1` sobrando em `calc.py` e rodar `python3 calc.py` (exige tools read/edit/bash).
Config: provider `@ai-sdk/openai-compatible` com `baseURL` `http://ancalagon-ubuntu:1234/v1`, como
`opencode.json` de projeto no diretório de teste.

| Preset | Resultado | Tempo |
|---|---|---|
| coder | ✅ corrigiu e rodou (`4.0`) | 17 s |
| qwen36 | ✅ | 255 s (parte presa no cliente, ver armadilhas) |
| qwen38 | ✅ | 32 s |
| gemma4 | ✅ | 14 s |
| colibri | ❌ inviável para uso agêntico (abaixo) | — |

**Colibri não serve para o opencode**, por três motivos em cascata:

1. **403 para qualquer cliente remoto.** O `coli serve` tem um host guard anti-DNS-rebinding que só
   aceita `Host` = loopback/bind address. Até hoje o preset **só tinha sido usado via localhost** (os
   benchmarks rodam no Anc; o gateway não anuncia o colibri). Corrigido com
   `COLI_ALLOWED_HOSTS=ancalagon-ubuntu,192.168.1.8` (no mesmo dia trocado o `.8` por `ancalagon.local`:
   o IP do Anc na LAN é DHCP volátil — hoje `.19` — e o `.8` passou a ser o iPhone). É uma lista explícita, não `'*'`, para manter o
   guard contra uma página maliciosa no navegador do Mac. Quem usar outro nome/IP na URL precisa
   entrar na lista.
2. **Sem tool calling nativo:** `Tool use is not wired up for the qwen36 engine yet`.
   `COLI_TOOL_FALLBACK=1` (tools injetadas no prompt) passa desse erro, mas…
3. **…o contexto padrão é 8192** (o system prompt + tools do opencode dão ~13.7K tokens) e o
   **prefill é ~36 tok/s** (2010 tokens em 56 s, medido local). `--ctx 32768` cabe sem tirar experts da
   VRAM (7142 residentes nos dois casos), mas **subiu o swap de 1.7 para 5.2 GB** e derrubou o prefill
   para ~21 tok/s. Um turno de 14K tokens levaria de 6 a 11 min. Revertidos `--ctx` e
   `COLI_TOOL_FALLBACK`; o Colibri fica como preset de chat curto.

### `OMP_WAIT_POLICY`: ACTIVE → PASSIVE (decisão do Lucas, 2026-11-02)

Com `ACTIVE`, o worker `qwen36 256` ficava a **~500% de CPU parado** (6 threads OpenMP em spin-wait,
GPU em 0%, nenhuma conexão aberta) enquanto o preset estivesse de pé. Esse custo de idle existia desde
o §15 e nunca tinha sido medido.

| `OMP_WAIT_POLICY` | decode (3 runs) | CPU parado |
|---|---|---|
| ACTIVE | 36.20 (35.61-36.89) | ~500% |
| **PASSIVE** | **33.57** (32.98-34.21) | **0.3%** |

−7.3% de decode (ranges não se sobrepõem, então é real), ainda bem acima do piso de 19 tok/s.
Trocado porque o preset passa a maior parte do tempo ocioso entre requests.

### Armadilhas

- **Colibri é híbrido: CPU alta durante a inferência é esperado.** Com o tier CUDA ativo, os ~30% dos
  experts fora da VRAM rodam na CPU. No prefill do opencode: GPU 39-74% / 120-190 W **e** worker a
  210% de CPU. "Só CPU" de verdade é o sintoma do §15 (`[qtier] ... tier disabled`) ou da MOK
  (`project_ancalagon_mok_apagada`): confira `nvidia-smi --query-gpu=memory.used` (~14 GB) antes de
  concluir.
- **A RAM do Anc fica no limite com o Colibri:** 29.2 GB RES de 31 GB, 0 disponível, swap em uso.
  Qualquer coisa que aumente a memória dele (`--ctx` maior) vai para o swap.
- **O Colibri atende um request por vez e não cancela quando o cliente cai.** Matar o opencode deixa
  os requests já aceitos rodando até o fim, e um request novo recebe **429** nesse meio-tempo. Para
  limpar, `lmswitch off && lmswitch colibri`.
- **opencode 2.2.5: `opencode run --standalone` travou** logo após as migrações do banco, sem enviar
  nenhum request. Sem `--standalone`, o `opencode serve --service` em background às vezes trava o run
  seguinte (o mesmo sintoma: zero requests no servidor). Contorno: `pkill -f "opencode serve"` antes
  do run. Antes de culpar o Anc, confira no log do servidor se chegou algum `POST`.
- **`mnt-fury.mount` falha no boot** (`ntfs3: volume is dirty and "force" flag is not set`) desde
  pelo menos 2 boots antes desta janela. É a partição NTFS `Fury` (Kingston FURY 2 TB, lado Windows),
  e não tem relação com o upgrade. Fix: `chkdsk` pelo Windows.

### gpu-unlock (tensor cores FP16/BF16→FP32 a 2×): teto medido antes de instalar

Avaliados [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) e o fork
[JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada). O fork tem o
`10de:2705` (este 4070 Ti SUPER, AD103) testado em **uma** placa, atrás de opt-in
(`gpu_unlock.ad103_experimental=1` + PCI exato). O relatório do 2705 dobra **só** FP16/BF16 com
acumulação FP32; **INT8 (379.5 TOP/s), dp4a e FP16→FP16 ficam iguais**. É um módulo de kernel que roda
um payload no SEC2 antes do driver, e o primeiro teste pede corte de energia na tomada.

Antes de instalar, o teto foi medido com `nsys` (CUDA 13.4): o `ExecStart=` de cada preset rodou sob
o profiler, com 1 prefill de ~14.5K tokens (o tamanho de um turno do opencode), `cache_prompt:false`.

| Preset | prefill | tempo GPU | MMQ (INT8, não muda) | flash-attn (FP16 mma, candidato) | teto do ganho no prefill |
|---|---|---|---|---|---|
| coder | 1960 tok/s, 7.39 s | 2.93 s (o resto é CPU: `--n-cpu-moe 16`) | 54% | 860 ms (29% da GPU) | **≤ 5.8%** |
| qwen36 | 1367 tok/s, 10.60 s | 10.61 s | 66% | 587 ms (5.5%) | **≤ 2.8%** |

O teto assume o kernel de flash attention inteiro rodando 2× mais rápido, o que é otimista. Decode é
memory-bound e fica igual. O qwen38 tem a mesma arquitetura do qwen36 (`qwen35`, DeltaNet híbrido);
o gemma4 não foi medido. **Recomendação (2026-11-02): não instalar**. Ganho de poucos % em prefill não paga o risco de um módulo de
kernel experimental validado em uma placa. Reabrir só se um preset passar a usar pesos FP16/BF16
(cuBLAS com acumulação FP32) ou se o llama.cpp mudar o MMQ para outro caminho.

## 18. Adição do preset Flint — Recursive Flint 40B-A2.5B + rebuild do llama.cpp upstream (2026-11-02)

**Modelo:** [RecursiveSI/flint](https://huggingface.co/RecursiveSI/flint) (Apache 2.0), MoE treinado do
zero para agente de código: 39.8B total / ~2.5B ativos, 49 camadas (2 densas + 47 MoE, 256 experts,
top-6 + 1 compartilhado), **35 camadas de sliding window (513 tokens) + 14 de atenção completa**,
contexto nativo 262K, tool calling OpenAI-compatível com `reasoning_content` separado. GGUF
[`unsloth/flint-GGUF`](https://huggingface.co/unsloth/flint-GGUF) `UD-Q4_K_XL` (25.05 GB, sha256
`63c2ecc4…e072f` conferido), em `~/models/gguf/` (no `/`; o `/mnt/black` só tinha 25 GB livres).
Benchmarks do card são do fabricante (SWE-bench Verified 74.2%, Terminal-Bench 2.1 54.9%) — não
replicados aqui; o que vale é o teste de opencode abaixo.

### Rebuild do upstream

A arquitetura `flint` exige o PR #30928 (commit `a37cc461`). Upstream foi de `b10380-17-g84e908c6`
(2026-08-12) para **`b12061-1-g29c720eaf`** (1665 commits; `--version` agora imprime `0.8.0-dev
(build 3168, commit 29c720eaf)`), com `scripts/build-llama.sh upstream`. Backup do `build/bin`
anterior (83 MB) em `~/llama-backup/upstream-b10380-20261102/bin` — roda direto de lá para rollback.
O fork TQ3 (qwen36/qwen38) **não** foi tocado. A/B dos presets que usam o upstream (`bench-presets.py`):

| Preset | decode antes → depois | prefill antes → depois | VRAM |
|---|---|---|---|
| coder | 89.14 → **86.95** tok/s (−2.5%) | 1821 → 1801 | 15174 → 15222 MiB |
| gemma4 | 84.73 → **85.15** tok/s | 2108 → 2155 | 13916 → 13932 MiB |

−2.5% no coder: acima do ruído entre runs (86.5–87.5), muito acima do piso (55). Aceito.

### Sweep de `--n-cpu-moe` (ctx 131072, KV q8_0/q8_0, `-t 12`, `-fa 1`)

| ncmoe | decode | prefill (~2K tok) | VRAM |
|---|---|---|---|
| 28 | 79.9 tok/s | 913 tok/s | 13280 MiB |
| **24** | **82.6 tok/s** | **1081 tok/s** | **15152 MiB** |
| 20 | não carrega (OOM) | — | — |

Cada camada de experts custa ~470 MiB de VRAM; 22–23 ficariam com <1 GB de folga. **Adotado: 24** neste sweep (depois
virou 25 para caber o ubatch 2048 — ver abaixo). O KV é barato porque só as 14 camadas de atenção completa guardam
contexto longo: 14 × 2 × 4 heads × 128 × 1 B (q8) ≈ 14 KB/token → 128K ≈ 1.8 GB. 262K caberia
trocando ~2 camadas para a CPU (~−1.5 tok/s); não foi preciso. Pelo `bench-presets.py` (preset
via `lmswitch`): **85.39 tok/s decode, 1124 tok/s prefill, 15130 MiB**. Carga a frio do GGUF: 75 s
(`wait_ready` do `flint` espera até 180 s); quente (page cache): 2 s.

### Opencode (direto na `:1234`, opencode 2.2.5)

- **Tool calling nativo** (curl): `finish_reason=tool_calls`, argumentos corretos, raciocínio em
  `reasoning_content` — sem o `COLI_TOOL_FALLBACK` que o Colibri exigia.
- **Tarefa simples** (`calc.py` com bug de média): 28 s, `Read → Edit → $ python3 calc.py`.
- **Tarefa difícil** — `durations.py` com 2 bugs (`qty > 1`, `if t` em vez de `t.strip()`) + implementar
  `parse_duration` estrito (rejeitar vazio, unidade repetida/desconhecida, número sem unidade, `1.5h`,
  `-1s`), 9 testes `unittest` que não podem ser alterados, limite de 600 s:

| Preset | Resultado | Tempo | Tool calls |
|---|---|---|---|
| flint (run 1) | **9/9 OK**, testes intactos | 127 s | 11 |
| flint (run 2) | **9/9 OK**, testes intactos | 236 s (inclui ~50 s de carga a frio) | 11 |
| coder | **estourou 600 s**, 1 falha (`test_invalid`) | 600 s | 51 (em loop) |

Solução do flint limpa (regex âncora + conjunto de unidades vistas + `qty > 0` + `t.strip()`). n=2
contra n=1: amostra pequena, mas a diferença é qualitativa (terminar vs. entrar em loop).

### Sweep de ubatch × threads (prompt de ~14K tokens = um turno do opencode)

O §3 tinha concluído "default 512 já satura" olhando só pp512 — mas a coluna pp4096 da mesma tabela
já mostrava 778 → 1587 tok/s com ubatch 2048. Com experts na CPU, o lote maior dilui a cópia dos
pesos para a GPU. Medido no flint (ctx 131072, KV q8_0, `-b = max(ub, 2048)`):

| ub | t | ncmoe | decode | prefill 14K | turno 14K | VRAM |
|---|---|---|---|---|---|---|
| 512 | 12 | 24 | 85.6 | 1144 tok/s | 12.3 s | 15154 MiB |
| 1024 | 12 | 24 | 84.5 | 1916 | 7.3 s | 15354 |
| 2048 | 12 | 24 | 84.5 | 2906 | 4.8 s | 15772 (só ~600 MiB livres) |
| 4096 | 12 | 26 (24/25 = OOM) | 82.1 | 3404 | 4.1 s | 15762 |
| 2048 | 12 | 25 | 83.3 / 83.7 | 2814 | 5.0 s | 15324 |
| 2048 | 8 | 25 | 83.8 | 2816 | 5.0 s | 15324 |
| **2048** | **6** | **25** | **86.5 / 86.5** | **2815** | **5.0 s** | **15324** |
| 2048 | 5 | 25 | 85.2 | 2805 | 5.0 s | 15324 |

**Adotado: `-ub 2048 -b 2048 -t 6 --n-cpu-moe 25`.** ub 4096 ganha só 0.9 s por turno e custa
−4.5 tok/s de decode (precisa de ncmoe 26). `-t 6` (núcleos físicos do 7600X) bate `-t 12` em
+3.5% de decode, reproduzido em duas rodadas; prefill não muda (é a GPU). Isto contradiz o §4
(`-t 12` +5-8% em MoE, medido no LM Studio): **reabrir o `-t` do coder e do gemma4**, e o ubatch
deles, porque o mesmo raciocínio vale. `bench-presets.py` com a config final: **86.61 tok/s decode,
2651 tok/s prefill (~2K), 15282 MiB**. Opencode, tarefa difícil: **9/9 em 73 s** (era 127 s), 11 tool
calls — 3 de 3 rodadas resolvidas.

**Armadilhas:**
- **Primeiro run "travou" 400 s sem nenhum request no `journalctl`** — era um `opencode serve --service`
  pendurado de run anterior (a trava conhecida do 2.2.5, §17), não o modelo. `pkill -f opencode` antes.
- **Prefill com ubatch default (512) era menor que o do coder** (1124 vs 1801 tok/s): mais experts na
  CPU. Resolvido pelo sweep acima (2651 tok/s com ub 2048).
- **Disco:** com o GGUF, o `/` ficou em 96% (8.9 GB livres). Os `qwen2.5-*` de abril em
  `~/models/gguf/` (36 GB) não são citados por nenhum unit nem wrapper no Anc — candidatos a limpeza (não apagados).

## 19. ubatch 2048 + `-t 6` no coder e no gemma4 (2026-11-02)

Mesmo sweep do §18 (`moe-sweep.py`: prompt de ~15K tokens com nonce, `cache_prompt:false`, decode =
média de 3 runs após 1 descartado), ctx 98304 e KV q4_0 como em produção, build b12061:

| Preset | ub | t | ncmoe | decode | prefill 15K | turno 15K | VRAM |
|---|---|---|---|---|---|---|---|
| coder | 512 | 12 | 16 | 85.7 | 2016 tok/s | 7.5 s | 15232 MiB |
| coder | 2048 | 12 | 16 | 85.5 | 3939 | 3.8 s | 15740 |
| coder | 2048 | 8 | 16 | 87.9 | 3928 | 3.8 s | 15740 |
| coder | 2048 | 6 | 16 | 89.2 / 89.4 | 3927 / 3935 | 3.8 s | 15740 (~640 MiB livres) |
| coder | 1024 | 6 | 16 | 89.4 | 3039 | 5.0 s | 15416 |
| **coder** | **2048** | **6** | **17** | **86.9** | **3854** | **3.9 s** | **15416** |
| gemma4 | 512 | 12 | 8 | 85.2 | 2511 | 6.0 s | 13966 |
| gemma4 | 2048 | 12 | 8 | 85.4 | 4655 | 3.2 s | 14548 |
| gemma4 | 2048 | 8 | 8 | 86.9 | 4645 | 3.2 s | 14548 |
| **gemma4** | **2048** | **6** | **8** | **87.4** | **4660** | **3.2 s** | **14548** |
| gemma4 | 1024 | 6 | 8 | 87.6 | 3761 | 4.0 s | 14160 |

**Adotado:** coder `-t 6 --n-cpu-moe 17 -ub 2048 -b 2048`; gemma4 `-t 6 --n-cpu-moe 8 -ub 2048 -b 2048`.
No coder a regra foi a mesma do flint — manter ~1 GB de VRAM livre: ncmoe 16 com ub 2048 deixava ~640
MiB. Empate técnico com `ub 1024 / ncmoe 16` (mesma VRAM, +2.5 tok/s de decode, −21% de prefill);
venceu o prefill porque o coder é o backend do `srl-coder`, cujo system prompt do Claude Code tem ~32K
(~8 s em vez de ~10.5 s no primeiro turno). O gemma4 cabe o ub 2048 sem mexer no ncmoe.

