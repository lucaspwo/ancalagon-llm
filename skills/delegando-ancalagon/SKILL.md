---
name: delegando-ancalagon
description: Use quando quiser terceirizar trabalho de código ao Ancalagon (LLM local) — gerar boilerplate/testes/conversões (Caminho 1) ou tarefas que precisam rodar e iterar com tools como "faça os testes passarem" (Caminho 2). Não use para reescrever documentação, config ou script que já existe. Headless, o Claude orquestra de ponta a ponta.
---

# Delegando para o Ancalagon (headless)

Terceiriza trabalho ao Ancalagon (RTX 4070 Ti SUPER, llama.cpp na :1234).
Charter completo em `~/git/apps_mac/ancalagon-llm/docs/delegation.md`.

**A decisão tem dois passos, nesta ordem — e o primeiro é o filtro:**

1. **O modelo local dá conta desta tarefa sem supervisão?** Se não, para aqui:
   faça no cloud. **Ganho de token não compra competência.**
2. Só então: qual caminho economiza mais (`gen` vs `iter`)?

Delegue **por capacidade, não por custo**. A economia de token é o motivo de
existir da skill, não critério de elegibilidade — uma tarefa que o Ancalagon
executa mal custa mais caro em retrabalho do que os tokens que poupou.

Helper: `~/.claude/skills/delegando-ancalagon/anc-delegate` (instalado por
`make install-skill`). O host resolve via MagicDNS Tailscale (`ancalagon-ubuntu`).
Para o reboot Windows→Linux, o nó Windows é `ancalagon` (override: `ANC_WIN_HOST`).

## Quando NÃO delegar

**Regra estrutural, aplicável sem interpretação — pergunte "o arquivo já existe?":**

- **Criar do zero é seguro. Reescrever ou reorganizar artefato existente não é.**
  Documentação, config, script em produção — a tarefa embute decidir o que pode
  sair, e isso exige saber o que é operacionalmente crítico. O Ancalagon não sabe.
  Se delegar mesmo assim: briefing em **modo aditivo** + `diff-guard` antes do
  commit (ver Guard-rails). Ver "Modo aditivo" em delegation.md.

Os critérios semânticos continuam valendo (decisões arquiteturais, cross-repo,
PRs, julgamento — ficam no cloud; o Ancalagon é executor, não arquiteto), mas
**não substituem o estrutural**: "atualizar os docs de manutenção" não parece
julgamento, parece formatação — e foi assim que uma delegação degradou a
documentação do `intellissis-infra` (commit `824bd4f`). Decidir o que, numa doc
operacional, pode ser descartado **é** julgamento.

## Escolha do caminho

A economia depende mais de **qual caminho** que de como briefar. Detalhes e o caso
que motivou esta regra: memória `feedback_anc_caminho1_economia_tokens`.

- **Caminho 1 (`gen`)** — usar **somente** quando os três valem:
  1. **Output ≫ spec** — boilerplate/expansão mecânica (ex.: N fixtures de um
     schema pequeno). Se especificar é quase tão caro quanto escrever, não delega.
  2. **Revisão leve** — baixo risco de bug, output verificável de relance.
  3. **Pouca referência embutida** — o briefing não precisa carregar trechos
     grandes de outros arquivos (o Ancalagon não os lê).

  **Aplicação (preserva a economia):** `cp` da saída crua para o destino + `Edit`
  cirúrgico nos ajustes. **Nunca** re-Write o arquivo inteiro no cloud — re-emitir
  o conteúdo gerado joga fora a economia da geração.

- **Caminho 2 (`iter`)** — default para qualquer coisa com **muita referência**
  (o agente headless lê os arquivos — o briefing vira tarefa + ponteiros, não
  conteúdo copiado), **testável** (o agente roda os testes e te entrega verde +
  `git diff`), ou **sutil**. O custo de cloud desacopla do tamanho da tarefa:
  briefing curto + resumo curto; o trabalho pesado roda local na GPU.

  **Lembrete:** o filtro de competência do topo desta skill vale aqui também —
  o Caminho 2 desacopla o custo do tamanho da tarefa, não da dificuldade dela.

Cada chamada imprime no stderr um one-liner `[anc] ...` com a **economia bruta**
(tokens do lado Ancalagon). É teto, não líquido: não inclui seu custo de cloud de
escrever o briefing nem de revisar. Some-os ao decidir se valeu.

