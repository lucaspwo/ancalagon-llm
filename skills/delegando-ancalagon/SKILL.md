---
name: delegando-ancalagon
description: Use quando quiser terceirizar trabalho de código ao Ancalagon (LLM local) para economizar tokens do Claude Code cloud — gerar boilerplate/testes/conversões (Caminho 1) ou tarefas que precisam rodar e iterar com tools como "faça os testes passarem" (Caminho 2). Headless, o Claude orquestra de ponta a ponta.
---

# Delegando para o Ancalagon (headless)

Terceiriza trabalho ao Ancalagon (RTX 4070 Ti SUPER, llama.cpp na :1234) para
poupar os output tokens caros do cloud. Charter completo em
`~/git/apps_mac/ancalagon-llm/docs/delegation.md`.

Helper: `~/.claude/skills/delegando-ancalagon/anc-delegate` (instalado por
`make install-skill`). O host resolve via MagicDNS Tailscale (`ancalagon-ubuntu`).
Para o reboot Windows→Linux, o nó Windows é `ancalagon` (override: `ANC_WIN_HOST`).

## Quando NÃO delegar

Decisões arquiteturais, cross-repo, PRs, julgamento — ficam no cloud. O Ancalagon
é executor, não arquiteto. Ver "Quando NÃO delegar" em delegation.md.

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

  **Ressalva:** só ganha se o qwen3-coder for competente para a tarefa sem
  supervisão — ganho de token não compra competência. Se o modelo local
  provavelmente erraria, faça no cloud ou aceite revisar o resultado.

Cada chamada imprime no stderr um one-liner `[anc] ...` com a **economia bruta**
(tokens do lado Ancalagon). É teto, não líquido: não inclui seu custo de cloud de
escrever o briefing nem de revisar. Some-os ao decidir se valeu.

## Procedimento

1. Monte um **briefing autocontido** (formato em delegation.md: contexto do
   projeto, decisões já tomadas, arquivos relevantes inline, critério de pronto).
   Salve em arquivo temporário (ex.: `/tmp/brief.md`).
2. Caminho 1: `anc-delegate gen /tmp/brief.md` → recebe o texto no stdout → você
   aplica via Edit/Write → mostre o diff ao Lucas.
   Caminho 2: `anc-delegate iter /tmp/brief.md --cwd <repo>` → o agente edita os
   arquivos → você roda `git diff` no repo e revisa.
3. O `anc-delegate` faz o **preflight** sozinho (liga/acorda/sobe o modelo). Se ele
   retornar erro de indisponibilidade, **reporte ao Lucas na hora** com o sintoma
   exato — não retente em loop (regra de delegation.md).

## Guard-rails

- Briefing > 40K tokens = recorte ruim. Pare e re-planeje (o `gen` também aborta).
- **Nunca desligue o service depois** — deixe para o Lucas via `lloff`/`make off`.
- Modelo: default `coder`. Use `--model qwen36` para tarefas que pedem reasoning
  explícito (mais lento, 37 tok/s, mas com cadeia de raciocínio).
- Se o `anc-delegate` reportar que a `:1234` caiu durante o trabalho, pode ser
  corte térmico do `gpu-guard` (watchdog parou o service por temperatura
  sustentada). Pare e reporte — não retente.
- O Ancalagon não tem Git, MCP, nem memória entre conversas. Tudo que ele precisa
  saber vai no briefing. Ver anti-padrões em delegation.md.
