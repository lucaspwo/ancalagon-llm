# Atualizar llama.cpp (Fase 1) — design

Data: 2026-06-01

## Contexto

O Ancalagon roda três presets de inferência via `llama-server`, compilados manualmente
contra CUDA sm_89 (RTX 4070 Ti SUPER, Ada Lovelace):

- `llama-coder` e `llama-gemma4` → binário do **upstream** `ggml-org/llama.cpp`
  (`/home/lucas/git/llama.cpp`)
- `llama-qwen36` → binário do **fork TQ3** `turbo-tan/llama.cpp-tq3`
  (`/home/lucas/git/llama.cpp-tq3`), que adiciona o quant ternário TQ3_4S

Estado no momento do design (medido em 2026-06-01):

| Repo | Branch | Commit local | Atrás de | Binário compilado |
|---|---|---|---|---|
| upstream | master | `b76429a` (2026-04-22) | 549 commits | 2026-04-23 |
| fork TQ3 | main | `794c5dc` (2026-04-21) | 433 commits | 2026-04-23 |

Driver NVIDIA atual: `595.71.05` (mantido em `apt-mark hold` junto de cuda/kernel/dkms).
Kernel `6.8.0-111`.

## Objetivo

Atualizar os dois binários do `llama.cpp` para servir três objetivos do usuário:

1. **Ganho de performance** — apenas se comprovado por medição; não assumido.
2. **Aptidão a modelos/features novos** — genérico, sem alvo específico.
3. **Higiene** — reduzir dívida (5+ semanas atrás), pegar bugfixes.

### Premissa explicitamente desafiada

Uma amostra dos commits CUDA/perf do range upstream mostrou majoritariamente bugfix,
Vulkan (não usado), AMD MFMA (hardware diferente) e otimização de Turing (sm_75, não Ada).
**Ganho de tok/s neste hardware é incerto e possivelmente nulo.** O update se justifica
pelos objetivos 2 e 3 mesmo sem ganho de perf — daí o critério "manter se não regredir".

## Não-objetivos (Fase 1)

- **Driver NVIDIA 595→610** — adiado para a Fase 2 (janela dedicada). Serve só "higiene",
  carrega o maior risco (suspend/resume S3, DKMS, reboot) e ganho de perf ≈ 0.
- **Mudar configs dos services** (`--n-cpu-moe`, `-c`/ctx, KV quant) — mantidos idênticos.
  A única variável que muda nesta fase é a **versão do binário**.
- **Baixar modelos novos.**

## Princípio metodológico

Herdado do `benchmarks/TUNING.md`: **uma variável por vez, baseline medido antes,
rollback garantido**. O upstream e o fork são tratados como **duas variáveis independentes**,
decididas (manter/reverter) separadamente.

## Estado atual / ambiente

- Build flags (de `build/CMakeCache.txt`, idênticas nos dois repos):
  `CMAKE_BUILD_TYPE=Release`, `CMAKE_CUDA_ARCHITECTURES=89`, `GGML_CUDA=ON`,
  `GGML_NATIVE=ON`.
- Recursos: 52 GB livres em `/`, 12 cores (build ≈ 10-20 min cada).
- Acesso ao Ancalagon: `ssh lucas@100.91.10.22` (Tailscale) ou `ssh lucas@192.168.1.8` (LAN).
- Services têm `Conflicts=` — só um sobe por vez, garantindo GPU livre para cada bench.
- Baseline de referência conhecido (TUNING.md, a ser reconfirmado fresh):
  coder ~78 tok/s, gemma4 ~84 tok/s, qwen36 TQ3 ~37 tok/s.

## Sequência

### Passo 0 — Baseline (antes de tocar em nada)

Para cada um dos três services, subir via `lmswitch`/`make`, medir e registrar:

- **tok/s de geração** com o prompt canônico do TUNING.md:
  `"Explain quantum entanglement in exactly 5 paragraphs"`, `max_tokens=400`, `T=0.2`,
  via `POST :1234/v1/chat/completions` (ou `/completion` lendo `timings.predicted_per_second`).
