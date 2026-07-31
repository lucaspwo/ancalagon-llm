# Handoff — LLM local em 8 GB de VRAM (RX 6600 + Ryzen 9 5900XT)

Documento de transferência de experiência do projeto **ancalagon-llm** para quem está montando
um servidor LLM local em hardware diferente. Escrito para ser lido por um assistente de código
(Claude Code, opencode, etc.) que vai executar o bring-up junto com o dono da máquina.

**Origem:** setup do Ancalagon — Ubuntu Server 24.04, RTX 4070 Ti SUPER (16 GB), Ryzen 5 7600X
(6C/12T, DDR5), `llama.cpp` compilado com CUDA + systemd `--user`. Dados brutos em
[`benchmarks/TUNING.md`](../benchmarks/TUNING.md) e [`benchmarks/POWER.md`](../benchmarks/POWER.md).

**Destino:** Linux, Radeon RX 6600 (8 GB, Navi 23 / gfx1032), Ryzen 9 5900XT (16C/32T, AM4),
32 GB DDR4.

---

## 1. Como ler este documento

O hardware de destino **não é o nosso**. Backend diferente (ROCm/Vulkan vs CUDA), metade da
VRAM, um terço da banda de memória de GPU. Copiar nossos números seria a pior forma de usar
este documento. Por isso toda afirmação carrega um rótulo:

| Rótulo | Significa | Como tratar |
|---|---|---|
| `[MEDIDO]` | Número real, colhido no nosso hardware CUDA | Referência de ordem de grandeza e de *método*. **Não é meta.** |
| `[TRANSFERÍVEL]` | Comportamento estrutural do `llama.cpp` ou da arquitetura, independente de GPU | Pode confiar sem remedir |
| `[DERIVADO]` | Estimativa calculada a partir das specs do hardware novo | Ponto de partida — validar com medição |
| `[MEDIR]` | Não sabemos; depende de gfx1032 / ROCm / Vulkan | **Gerar o número antes de decidir** |

Se em algum momento o documento e a máquina discordarem, a máquina está certa.

---

## 2. O terreno: seu hardware vs o nosso

| | Ancalagon (origem) | Destino | Consequência |
|---|---|---|---|
| GPU | RTX 4070 Ti SUPER | RX 6600 | — |
| VRAM | 16 GB | **8 GB** | Metade do orçamento; contexto vira recurso escasso |
| Banda VRAM | ~672 GB/s | **~224 GB/s** | **~1/3 dos tok/s no mesmo modelo — por física** |
| Backend | CUDA sm_89 | ROCm (gfx1032, não-oficial) ou Vulkan | Todos os nossos números de tuning invalidados |
| CPU | 6C/12T Zen 4 | **16C/32T Zen 3, dual-CCD** | Muito melhor para offload de MoE |
| RAM | DDR5 (~75 GB/s) | DDR4 (~45 GB/s se em 3200 dual-channel) | Offload de MoE ~40% mais lento que o nosso |
| iGPU para vídeo | n/a | **não tem** (5900XT não é APU) | O desktop come VRAM da mesma GPU que infere |

### A ferramenta mental mais útil: teto por banda

Geração de token é **memory-bandwidth-bound**, não compute-bound. O teto teórico é:

```
tok/s_teto ≈ (banda_efetiva GB/s) / (GB lidos por token)
```

Onde "GB lidos por token" = tamanho dos **pesos ativos** (num modelo denso, todos; num MoE,
só os experts ativados + attention). A eficiência real fica em **0,65–0,75** da banda nominal.

`[MEDIDO]` Validação da fórmula no nosso hardware: Qwen3.6-27B-TQ3_4S, 12,6 GB de pesos,
100% GPU, **36,8 tok/s**. Isso implica 464 GB/s efetivos de 672 nominais = **69% de eficiência**.
A fórmula prevê bem.

Use isso antes de baixar qualquer modelo. Se a conta der 12 tok/s, nenhuma flag vai transformar
em 40 — o problema é a escolha do modelo, não o tuning.

---

## 3. Etapa 0 — reconhecimento

Rode isto **antes** de instalar qualquer coisa e anote as saídas; várias decisões abaixo dependem delas.

