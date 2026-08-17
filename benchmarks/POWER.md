# Consumo de energia — Ancalagon GPU

Consolida medições de potência da GPU (RTX 4070 Ti SUPER, TGP máximo 285W) por estado operacional. Todos os valores são **da GPU apenas** — não incluem CPU, placa-mãe, display, etc.

Fonte: `nvidia-smi --query-gpu=power.draw,utilization.gpu,memory.used --format=csv,noheader,nounits`, médias de 5-115 amostras por medição.

## Estado atual

| Estado | Power (GPU) | GPU util | VRAM usada | Sobre o mínimo |
|---|---|---|---|---|
| GPU dormente (sem service) | **22.2W** | 0% | 34 MiB | — |
| `llama-coder` idle (modelo carregado, sem request) | **25.8W** | 0% | 15354 MiB | +3.6W |
| `llama-coder` em inference | **101W** | ~40% | 15354 MiB | +79W vs dormente |
| `llama-qwen36` idle (modelo carregado, sem request) | **25.8W** | 0% | 15142 MiB | +3.6W |
| `llama-qwen36` em inference | **288W** | 96% | 15142 MiB | +266W vs dormente |

Medições feitas em **2026-04-24**, com a config vigente naquela data: coder ctx=96K ncmoe=16, qwen36 ctx=32K (TQ3 fork).

O `llama-qwen36.service` opera hoje com **ctx=40K** (`-c 40960`). Os valores de power e utilização acima seguem válidos — consumo é função da carga de compute, não do tamanho do contexto —, mas a **VRAM usada do qwen36 é maior que os 15142 MiB da tabela**, porque o KV cache cresce linear com o contexto. Para VRAM corrente, medir; para power, usar a tabela.

## Interpretação

**Modelo carregado não consome energia significativa em idle** (+3.6W sobre dormente). O driver CUDA deixa a GPU entrar em P-state baixo quando não há compute ativo. Significa que manter um service carregado entre usos é barato; não precisa parar o service por economia de energia se há chance de usar de novo na mesma hora.

**Coder usa só 35% do TGP** (101/285W). Confirma o diagnóstico de "CPU é o gargalo" — o offload de experts para a CPU (`--n-cpu-moe 16`) deixa a GPU esperando dados pela maior parte do tempo. Ganhar mais tok/s aqui exigiria reduzir a fração CPU (já otimizado) ou trocar o modelo por um menor que caiba 100% GPU.

**Qwen36 TQ3 satura a GPU** (288/285W, ocasionalmente excedendo TGP nominal dentro da margem de boost). O modelo TQ3_4S cabe 100% em VRAM, atenção e experts todos na GPU, inferência linear no compute da 4070 Ti SUPER. Este é o **pior caso de consumo** no setup atual — qualquer config futura não deve ultrapassar isso muito.

## Custo por hora de uso

Tarifa real da conta do Lucas, **já com todos os tributos** (PIS 1,02%, COFINS 4,67%, ICMS 20%):
- Consumo TUSD: **R$ 0,57337503/kWh**
- Consumo TE: **R$ 0,41305269/kWh**
- **Tarifa efetiva: R$ 0,98642772/kWh**

Atualmente **sem bandeira tarifária** (adicional zero). Custo fixo mensal separado: **Contribuição de Iluminação Pública (CIP) R$ 49,67/mês** — independe do consumo e não entra no cálculo marginal abaixo.

| Cenário (GPU apenas) | Power médio | Custo/h | Custo/dia (8h) | Custo/mês (24/7) |
|---|---|---|---|---|
| Dormente / desligado | 22W | R$ 0,022 | R$ 0,17 | R$ 15,62 |
| Coder idle o dia todo | 26W | R$ 0,026 | R$ 0,21 | R$ 18,46 |
| Coder inferindo 100% do tempo | 101W | R$ 0,100 | R$ 0,80 | R$ 71,73 |
| Qwen36 inferindo 100% do tempo | 288W | R$ 0,284 | R$ 2,27 | R$ 204,53 |

Observações:
- Uso real é uma mistura de idle + bursts curtos de inference. Valor efetivo fica muito abaixo da linha "inferindo 100% do tempo".
- **Manter coder carregado 24/7 em idle custa apenas +R$ 2,85/mês** sobre ter o Ancalagon ligado mas sem service (R$ 18,46 − R$ 15,62) — é essa diferença (não o total) que pesa na decisão de `anc_lin_off`.
- Adicionar ~50-100W para CPU/placa/fontes para chegar ao consumo total do sistema.
- Se bandeira subir (amarela +R$ 0,01885/kWh, vermelha 1 +R$ 0,04463/kWh, vermelha 2 +R$ 0,07877/kWh), multiplicar o consumo pelo adicional. Em bandeira vermelha 2 o coder inferindo 100% custaria R$ 0,008/h extra.

## Quando vale a pena parar o service

Regra prática, dada a diferença de apenas +3.6W entre modelo carregado e GPU dormente:

- **Não vale a pena** `anc_lin_off` entre usos num mesmo dia de trabalho. Manter o modelo carregado custa apenas +R$ 0,004/h (diferença entre 26W e 22W dormente, tarifa regulada). Reload leva 20-60s — o trade em tempo humano é desfavorável.
- **Vale a pena** `anc_lin_off` quando:
  - Sabe que vai ficar >2h sem usar
  - Quer liberar GPU para outro workload (jogo, fine-tuning, experimento)
  - Vai dormir ou sair da casa
  - Quer trocar entre coder ↔ qwen36 (o `lmswitch` faz isso automaticamente via `Conflicts=`)

## Histórico comparativo (pré-tuning)

Valores observados no LM Studio antes da migração para llama.cpp nativo, para referência:

| Config (pré-migração) | Power | GPU util | tok/s |
|---|---|---|---|
| LM Studio — qwen3-coder Q4_K_M offload 0.80 | 67W | 30% | 64.5 |
| LM Studio — qwen3-coder Q4_K_M offload 0.70 (com KV em f16 acidental) | 94W | 30% | 51.5 |
| LM Studio — qwen3.6-27b Q4_K_M offload 0.85 | 94W | 34% | 13.7 |

A migração para llama.cpp nativo subiu power **e** tok/s no coder (era 67W/64.5 → 101W/78, mais trabalho útil por watt). No qwen36, a troca para TQ3 subiu power drasticamente (94W → 288W) mas **dobrou o tok/s** (13.7 → 36.8). Relação W/(tok/s) melhorou nos dois casos.

## Baseline de "GPU saturada" para comparação

Rodando Qwen3.5-9B Q4_K_M (7.2 GB, 100% GPU, sem offload): **217W, 91.7% util, 90 tok/s**. Mostra que:
- TGP da 4070 Ti SUPER permite ~215-290W dependendo de como a carga pressiona diferentes unidades da GPU
- TQ3 a 288W está saturando mais intensamente que o modelo Q4_K_M 9B, provavelmente por usar kernels ternary-specific mais paralelos

## Como remedir

```bash
# Sample de 10 pontos, 1s de intervalo, média
for i in $(seq 1 10); do
  nvidia-smi --query-gpu=power.draw,utilization.gpu,memory.used \
    --format=csv,noheader,nounits
  sleep 1
done | awk -F, '{ p+=$1; u+=$2; m=$3; n++ } \
  END { printf "%.1fW %.1f%% %d MiB (n=%d)\n", p/n, u/n, m, n }'
```

Evitar `-lms -c N`: combinação com amostragem curta causa `division by zero` em awk quando o csv header aparece na stream. O loop acima é equivalente e mais previsível.