- **VRAM usada** (`nvidia-smi`).
- **(Somente qwen36 TQ3)** o **teste de qualidade** do TUNING.md §5: código Python com
  bug de concorrência (TOCTOU / lock granularity) + bug de wall clock (`time.time()`
  não-monotônico). Registrar se identifica os 3 bugs críticos.

Salvar os números num arquivo temporário de baseline (ex.: `/tmp/llama-baseline.txt`).

### Passo 1 — Backup dos binários (rollback instantâneo)

```
cp /home/lucas/git/llama.cpp/build/bin/llama-server      .../llama-server.bak-b76429a
cp /home/lucas/git/llama.cpp-tq3/build/bin/llama-server  .../llama-server.bak-794c5dc
```

Anotar os commits atuais. Rollback = restaurar o `.bak` (não precisa recompilar o antigo).

### Passo 2 — Atualizar upstream

```
cd /home/lucas/git/llama.cpp
git pull            # b76429a → HEAD; anotar novo commit
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 \
      -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON
cmake --build build --config Release -j 12 -t llama-server
```

Re-benchmark **coder** e **gemma4** (ambos usam este binário), mesmo prompt/params do baseline.

### Passo 3 — Atualizar fork TQ3

```
cd /home/lucas/git/llama.cpp-tq3
git pull            # 794c5dc → HEAD; anotar novo commit
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 \
      -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON
cmake --build build --config Release -j 12 -t llama-server
```

Re-benchmark **qwen36** + **re-rodar o teste de qualidade ratelimiter**.

### Passo 4 — Decisão manter/reverter (por binário, independente)

- **Manter** se: `tok/s_novo ≥ tok/s_baseline × 0.95` **E** (no TQ3) qualidade preservada
  no teste ratelimiter. Mantém mesmo sem ganho de perf — objetivos 2 e 3 já justificam —
  desde que não regrida mais que 5%.
- **Reverter** (restaurar `.bak`, instantâneo) se: regressão > 5% **ou** degradação de
  qualidade no TQ3.

O upstream e o fork são decididos separadamente.

### Passo 5 — Script de build reproduzível

Criar `scripts/build-llama.sh` parametrizado (upstream | tq3) documentando o comando exato
de configure+build. Hoje não existe — o build é tribal knowledge.

### Passo 6 — Documentar

- `benchmarks/TUNING.md`: nova seção com antes/depois (tok/s por modelo) e os commits novos.
- `CLAUDE.md`: atualizar os commits/datas de referência se forem mantidos.

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Build falha | Binário antigo intacto; zero impacto operacional |
| Fork TQ3 não compila após pull (divergência do 3º) | Mantém `.bak`, reporta; **não bloqueia** o upstream (já decidido/documentado) |
| Regressão de perf | Rollback instantâneo (restaura `.bak`) |
| Quant TQ3 muda silenciosamente (thresholds) | Teste de qualidade ratelimiter detecta |
| GPU ocupada durante bench | `Conflicts=` garante 1 service por vez; checar `nvidia-smi` antes de cada bench |
| Flags de build divergem do original | Flags fixadas explicitamente no comando (sm_89/Release/CUDA/NATIVE) |

## Critério de conclusão

- Os três models benchmarkados antes e depois, números registrados no TUNING.md.
- Cada binário ou mantido (sem regressão) ou revertido ao `.bak` (com a regressão documentada).
- `scripts/build-llama.sh` criado e funcional.
- Configs dos services inalteradas.

## Fase 2 (futuro, fora deste spec)

Driver NVIDIA 595→610 isolado: `apt-mark unhold` da stack, upgrade, reboot, DKMS rebuild,
**teste de suspend/resume S3** (`make sleep`/`make wake`) e re-bench dos três models sem
recompilar — para isolar o efeito do driver. Decisão manter/reverter análoga.