```bash
# GPU: confirmar Navi 23 e o gfx real
lspci -nn | grep -i vga
# Se rocminfo já existir:  rocminfo | grep -i gfx

# VRAM total e livre agora (com o desktop rodando)
glxinfo -B 2>/dev/null | grep -i "memory\|device"
# ou, mais direto, se amdgpu_top estiver instalado:
amdgpu_top -d

# RAM: total e — crítico — se está em dual-channel e na velocidade certa
sudo dmidecode -t memory | grep -E "Size|Speed|Configured|Locator" | grep -v "No Module"

# Cores físicos vs lógicos e topologia de CCD
lscpu | grep -E "^CPU\(s\)|Core|Thread|NUMA|L3"

# Espaço em disco (cada GGUF grande são 5-20 GB)
df -h ~
```

### Três itens de checklist que valem mais que qualquer flag

**1. Memória em dual-channel e no perfil DOCP/EXPO.** `[TRANSFERÍVEL]` Se os 32 GB estiverem
em um único pente, ou rodando no default JEDEC 2133 em vez de 3200, o preset MoE (seção 8)
perde **até um terço** da velocidade. `dmidecode` mostrando `Configured Memory Speed: 2133`
com módulos de 3200 = ir na BIOS habilitar DOCP. É o ganho mais barato de todo o setup.

**2. O desktop está comendo VRAM.** `[TRANSFERÍVEL]` Sem iGPU, a RX 6600 dirige o monitor e
o compositor. Em 16 GB isso era ruído; em 8 GB são **0,5–1 GiB, ou ~12% do orçamento**. Meça
com o desktop aberto e depois num TTY puro (`Ctrl+Alt+F3`, e pare o display manager) — a
diferença é o que você pode recuperar. Opções, em ordem de custo:
   - aceitar e trabalhar com o orçamento reduzido (mais simples, e provavelmente o certo no início);
   - rodar a máquina headless de verdade (sem DE) e acessar por SSH — é o que fazemos no Ancalagon;
   - uma GPU velha/barata só para vídeo, liberando a RX 6600 inteira.

**3. Não confunda apagar o monitor com liberar VRAM.** `[TRANSFERÍVEL]` Nosso
[`bin/videoswitch`](../bin/videoswitch) desliga a saída de vídeo (DPMS) para não deixar imagem
estática nos monitores — ele **não devolve VRAM**. Para recuperar memória é preciso parar o
servidor gráfico, não apenas apagar a tela.

---

## 4. Calibração de expectativa

Esta seção existe para evitar semanas perseguindo um número inalcançável.

**8 GiB de VRAM comportam três coisas ao mesmo tempo:** pesos do modelo, KV cache e buffer de
compute. Elas competem. `[TRANSFERÍVEL]`

- **Pesos:** o tamanho do arquivo GGUF, aproximadamente.
- **KV cache:** cresce **linear no contexto**. Fórmula:
  ```
  bytes_KV ≈ 2 × n_layers × n_kv_heads × head_dim × n_ctx × bytes_por_elemento
  ```
  (`bytes_por_elemento`: 2 em f16, ~1,1 em q8_0, ~0,6 em q4_0.) Os três primeiros parâmetros
  saem do `config.json` do modelo no Hugging Face.
- **Buffer de compute:** 400–700 MiB, cresce com `--ubatch-size`.

Ordem de grandeza para um denso de 8B a 32K de contexto: pesos ~4,9 GiB, **KV em f16 ~4,3 GiB**,
compute ~0,6 GiB = 9,8 GiB. **Não cabe.** Com KV em `q4_0` o KV cai para ~1,2 GiB e o total vai
a ~6,7 GiB — cabe. É por isso que a seção 7 é o checkpoint mais importante do documento: em
8 GiB, **quantizar o KV cache não é otimização, é o que faz o contexto existir**.

### O piso de contexto de um agente de código

`[MEDIDO]` No Ancalagon, o system prompt + definições de tools do Claude Code consomem
**~32K tokens antes de qualquer conteúdo do usuário**. Foi exatamente por isso que subimos o
`llama-coder.service` de 32K para 96K de contexto (`benchmarks/TUNING.md` §2).

Consequência direta para 8 GiB: **um agente de código com contexto confortável é o caso de uso
mais apertado que existe nesse hardware.** Se a seção 7 der errado (sem KV quantizado), o
contexto viável cai para ~12–16K e agentes pesados em tools ficam inviáveis — o caminho passa
a ser um cliente mais enxuto (aider, opencode com poucas tools) ou um modelo menor.

