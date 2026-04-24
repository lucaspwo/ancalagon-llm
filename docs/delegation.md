# Delegando para o Ancalagon

Este documento descreve quando e como passar trabalho do Claude Code (cloud) para o Ancalagon (qwen3-coder local). Serve como charter operacional, não prescrição: são padrões que funcionam, não regras absolutas.

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

- Decisões que tocam múltiplos repos (requer memória cross-project)
- Mudanças na infraestrutura (systemd, Tailscale, scripts de ambiente — Ancalagon pode, mas sem tools de verificação fica arriscado)
- Tarefas que exigem PR/Git (Ancalagon não tem)
- Qualquer coisa em que a qualidade do raciocínio importa mais que a quantidade de código gerado

## Modelo certo para o trabalho

- **`llcoder && srl-coder`** (Qwen3-Coder 30B MoE, 78 tok/s) — código em geral, testes, refactor
- **`llq36 && srl-tq`** (Qwen3.6-27B TQ3, 37 tok/s + reasoning) — tarefas que pedem análise mais cuidadosa, debugging com raciocínio explícito
- **`llcoder` é o default**; escolher `llq36` quando o problema pedir reflexão acima de throughput
