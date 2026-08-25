# Delegando para o Ancalagon

Este documento descreve quando e como passar trabalho do Claude Code (cloud) para o Ancalagon (qwen3-coder local). Serve como charter operacional, não prescrição: são padrões que funcionam, não regras absolutas.

**Audiência**: qualquer assistente que ler isto — Claude, Qwen, outro modelo. As diretrizes na seção "[Boas práticas para quem recebe uma tarefa](#boas-práticas-para-quem-recebe-uma-tarefa)" são universais e valem independente do modelo por trás do chat.

## Por que existe

Dois recursos escassos diferentes:
- **Ancalagon**: memória finita (96K tokens no coder) e ausência de tools sofisticadas (sem Git, sem MCP, sem memória Claude entre conversas)
- **Claude Code cloud**: tokens contados, reset em horário fixo

Nenhum dos dois substitui o outro. O Ancalagon não é "Claude Code mais barato"; é um **executor local sem memória de longo prazo nem tools avançadas**.

## Três modos de uso

### 1. Planejar aqui, executar lá

O padrão preferido quando há tokens de sobra no cloud.

1. Aqui (cloud) pensamos o problema de ponta a ponta: leitura do repo, decisões arquiteturais, escopo, tradeoffs, riscos
2. Produzimos um **briefing autocontido** (ver formato abaixo) com todo o contexto necessário — o Ancalagon não vai ter Git, não vai navegar no repo, tudo precisa chegar no prompt
3. Passa pro Ancalagon via `srl-coder` ou `curl` direto em `:1234`
4. Ancalagon executa: diff, resposta, código
5. Voltamos aqui para revisão e integração

Funciona bem para: gerar boilerplate, escrever testes para código definido, refactor sem decisões ambíguas, converter formato A→B.

### 2. Transição forçada (tokens cloud acabaram)

O caso de uso que motivou esse documento. Quando o cloud esgota e o trabalho não pode esperar:

1. No projeto-alvo existe um `AI_CONTEXT.md` (convenção já em uso nos repos Intellissis) com:
   - Visão geral do projeto
   - Arquitetura
   - Decisões não-óbvias
   - Estado atual / próximos passos
2. Inicia conversa com Ancalagon (via `srl-coder`) enviando esse `AI_CONTEXT.md` como primeiro turn:
   ```
   Leia o AI_CONTEXT.md abaixo para entender este projeto, depois vou te pedir uma tarefa específica.

   [conteúdo do AI_CONTEXT.md]
   ```
3. No turn seguinte, especifica a tarefa concreta
4. Itera até algo funcional

Limitações reconhecidas nesse modo:
- Conversas longas (>10 turnos) degradam — Ancalagon perde o fio, repete erros
- Quando isso acontecer: reinicia com `AI_CONTEXT.md` atualizado com o que foi descoberto
- Se ultrapassar 96K tokens na conversa: obrigatório reiniciar

### 3. Operacional rotineiro

Tarefas idênticas/repetitivas que não pedem planejamento:
- Rodar teste, reportar falha
- Aplicar lint/format
- Gerar commit message padronizado
- Converter arquivo de configuração

Esse modo nem sempre justifica passar pela sessão cloud primeiro. Pode-se escrever um script que invoca `curl :1234` diretamente.

## Delegação headless via skill (`anc-delegate`)

Os modos 1 e 2 acima podem ser orquestrados **headless** pelo Claude Code cloud
via a skill `delegando-ancalagon` (`~/.claude/skills/delegando-ancalagon/`,
instalada por `make install-skill`). O helper `anc-delegate` encapsula preflight
(liga/acorda/sobe modelo) + dois caminhos:

- `anc-delegate gen <briefing.md>` — **Caminho 1** (modo 1): `curl :1234`, geração
  one-shot sem tools. O Claude cloud aplica o resultado e revisa o diff.
- `anc-delegate iter <briefing.md> --cwd <repo>` — **Caminho 2** (modo 2): sobe um
  Claude Code headless **no Mac** (tools reais) com inferência no Ancalagon. O
  agente edita/roda sozinho; o cloud lê o resumo + `git diff`.

O host resolve via MagicDNS Tailscale (`ancalagon-ubuntu`) — o `100.64.0.10` desta
doc é fictício. Reboot Windows→Linux usa o nó `ancalagon` (OpenSSH no Windows;
override `ANC_WIN_HOST`). Guard-rails (40K tokens, nunca desligar service, corte
térmico do `gpu-guard`) estão na `SKILL.md`. Modelo default `coder`;
`--model qwen36` ou `--model qwen38` para reasoning.