### Números realistas para este hardware

`[DERIVADO]` — pela fórmula da seção 2, a validar:

| Cenário | Cálculo | Estimativa |
|---|---|---|
| Denso 7–8B Q4_K_M, 100% GPU | 224 × 0,7 ÷ 4,9 | **~30–35 tok/s** |
| MoE 30B-A3B, experts em DDR4 | 45 × 0,7 ÷ 1,4 | **~15–22 tok/s** |
| `[MEDIDO]` nosso coder MoE, para contraste | — | 84 tok/s |

Ver 20 tok/s onde nós vemos 84 **não é sinal de configuração errada**. É 1/3 da banda de VRAM
e 60% da banda de RAM. A pergunta certa é "estou perto do meu teto?", nunca "estou perto do
teto deles?".

---

## 5. On-ramp em três fases

Cada fase tem um critério objetivo de saída. Não avance sem o número em mãos.

### Fase 1 — funcionando (30–60 min)

Suba **Ollama** ou **LM Studio** com backend ROCm/Vulkan e carregue um modelo denso de 7–8B em
Q4_K_M. Objetivo é só ter um endpoint respondendo e um baseline.

**Saída:** um tok/s de geração anotado, com o modelo e o contexto usados.

Por que não ir direto ao `llama.cpp`: compilar para gfx1032 tem armadilhas próprias (seção 6).
Separar "meu hardware consegue inferir" de "meu build está certo" economiza horas de depuração
ambígua.

### Fase 2 — instrumentar e diagnosticar

Esta é a fase que justificou toda a migração do nosso lado, e é o aprendizado mais valioso
deste documento. `[TRANSFERÍVEL]`

Com o modelo gerando tokens continuamente, observe a GPU:

```bash
# qualquer um destes serve
amdgpu_top          # mais completo (VRAM, util, clocks, power)
radeontop           # leve, só util e VRAM
rocm-smi            # se o stack ROCm estiver instalado
watch -n1 'cat /sys/class/drm/card*/device/gpu_busy_percent'   # sempre disponível
```

Leia a utilização de GPU **durante a geração**:

- **> 85%** → você está no teto de banda. Ganhos só vêm de modelo menor ou quant menor. Tuning
  não vai render — considere parar na Fase 1 e não migrar.
- **25–45%** → **a GPU está esperando a CPU.** Há muito na mesa.

`[MEDIDO]` Foi exatamente este o nosso diagnóstico: o LM Studio nos dava 30–34% de utilização
e 70 W de um orçamento de 285 W. A migração para `llama.cpp` nativo levou o mesmo modelo de
64,5 para 81,5 tok/s, e o caso extremo (Qwen3.6-27B) de 13,7 para 36,8 tok/s — 34% → 96% de
utilização. **O número que autorizou o trabalho foi a utilização ociosa, não o tok/s.**

**Saída:** utilização de GPU sob carga + a decisão de migrar ou não, escrita com o número que a sustenta.

### Fase 3 — `llama.cpp` nativo

Só se a Fase 2 mostrou GPU ociosa. O que se ganha aqui e não existe nos wrappers:

| Recurso | Por que importa em 8 GB |
|---|---|
| `--n-cpu-moe N` | Coloca **só os experts** na CPU, mantendo attention/norm 100% na GPU. Wrappers só oferecem "N% das camadas", que é pior. É o que viabiliza o preset B. |
| `-ctk`/`-ctv` | Quantização de KV explícita e independente — o que faz o contexto caber |
| `-c` exato | Controle fino do contexto, em vez de presets redondos |
| `-t` | Sweep de threads, que no seu 16C dual-CCD é obrigatório |

Nosso script de build: [`scripts/build-llama.sh`](../scripts/build-llama.sh) — é CUDA, serve como
esqueleto; troque a flag de backend (seção 6).

**Saída:** o mesmo prompt da Fase 1 rodando no build nativo, com tok/s comparável lado a lado.

---

## 6. Backend: Vulkan ou ROCm

`[MEDIR]` — não temos nada medido em AMD. O que segue é o mapa do terreno, não uma conclusão.

**A RX 6600 é gfx1032 (Navi 23) e não está na lista de suporte oficial do ROCm** — a linha
RDNA2 suportada oficialmente é gfx1030 (Navi 21). Na prática roda com:

```bash
export HSA_OVERRIDE_GFX_VERSION=10.3.0   # faz a gfx1032 se passar por gfx1030
```