## Procedimento

1. Monte um **briefing autocontido** (formato em delegation.md: contexto do
   projeto, decisões já tomadas, arquivos relevantes inline, critério de pronto).
   Salve em arquivo temporário (ex.: `/tmp/brief.md`).
   **Se a tarefa toca arquivo existente**, o briefing vai em **modo aditivo** — a
   lista fechada de tokens que não podem desaparecer está em delegation.md, e o
   briefing precisa pedir um campo **"Remoções propostas"** no relatório. Um
   contrato que só pergunta "o que você preservou?" nunca revela o que foi perdido.
2. Caminho 1: `anc-delegate gen /tmp/brief.md` → recebe o texto no stdout → você
   aplica via Edit/Write → mostre o diff ao Lucas.
   Caminho 2: `anc-delegate iter /tmp/brief.md --cwd <repo>` → o agente edita os
   arquivos → você roda `git diff` no repo e revisa.
3. O `anc-delegate` faz o **preflight** sozinho (liga/acorda/sobe o modelo). Se ele
   retornar erro de indisponibilidade, **reporte ao Lucas na hora** com o sintoma
   exato — não retente em loop (regra de delegation.md).
4. **Se a tarefa tocou arquivo existente:** rode o `diff-guard` antes de qualquer
   commit (ver Guard-rails). Revisão a olho não é verificação.

Outros subcomandos do helper: `anc-delegate health` (JSON com service ativo, saúde
da `:1234`, temperatura e throttle da GPU — não acorda a máquina) e
`anc-delegate preflight [--model M]` (só a escada SSH/WoL/reboot, sem enviar
trabalho). Use o `health` para confirmar **qual modelo está de fato no ar**.

## Guard-rails

- **Tocou arquivo existente? Rode o `diff-guard` antes de commitar.** Ele compara,
  por arquivo, os tokens de classes protegidas (IPs/octetos, nomes de arquivo,
  caminhos, flags, links, código inline, vocabulário de segurança) antes e depois,
  e falha se algum desapareceu. `git diff` lido a olho **não** substitui isto — foi
  exatamente o que deixou passar os seis defeitos do `824bd4f`.

  ```bash
  ~/.claude/skills/atualizando-docs-manutencao/diff-guard.sh --repo <repo>
  ```

  Reprovou? Restaure o que sumiu. Se a remoção era intencional, `--forcar` libera
  registrando o que foi liberado. **Nunca contorne o guard editando/desativando
  ele.** Quem verifica não pode ser quem errou: o guard roda no Mac, no Claude
  Code, nunca no modelo local.
- Briefing > 40K tokens = recorte ruim. Pare e re-planeje (o `gen` também aborta).
- **Nunca desligue o service depois** — deixe para o Lucas via `anc_lin_off`/`make off`.
- Modelo: default `coder`. Use `--model qwen36` ou `--model qwen38` para tarefas que
  pedem reasoning explícito (mais lentos, ~40 tok/s, mas com cadeia de raciocínio).
  Entre os dois, `qwen38` é o modelo mais novo (ago/2026) com throughput equivalente.
- `--model gemma4` existe no helper, mas **seu perfil de competência não está
  caracterizado** — é o preset com menor computação por token (`A4B` ≈ 4B ativos),
  generalista (não de código) e sem raciocínio explícito. Não é hoje a escolha
  recomendada para nada; o único uso registrado em tarefa real produziu o `824bd4f`.
  Ver "Modelo certo para o trabalho" em delegation.md antes de escolher.
- **`--model` é preferência, não garantia.** Se já houver `llama-*.service` ativo,
  o helper **não troca** (`ensure_model()`, `anc-delegate:46`, loga `Service ativo:
  <s> (não troco)`). Confirme com `anc-delegate health` qual modelo está realmente
  no ar — não presuma pelo que você pediu na linha de comando.
- Se o `anc-delegate` reportar que a `:1234` caiu durante o trabalho, pode ser
  corte térmico do `gpu-guard` (watchdog parou o service por temperatura
  sustentada). Pare e reporte — não retente.
- O Ancalagon não tem Git, MCP, nem memória entre conversas. Tudo que ele precisa
  saber vai no briefing. Ver anti-padrões em delegation.md.