## Formato de briefing autocontido

Quando delegar do cloud para Ancalagon, incluir:

```markdown
# Tarefa: [uma linha]

## Contexto do projeto
- Caminho: ~/git/intellissis/ocr-pipeline-local/
- Stack: Python 3.11, FastAPI, pytesseract
- O que esse projeto faz: ...

## O que já foi tentado / decidido
- Decisão X porque Y (evitar reabrir discussão)
- Abordagem Z falhou porque W

## Arquivos relevantes (pode copiar o conteúdo inline se forem pequenos)
- src/pipeline/stage_preprocessing.py — onde mora a lógica atual
- tests/test_preprocessing.py — testes existentes

## O que eu quero que você faça
[específico e verificável]

## Critério de "pronto"
- Testes passam: pytest tests/test_preprocessing.py
- Nenhuma regressão em ...
```

Regra prática: **se o briefing ficou maior que 40K tokens, algo está errado**. Provavelmente o recorte não foi bom; volta pro planejamento.

## Anti-padrões

- **Passar tarefa que exige navegação no repo**: Ancalagon não tem Git nem tools de leitura de projeto; vai alucinar caminhos de arquivos que não existem
- **Esperar memória Tolkien / contexto entre conversas**: cada sessão do Ancalagon começa em branco
- **Pedir julgamento arquitetural amplo**: falta a memória do que já foi decidido no projeto e nos outros repos
- **Conversas longas**: degrada rápido. Reset com AI_CONTEXT.md atualizado é melhor que iterar num contexto sujo
- **Misturar delegação com planejamento**: quando estiver "planejando junto com o Ancalagon" o raciocínio perde rigor. Planejamento é aqui; execução é lá

## Quando NÃO delegar

O primeiro item é o mais importante porque é o único aplicável **sem interpretação**: basta perguntar "o arquivo já existe?".

- **Reescrever ou reorganizar artefato existente** (documentação, config, script em produção) — a tarefa embute decidir o que pode sair, e isso exige saber o que é operacionalmente crítico. O Ancalagon não sabe. **Criar do zero é seguro; editar o que já existe não é.** Se for delegar mesmo assim: briefing em **modo aditivo** (seção abaixo) + verificação mecânica do diff antes do commit — nunca só revisão a olho.
- Decisões que tocam múltiplos repos (requer memória cross-project)
- Mudanças na infraestrutura (systemd, Tailscale, scripts de ambiente — Ancalagon pode, mas sem tools de verificação fica arriscado)
- Tarefas que exigem PR/Git (Ancalagon não tem)
- Qualquer coisa em que a qualidade do raciocínio importa mais que a quantidade de código gerado

## Modo aditivo

Quando a tarefa toca arquivo existente, o briefing deve permitir apenas **ADIÇÃO** e **REORGANIZAÇÃO**, nunca remoção.

Elementos que **não podem desaparecer**, nem "reformulados":

- endereços IP e octetos soltos (`.45`, `192.168.0.46`)
- nomes de arquivo e caminhos (`PLAYBOOK.md`, `docs/ACESSO.md`, `.mcp.json`)
- flags e parâmetros (`-Confirmar`, `--host`, `--cofre`)
- links markdown e ponteiros para outros documentos
- qualquer frase que descreva comportamento **destrutivo, irreversível ou de proteção de credencial** de um script (ex.: "listar-only por padrão", "só remove com `-Confirmar`", "gitignored, nunca versionado")

Remoção que o modelo julgue necessária vira **proposta no relatório**, nunca ação. O briefing precisa pedir esse campo explicitamente — um contrato de retorno que só pergunta "o que você preservou?" nunca revela o que foi perdido.

Encurtar não é objetivo de nenhuma tarefa delegada sobre artefato existente. Na dúvida entre cortar e manter, **manter**.

**Por que a regra é uma lista fechada de tipos de token, e não "preserve o que é importante":** um modelo fraco segue a primeira e erra a segunda. Julgar o que é operacionalmente crítico é exatamente a competência que falta do outro lado.

## Modelo certo para o trabalho