Funciona, mas é um caminho não suportado: quebra em upgrades, e mensagens de erro apontam para
o lugar errado.

**Recomendação: comece por Vulkan.** `llama.cpp` com backend Vulkan em RDNA2 instala com os
drivers Mesa que a distro já tem, sem stack ROCm de vários GB, sem override de gfx, sem
acoplamento a versão de kernel. Para geração de token (o que domina uso interativo), tende a
ficar próximo do ROCm — que costuma levar vantagem em *prompt processing*.

**Teste os dois e meça** — é meia hora de trabalho e resolve a dúvida em definitivo para a sua
máquina, o que este documento não pode fazer:

```bash
# builds paralelos, mesmo commit, diretórios separados
cmake -B build-vk   -DGGML_VULKAN=ON  && cmake --build build-vk   -j16
cmake -B build-rocm -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1030 && cmake --build build-rocm -j16

# compare com llama-bench, mesmo modelo, mesmos parâmetros
./build-vk/bin/llama-bench   -m modelo.gguf -p 512 -n 128
./build-rocm/bin/llama-bench -m modelo.gguf -p 512 -n 128
```

Decida pelo **tg** (geração) se o uso é interativo; pelo **pp** (prefill) se você vai jogar
prompts de dezenas de milhares de tokens (agente de código com muito contexto).

---

## 7. O teste que decide o resto: flash attention + KV quantizado

**Faça este teste antes de escolher modelo.** `[MEDIR]`

No `llama.cpp`, a **quantização do KV cache depende de flash attention** — sem FA funcional,
`-ctk q4_0 -ctv q4_0` não é aceito ou cai para um caminho lento. E Navi 23 **não tem WMMA**
(instruções de matriz introduzidas no RDNA3), então os kernels otimizados de FA podem não
existir no seu backend.

Como a seção 4 mostrou, isso não é um detalhe de performance: **é o que decide se 32K de
contexto cabem em 8 GiB.**

```bash
# 1. Sobe SEM KV quant, contexto pequeno — deve funcionar sempre
./llama-server -m modelo.gguf -c 8192 -ngl 99 --port 1234

# 2. Sobe COM FA e KV q4_0 — este é o teste
./llama-server -m modelo.gguf -c 32768 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 --port 1234

# 3. Se subiu: confirme que é rápido, não só que não quebrou.
#    Compare tok/s com o caso 1. Uma queda grande = fallback silencioso.
```

**Interpretação:**

| Resultado | O que fazer |
|---|---|
| Sobe e a velocidade se mantém | Melhor caso. Siga a seção 8 como escrita. |
| Sobe mas fica visivelmente mais lento | Fallback não otimizado. Teste `q8_0` simétrico como meio-termo. |
| Não sobe / erro de FA | Contexto viável cai para ~12–16K com KV f16. Reveja a seção 4 — provavelmente um modelo menor. |

**Armadilha crítica, não descubra sozinho** `[TRANSFERÍVEL]`: se for testar `q8_0`, use nos
**dois** lados. Ver seção 9, item 1.

---

## 8. Os dois presets

O pedido era "ambos" — agente de código e chat/reasoning. Em 8 GiB isso **não é um modelo só**,
são dois presets mutuamente exclusivos, exatamente como fazemos com os três do Ancalagon.

### Preset A — denso 7–8B, 100% GPU (o padrão)

O cavalo de batalha. Tudo em VRAM, latência baixa, previsível.

| Item | Valor |
|---|---|
| Modelo | denso de 7–8B em Q4_K_M (~4,5–5 GiB) |
| Contexto | 32K se a seção 7 passou; 12–16K se não |
| VRAM | ~4,9 (pesos) + ~1,2 (KV q4 @32K) + ~0,6 (compute) ≈ **6,7 GiB** |
| Velocidade | `[DERIVADO]` ~30–35 tok/s |
| Flags | `-ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -c 32768 --jinja` |

Folga sobre 8 GiB é de ~1,1 GiB — **e o desktop consome parte dela** (Etapa 0, item 2). Se der
OOM sob prompt longo, corte o contexto antes de mexer em qualquer outra coisa.

### Preset B — MoE 30B-A3B com experts na CPU (qualidade, lento)

Aqui está o achado que mais transfere do nosso projeto, e ele é **mais** relevante em 8 GiB do
que em 16 GiB. `[TRANSFERÍVEL]`

Num MoE, `--n-cpu-moe N` mantém attention, normalizações e camadas compartilhadas 100% na GPU
e empurra **apenas os experts** para a CPU. Como só uma fração dos experts é ativada por token,
você roda a qualidade de um modelo de 30B numa GPU que não comporta nem metade dele.

| Item | Valor |
|---|---|
| Modelo | MoE ~30B-A3B em Q4_K_M (~18 GB — mora na **RAM**, você tem 32 GB) |
| VRAM (com todos os experts na CPU) | ~3 (não-experts) + ~0,9 (KV q4) + ~0,6 ≈ **4,5 GiB** |
| Contexto | 32K viável — o KV de um MoE é menor que o de um denso equivalente |
| Velocidade | `[DERIVADO]` ~15–22 tok/s, limitada pela DDR4 |
| Flags | `-ngl 99 --n-cpu-moe <sweep> -fa 1 -ctk q4_0 -ctv q4_0 -c 32768 --jinja` |

Note a **folga de ~3 GiB** nesse preset. Ela não deve ficar ociosa: é aí que entra o sweep.

#### O sweep de `--n-cpu-moe` — faça, não copie

`[MEDIDO]` No nosso hardware, varrer essa flag rendeu **+47% de geração** no preset Gemma 4
(57 → 84 tok/s) só movendo experts entre CPU e GPU. E a curva **não é linear**: 16→12 rendeu
6 tok/s, 12→8 rendeu 21 tok/s, 8→4 rendeu 17 tok/s (`benchmarks/TUNING.md` §7).

O método, que é o que transfere:

1. Comece **alto** (todos os experts na CPU — para 48 camadas, `--n-cpu-moe 48`). Deve subir.
2. Baixe em passos, medindo tok/s **e VRAM livre** a cada ponto.
3. Continue até OOM ou até a VRAM livre ficar apertada.
4. **Volte um ou dois passos.** O ponto ótimo não é o mais rápido — é o mais rápido **que sobrevive a um prompt longo**.

`[MEDIDO]` Por que o passo 4 existe: no nosso sweep, `ncmoe=4` dava 101 tok/s contra 84 do
`ncmoe=8` — mas num prefill de 48K sobravam **107 MiB livres**. Trocamos 20% de throughput por
não travar em produção. **Meça a VRAM livre sob prefill longo, não em idle.** Em 8 GiB essa
disciplina importa ainda mais.

#### O sweep de `-t` — e por que nossa conclusão não serve para você

`[MEDIDO]` Concluímos `-t 12` no Ancalagon, ou seja, SMT completo dos 6 cores. `[TRANSFERÍVEL]`
**Não copie.** Aquilo era um 6-core single-CCD. Seu 5900XT tem 16 cores em **dois CCDs**, e em
carga memory-bound, threads cruzando CCD frequentemente pioram o resultado.

Varra `-t` em **8, 12, 16, 24, 32** com o preset B carregado. Espere o ótimo em algum lugar
entre 8 e 16 — mas o número é seu, não meu.

### Por que dois presets e não um

`[TRANSFERÍVEL]` Uma GPU, um endpoint, nunca dois modelos disputando VRAM. Modelamos isso com
`Conflicts=` do systemd (seção 10): o próprio init garante exclusão mútua, sem coreografia
manual de parar/subir e sem risco de OOM por sobreposição.

---

## 9. Armadilhas que já pagamos

Todas `[TRANSFERÍVEL]` — são comportamentos do `llama.cpp` e da metodologia, não do CUDA.

**1. KV cache assimétrico destrói a performance.** Usar quantizações diferentes em K e V
(`-ctk q8_0 -ctv q4_0`) provoca um fallback catastrófico. `[MEDIDO]` No Qwen3-Coder: 49,2 tok/s
com `q8_0/q8_0`, **3,16 tok/s** com `q8_0/q4_0`. No Qwen3.6, caiu para 1,22. **Sempre simétrico.**
É o tipo de bug que consome um dia inteiro porque nada falha — só fica absurdamente lento.

**2. KV quantizado paga por si ao permitir mais offload.** `[MEDIDO]` A VRAM liberada pelo
KV `q4_0` permitiu subir o offload de 0,70 para 0,80, e o tok/s foi de 48,7 para **61,8** — um
ganho de 27% que veio de *como gastar a memória liberada*, não da quantização em si. Em 8 GiB,
raciocine sempre assim: cada MiB economizado no KV é um MiB para trazer experts de volta à GPU.