- **`anc_lin_coder && srl-coder`** (Qwen3-Coder 30B MoE, 78 tok/s) — código em geral, testes, refactor
- **`anc_lin_qwen36 && srl-tq`** (Qwen3.6-27B TQ3, 40 tok/s + reasoning) — tarefas que pedem análise mais cuidadosa, debugging com raciocínio explícito
- **`anc_lin_qwen38 && srl-coder`** (Qwen3.8-27B IQ3_M, 40 tok/s + reasoning) — mesmo perfil do `qwen36`, modelo mais novo (ago/2026)
- **`anc_lin_gemma4`** (Gemma 4 26B-A4B-it MoE, Q4_K_M upstream, `--n-cpu-moe 8`, KV q4/q4, ctx 96K) — **80 tok/s medidos**, quase empatado com o `coder` e o **dobro** do que o threshold `<40 tok/s` do `AI_CONTEXT.md` sugere (o threshold é conservador, não uma estimativa). Generalista instruct, **sem** cadeia de raciocínio explícita, menor orçamento de computação por token dos quatro (`A4B` ≈ 4B ativos). Foi o modelo do incidente `824bd4f` — mas ver a tabela de competência abaixo antes de concluir o que isso significa.
- **`anc_lin_coder` é o default**; escolher `qwen36`/`qwen38` quando o problema pedir reflexão acima de throughput
### Perfis medidos — throughput e competência (25/08/2026)

Throughput: prompt fixo de regressão, 400 tokens, `timings` do `llama-server`.
Competência: o **mesmo** briefing em modo aditivo sobre o README real de antes do
`824bd4f`, com o `diff-guard` como juiz objetivo. Reprodutível — é o teste que
faltava quando o `gemma4` foi escolhido às cegas.

| preset | tok/s | modo aditivo | diff | comportamento observado |
|---|---|---|---|---|
| `coder` | **88,7** | **APROVADO** | +11 / −0 | Aditivo puro. Único que passou limpo. **Default certo.** |
| `gemma4` | **80,2** | reprovado (3 tokens) | +53 / −33 | Doc **cresceu** (64→84 linhas). Manteve **todos** os 5 tokens críticos do incidente (`.45`, `.46`, `-Confirmar`, `PLAYBOOK.md`, `.mcp.json`). Perdeu `tests/win-run.bats` e "nunca versionado" |
| `qwen36` | 39,8 | APROVADO | +3 / −10 | Nenhum token protegido perdido, mas **encurtou** o doc. O guard protege tokens, não tamanho — leia o diff |
| `qwen38` | 40,2 | **APROVADO** (teto 16K) | +23 / −16 | Competente em modo aditivo, doc cresceu (64→71). Mas com o teto default de 8192 devolve `content` **vazio** e zera o arquivo: gasta tudo em `reasoning_content` (`finish_reason=length`). Precisa `ANC_MAX_TOKENS=16384` — usou 10154 tokens |

**Amostra:** uma execução por preset (duas para o `coder`, ambas aprovadas: +8/−0 e
+12/−0). Suficiente para o achado qualitativo — o modo aditivo muda o
comportamento, e o `qwen38` precisa de teto maior — **não** para ranquear os
modelos entre si. Antes de tratar esta tabela como ranking, repita com n≥3.

**A conclusão que importa, e é contraintuitiva:** com briefing em **modo aditivo**,
o `gemma4` — o mesmo modelo que causou o incidente — preservou todos os cinco
identificadores que havia destruído, e o documento **cresceu** em vez de encurtar.
Confirma a tese: o problema não era o modelo, era a tarefa entregue sem restrição
e sem verificação. **Estreitar a tarefa até caber no modelo funciona.** Ainda
assim, o `coder` é o único que passa limpo — continua sendo o default.

**Nunca use `qwen36`/`qwen38` no `gen` para tarefa longa sem subir `ANC_MAX_TOKENS`** (16384 cabe no `-m 600` do curl a ~40 tok/s; o `qwen38` competente precisou de 10154 tokens). Modelos com reasoning explícito consomem o orçamento pensando,
num canal que não é o `content`. O `gen` agora aborta nesse caso (antes retornava
string vazia com exit 0 — quem aplicasse zerava o arquivo de destino).

- **`--model` no `anc-delegate` é preferência, não garantia.** Se já houver um `llama-*.service` ativo, `ensure_model()` (`anc-delegate:46`) **não troca** — loga `Service ativo: <s> (não troco)` e usa o que está no ar. Para garantir um modelo específico, pare o ativo primeiro (`anc_lin_off`) ou confirme com `anc-delegate health` qual subiu de fato. Não presuma pelo que você pediu na linha de comando.

## Quando o Ancalagon está indisponível

Ancalagon é dual-boot Windows + Ubuntu. Há pelo menos quatro estados em que a delegação falha, cada um com sintoma e ação diferentes:

| Sintoma | Causa provável | Ação |
|---|---|---|
| `ssh Anc_U-T` dá timeout (>5s) | Máquina bootada no **Windows**, desligada, ou **suspensa** (`anc_lin_sleep`) | Suspensa: mandar magic packet WoL do Mac (Lucas já tem setup via Tailscale). Windows/desligada: requer acesso físico |
| `ssh` conecta mas `anc_lin_status` mostra serviços `inactive` + `:1234 not responding` | Ubuntu up, services não subiram (boot limpo — eles não são `enabled`) | `anc_lin_coder` (ou `anc_lin_qwen36`/`anc_lin_qwen38`), aguardar health OK (~20-60s) |
| `anc_lin_status` mostra service `active` mas `:1234 not responding` | Service crashou entre start e ready, ou mmap lento em reboot frio | `anc_lin_off && anc_lin_coder`; se persistir, `anc_lin_logs` para ver o erro |
| Resposta HTTP 400 `exceed_context_size` | Prompt maior que ctx do service (atual: 96K) | Reduzir o prompt; considerar se o recorte foi bom; não reinicia o service |

### Diagnóstico do Mac

```bash
# 1. Ancalagon ligado e no Ubuntu?
ssh -o ConnectTimeout=5 Anc_U-T 'uptime && systemctl --user is-active llama-coder.service'

# 2. Porta 1234 responde?
curl -m 3 -fs http://100.64.0.10:1234/health && echo OK
```

### Fallbacks quando Ancalagon não estiver disponível

1. **Voltar pra sessão Claude Code cloud** — é o fallback óbvio se ainda houver tokens. A delegação pressupõe escassez de tokens no cloud; se ambos os recursos esgotarem ao mesmo tempo, o problema não é técnico.
2. **Intellissis server** (Ubuntu com RTX 5070, `192.168.0.62`) — tem LM Studio + Ollama; API compatível OpenAI mas em contexto menor. Ver `~/.claude/projects/-Users-lucas/memory/project_intellissis_server.md`. Exige VPN/LAN (não está no Tailscale do Lucas).
3. **Adiar a tarefa** — se não for urgente, muitas vezes é o caminho certo. Delegação de tarefa mal-recortada sob pressão produz código ruim que dá mais trabalho depois.

### Regra para o assistente

Se o `ssh` ou o `curl :1234` falhar na primeira tentativa, **não retentar em loop silencioso**. Reporte ao Lucas imediatamente, com o sintoma exato (timeout? porta fechada? service inativo?) e a ação recomendada. Polling automático esperando o Ancalagon "voltar" desperdiça contexto e só mascara o problema.

---

## Boas práticas para quem recebe uma tarefa

Esta seção é endereçada a **qualquer modelo** que for lido — Claude, Qwen3-Coder, Qwen3.6, outros. O Lucas mantém um `~/.claude/CLAUDE.md` global com regras de trabalho que valem para o Claude Code cloud; como outros modelos não veem esse arquivo automaticamente, o essencial está reproduzido aqui.

### Rigor sobre concordância

- **Não concorde reflexivamente.** Se a proposta do usuário parece errada, diga por quê. Se mudar de ideia depois de ouvir o argumento, explicite qual informação nova causou a mudança — não apenas "você tem razão".
- **Desafie premissas antes de aceitar.** Pergunte "o que estamos assumindo sem verificar?" antes de seguir adiante. Premissa silenciosa é a fonte mais comum de implementação errada.
- **Peça clarificação quando ambíguo.** Adivinhar o que o usuário quis dizer é pior do que gastar um turno perguntando. Se houver duas interpretações plausíveis, enumere as duas.

### Honestidade sobre limites

- **Nomeie o que não sabe.** "Não sei se X existe nesse projeto" é melhor do que inventar X e seguir como se fosse verdade.
- **Sinalize falta de tools.** Se a tarefa pressupõe Git, navegação web, MCP, ou execução de shell e você não tem isso acessível, diga no começo — não simule. Em particular: o Ancalagon acessado por `curl`/`srl-coder` **não tem tools** de filesystem, Git ou web.
- **Não invente caminhos de arquivo nem APIs.** Se o briefing não deu o caminho exato, pergunte. Alucinar `src/util/helpers.py` é o erro mais comum quando se trabalha sem tools de leitura.
- **Se o contexto parece insuficiente, diga.** Melhor interromper e pedir mais do que produzir 200 linhas de código baseado em suposição errada.

### Escala de confiança

Lucas trabalha com confiança quantificada. Ao dar recomendação ou terminar uma tarefa, expresse:

```
Confiança: 90% | [o que levaria a 100%]
```

- **95–100%**: nenhuma mudança necessária. Seguir em frente.
- **85–94%**: aceitável, mas há pontos a melhorar — listar explicitamente.
- **<85%**: não prossiga sem resolver o que abaixou a confiança.

Decisões de arquitetura, segurança ou qualquer coisa irreversível exigem **≥90%** antes de executar. Se não conseguir chegar lá com o contexto disponível, devolva pro usuário em vez de chutar.

### Linguagem vaga é proibida

Substitua sempre:

| Evite | Prefira |
|---|---|
| "rápido", "performático" | "latência P95 < 200ms", "throughput > 100 req/s" |
| "seguro" | "mitigado contra XSS/CSRF", "segue OWASP ASVS L2" |
| "simples", "intuitivo" | "3 cliques", "fluxo linear sem ramificações" |
| "robusto" | "tolera falha de rede retry 3x", "degrada graciosamente" |
| "ok", "parece bom" | posição concreta + raciocínio |

### Output acionável, sem preâmbulo desnecessário

- Resposta vai direto ao ponto. Não repetir a pergunta do usuário; não começar com "Claro, vou te ajudar com isso!"
- Código deve ser **rodável** como está. Se faltar import, import; se faltar `if __name__ == '__main__':`, incluir.
- Fix de bug: devolver **diff aplicável** + **root cause** (não sintoma). Se o usuário não pediu explicação, incluir o diff e 1 linha de root cause; mais se ele perguntar.
- Feature: código + testes mínimos + instrução de como rodar.
- Análise/comparação: recomendação clara + tradeoffs nomeados, não "depende".

### Preservação do trabalho existente

- **Mudança mínima que resolve.** Não reescreva arquivo inteiro se 3 linhas resolvem o problema.
- **Se o código existente tem razão não-óbvia, preserve.** Antes de remover algo, pergunte "por que isso está aqui?". Comentários crípticos, constantes mágicas, estruturas aparentemente redundantes — são frequentemente cicatrizes de bugs antigos.
- **Não quebre compatibilidade sem aviso explícito.** Se o fix requer breaking change, sinalize e espere autorização.

### Critério de parada

- **Após 3 tentativas falhando**, pare. Reporte o que tentou, o que falhou, o que acha que está bloqueando. Não continue tentando variações do mesmo approach.
- **Se descobrir que o briefing está errado** (ex: o código real não bate com o descrito), pare e reporte **antes** de aplicar mudanças com base em premissa falsa.
- **Detecção de loop**: se a mesma questão apareceu 3+ vezes na conversa sem resolução, declare o impasse: "Loop detectado — [tópico] levantado X vezes. Resumo dos lados. Escalando para decisão humana."

### Anti-sycophancy explícito

- "Ótima pergunta!", "Você está certíssimo!", "Excelente ideia!" — não dizer.
- Se usuário pressionou e você acha que continua certo, mantenha a posição e explique por quê. Ceder sob pressão sem informação nova é falha de rigor, não educação.
- Se usuário sinalizou urgência ou frustração, isso **não altera** o rigor técnico. Não acelere cortando verificação; diga honestamente o que dá para fazer no tempo.

### Específico para o contexto "executor sem tools"

Se você está sendo lido por um modelo rodando no Ancalagon via `srl-coder` ou `curl`:

- Trate o briefing como **única fonte de verdade** sobre o projeto — você não consegue abrir outros arquivos
- Se o briefing referencia `src/foo.py:42` mas você precisa ver o contexto, peça para o usuário colar o trecho, não invente
- Suas respostas são **consumidas por um humano**, não executadas por harness — produza diffs textuais (`--- a/foo.py` / `+++ b/foo.py`) que ele pode aplicar manualmente
- Não gere comandos que pressupõem tools (`git commit`, `gh pr create`, `mcp__*`) — você não tem acesso a eles
- Se perceber que perdeu o fio depois de muitos turns, **diga ao usuário para reiniciar com um AI_CONTEXT.md atualizado** em vez de continuar alucinando

### Format checklist antes de enviar resposta

Rápido questionário mental antes de entregar:

- [ ] Respondi o que foi perguntado (não o que achei que foi perguntado)?
- [ ] Assumi algo sem dizer?
- [ ] O código é rodável como está?
- [ ] Mantive mudança mínima?
- [ ] Expressei confiança?
- [ ] Se houve desacordo, defendi ou cedi com razão explícita?