**3. Descarte a primeira medição após o boot.** `[MEDIDO]` A primeira leitura do nosso coder
pós-boot deu 73,5 tok/s (−6,7%); remedições estáveis deram 78,0 / 78,7 / 79,9. Contenção de CPU
logo após o boot degrada o offload de MoE. **Já concluímos "regressão" em cima de cold-start
mais de uma vez.** Espere a carga assentar; melhor de 3.

**4. `--jinja` é obrigatório para tool-calling.** Sem ele o `llama-server` não aplica o chat
template do modelo, e agentes que dependem de function calling falham de formas confusas.
Está em todos os nossos três services.

**5. A fonte de verdade é o repositório, nunca o servidor.** Editar
`~/.config/systemd/user/*.service` direto na máquina cria divergência silenciosa — o próximo
deploy reverte, e ninguém lembra por quê. Edite no repo, faça deploy. Vale desde o primeiro dia,
não a partir do dia em que dói.

**6. Comentário mente, `ExecStart` não.** `[MEDIDO]` Nosso `llama-coder.service` tem um
`Description=` dizendo `n-cpu-moe=12` enquanto o `ExecStart=` real usa `--n-cpu-moe 16`
(sobrevivente de um sweep). Ao investigar um preset ativo, leia sempre a linha de comando real —
de preferência a do processo em execução, com `systemctl --user cat` ou `ps`.

**7. Deixar o modelo carregado é barato.** `[MEDIDO]` Modelo residente em idle custou
**+3,6 W** sobre a GPU dormente no nosso hardware — praticamente nada. Recarregar leva 20–60 s.
Não pare o serviço "para economizar energia" entre usos no mesmo dia; pare quando quiser a GPU
de volta para outra coisa. Metodologia em [`benchmarks/POWER.md`](../benchmarks/POWER.md) —
os valores em reais são da nossa tarifa e não servem para você, mas a conclusão qualitativa sim.

---

## 10. Arquitetura operacional

O que copiar do nosso setup, em ordem de valor:

**1. Um serviço systemd `--user` por preset, com `Conflicts=` cruzado.** Modelo em
[`systemd/llama-coder.service`](../systemd/llama-coder.service). O essencial:

```ini
[Unit]
Description=llama.cpp server - <preset>
Conflicts=llama-<outro>.service        # o init garante a exclusão mútua
After=network-online.target

[Service]
Type=simple
ExecStart=/caminho/llama-server -m /caminho/modelo.gguf --host 0.0.0.0 --port 1234 \
          -c 32768 -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t <sweep> --jinja
Restart=on-failure
TimeoutStartSec=120
```

**2. Todos os presets na mesma porta.** Usamos a `:1234` porque era a que o LM Studio ocupava —
assim nenhum cliente precisou mudar de URL na migração. Escolha a porta cedo e não mexa mais.

**3. Serviços *não* habilitados no boot.** Decisão consciente: a GPU é compartilhada com outras
tarefas, e boot limpo não deve carregar 5 GiB de pesos. Você invoca o preset quando precisa.

**4. Um wrapper com health probe.** [`bin/lmswitch`](../bin/lmswitch) — sobe o preset, faz
polling em `/health` até responder e devolve a URL. O detalhe que importa: ele **verifica se o
serviço morreu** durante a espera em vez de só esperar o timeout, e despeja as últimas linhas
do journal. Em 8 GiB, onde OOM na carga vai acontecer durante o tuning, esse diagnóstico
imediato vale muito.

```bash
# o núcleo do wait_ready, que é a parte reaproveitável
for _ in $(seq 1 90); do
  systemctl --user is-active --quiet "$svc" || { systemctl --user status "$svc" | tail -15; exit 1; }
  curl -fs -o /dev/null "http://localhost:1234/health" && { echo ready; exit 0; }
  sleep 1
done
```

**5. Watchdog térmico — só depois de calibrar.** [`bin/gpu-guard`](../bin/gpu-guard) corta o
serviço ativo sob temperatura crítica sustentada. `[MEDIDO]` A lição: nosso limite inicial
(78 °C) ficava perto demais do pico normal sob carga (77 °C) e gerava falso positivo. **Meça
seu pico real sob carga sustentada primeiro, depois defina o limite acima dele.** Uma RX 6600
tem envelope térmico bem diferente — não copie 82/86 °C.

---

## 11. Protocolo de benchmark

Sem isso, seus números não são comparáveis nem **entre si**, e todo o resto deste documento
perde o sentido. `[TRANSFERÍVEL]`

```
Prompt canônico:  "Explain quantum entanglement in exactly 5 paragraphs"
n_predict:        400
temperature:      0,2
Amostras:         melhor de 3, descartando a primeira após o boot
Uma variável por vez: modelo, flag, driver ou versão — nunca duas
```

Registre junto de cada número: **tok/s de geração, tok/s de prefill, VRAM usada, VRAM livre e
utilização de GPU**. Só o tok/s não permite diagnosticar nada depois.

`[MEDIDO]` Foi assim que separamos limpo o efeito de cada mudança nas nossas fases de upgrade:
llama.cpp 667 commits à frente rendeu ~0% no coder e +7% no TQ3; driver novo rendeu +5,7% e
+2,8% nos modelos com offload e **0%** no modelo 100% GPU — exatamente como previsto, porque
banda de VRAM é hardware fixo. Sem protocolo fixo, essas três conclusões seriam ruído.

**Defina um piso de regressão por preset** assim que tiver o número bom: usamos 70% do valor
medido. Abaixo disso, investigue em vez de aceitar. É o que transforma "parece mais lento hoje"
em um sinal acionável.

---

## 12. Ordem de execução sugerida

```
[ ]  1. Etapa 0 — reconhecimento; anotar VRAM livre com e sem desktop
[ ]  2. Verificar dual-channel + DOCP na BIOS         ← ganho mais barato do setup
[ ]  3. Fase 1 — Ollama/LM Studio, denso 7-8B, primeiro tok/s
[ ]  4. Fase 2 — medir utilização de GPU sob carga    ← decide se vale continuar
[ ]  5. Build Vulkan; llama-bench; opcionalmente build ROCm e comparar
[ ]  6. Teste FA + KV q4_0 (seção 7)                  ← decide o contexto viável
[ ]  7. Preset A (denso) como systemd service; benchmark canônico; piso de regressão
[ ]  8. Preset B (MoE) + sweep de --n-cpu-moe e de -t
[ ]  9. Wrapper lmswitch-like com health probe
[ ] 10. Ligar o cliente (opencode/aider/Claude Code) e validar tool-calling de ponta a ponta
```

Passos 4 e 6 são portões: o resultado deles muda o que vem depois. Não os pule por parecerem
burocracia — são as duas medições que evitam retrabalho grande.

---

## 13. O que deliberadamente não está aqui

- **Custo de energia.** Nossa tarifa e nossa GPU. A conclusão qualitativa da seção 9 item 7
  transfere; os reais por kWh, não.
- **Acesso remoto (Tailscale), dual-boot, Wake-on-LAN.** Ortogonais ao problema de inferência.
  Se interessarem, estão no [`README.md`](../README.md) do repositório.
- **Escolha nominal de modelos.** Este documento fala em categorias ("denso 7–8B Q4_K_M",
  "MoE ~30B-A3B") de propósito: os lançamentos giram rápido e um nome fixo envelhece mal.
  Aplique o cálculo da seção 2 ao candidato do momento — o método continua válido.
- **Fine-tuning, embeddings, RAG.** Fora de escopo.

---

## Referências neste repositório

| Arquivo | Conteúdo |
|---|---|
| [`benchmarks/TUNING.md`](../benchmarks/TUNING.md) | Todos os sweeps brutos: KV quant, `--n-cpu-moe`, ubatch, threads, upgrades |
| [`benchmarks/POWER.md`](../benchmarks/POWER.md) | Consumo por estado operacional e metodologia de medição |
| [`systemd/`](../systemd/) | Os três units reais, com `Conflicts=` |
| [`bin/lmswitch`](../bin/lmswitch) | Wrapper de troca de preset com health probe |
| [`bin/gpu-guard`](../bin/gpu-guard) | Watchdog térmico com histerese |
| [`scripts/build-llama.sh`](../scripts/build-llama.sh) | Build do `llama.cpp` (CUDA — trocar o backend) |
| [`MANUTENCAO.md`](../MANUTENCAO.md) | Arquitetura, fluxos e receitas de mudança |
