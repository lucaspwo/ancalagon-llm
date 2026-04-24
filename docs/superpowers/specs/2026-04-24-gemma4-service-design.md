# Gemma 4 service — design

**Data:** 2026-04-24
**Status:** aprovado, pendente implementação

## Contexto

Repo `ancalagon-llm` gerencia dois presets systemd mutuamente exclusivos (`llama-coder`, `llama-qwen36`) na porta 1234, coordenados pelo wrapper `lmswitch`. Adicionar terceiro preset para o modelo Gemma 4 26B-A4B-it (MoE multimodal-capable, Q4_K_M, 16 GB em disco), já presente em `/home/lucas/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-GGUF/`.

## Papel do service

**Alternativa ao `llama-coder` para Claude Code** — prioriza contexto agressivo (96K), KV cache quantizado para economizar VRAM, offload parcial de experts MoE para CPU. Coexiste com os dois services atuais como terceiro preset mutuamente exclusivo. Objetivo: comparar tok/s e qualidade lado-a-lado com Qwen3-Coder-30B-A3B no mesmo caso de uso.

Visão (mmproj) **fora de escopo** — se necessário no futuro, vira service separado para não pagar VRAM de visão em uso puro de código.

## Arquivos

### Novos

#### `systemd/llama-gemma4.service`
Unit systemd `--user`, porta 1234, conflita com os outros dois llama-services e com `lmstudio.service`.

Config inicial (espelha a do `llama-coder` como ponto de partida empírico):

```
ExecStart=/home/lucas/git/llama.cpp/build/bin/llama-server \
  -m /home/lucas/.lmstudio/models/lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf \
  --host 0.0.0.0 --port 1234 \
  -c 98304 -ngl 99 -fa 1 \
  -ctk q4_0 -ctv q4_0 \
  -t 12 --n-cpu-moe 16 \
  --jinja
```

Demais diretivas (`Restart`, `KillMode`, `TimeoutStartSec`, `After/Wants=network-online.target`, `WorkingDirectory`, `Environment=PATH`) idênticas aos outros services.

### Modificados

#### `systemd/llama-coder.service`
Acrescentar `llama-gemma4.service` em `Conflicts=`.

#### `systemd/llama-qwen36.service`
Acrescentar `llama-gemma4.service` em `Conflicts=`.

#### `bin/lmswitch`
- Usage atualizado: `{coder|qwen36|gemma4|off|sleep|status|logs}`
- Novo case `gemma4)` que para os outros dois services e sobe `llama-gemma4.service`
- Cases `coder)` e `qwen36)` passam a parar `llama-gemma4.service` também
- Cases `off|stop)` e `sleep|suspend)` param os três services
- Loop de `status` inclui `llama-gemma4`
- Loop de `logs` inclui `llama-gemma4`

#### `Makefile`
Novo target `gemma4:` invocando `ssh $(REMOTE) /home/lucas/.local/bin/lmswitch gemma4`. Acrescentar em `.PHONY`.

#### Documentação
- `README.md`: adicionar linha no diagrama ASCII, atualizar seção de uso
- `CLAUDE.md`: atualizar diagrama, listagens de services, aliases (Mac), e tabela de performance de referência (valor medido após benchmark)
- `AI_CONTEXT.md`: acrescentar `gemma4` às opções mencionadas
- `benchmarks/TUNING.md`: entrada nova com dados medidos após primeiro run

## Tuning — método

26B-A4B é **menor que 30B-A3B em params totais** (mais VRAM livre para KV/compute) mas **4B ativos em vez de 3B** (mais compute por token no forward pass). Não é previsível se fica mais rápido ou mais lento que o coder sem medir.

**Estratégia:**
1. Subir com config idêntica à do coder (ncmoe=16, ctx=96K, KV q4_0)
2. Medir: tok/s de geração, prefill (pp) tok/s, VRAM usada, VRAM livre
3. Ajustar ncmoe conforme resultado:
   - VRAM livre > 1.5 GiB → baixar ncmoe (tentar 12, depois 8) para ganhar tok/s
   - Compute buffer estourar (OOM) → subir ncmoe (tentar 20)
4. Validar a regra "cada bump de ctx exige bump proporcional de ncmoe" documentada no `CLAUDE.md`

## KV quantization

`ctk=q4_0 ctv=q4_0` — simétrico. Justificativa no `CLAUDE.md`: no coder (MoE quase todo na GPU), K=V=q4 funciona e economiza VRAM. Assimetria K≠V causa fallback CUDA e é proibida.

Se depois de medir houver fallback catastrófico igual ao que o qwen36 teve com q4 (cair para 1 tok/s), voltar para q8_0. Mas a expectativa é que funcione — perfil de offload é MoE, igual ao coder.

## Threshold de regressão

A definir depois do benchmark inicial — regra usual do repo é `tok/s_medido * 0.7` como piso mínimo aceitável. Entrará em `CLAUDE.md` junto com a linha da tabela.

## Fora de escopo

- Carregamento de `mmproj-*-BF16.gguf` (visão multimodal) — service separado se vier demanda
- Aliases `.zshrc` do Mac (`llgemma4`) — vivem fora do repo, documentar mas não deployar
- Compilação/download — Gemma 4 já está em disco, llama.cpp upstream já compilado
- Comparação automatizada coder vs gemma4 — benchmark manual, resultados documentados em `benchmarks/TUNING.md`

## Riscos e mitigações

| Risco | Probabilidade | Mitigação |
|---|---|---|
| KV q4 causa fallback CUDA (como no qwen36) | Baixa (perfil MoE similar ao coder) | Medir na primeira subida; fallback para q8_0 se detectar |
| ncmoe=16 não cabe com ctx=96K (arquitetura diferente do Qwen) | Média | Service falha no boot; subir ncmoe até caber |
| Tok/s < 55 no primeiro run | Média | Tuning iterativo de ncmoe; se mesmo com tuning ficar abaixo, abrir questão de qualidade vs throughput |
| Jinja template do Gemma 4 incompatível com `--jinja` do llama-server upstream | Baixa | Logs do journalctl vão apontar; última opção é remover `--jinja` |

## Critérios de aceitação

- `make install` deploya o novo unit sem erro
- `make gemma4` sobe o service e `:1234/health` responde 200
- `make coder` ou `make qwen36` param gemma4 e sobem o service pedido (Conflicts= funciona)
- `lmswitch status` mostra os 3 services + lmstudio
- `lmswitch logs` segue o journal do gemma4 quando ele é o ativo
- Tok/s geração medido e anotado em `benchmarks/TUNING.md` + tabela do `CLAUDE.md`
- README + CLAUDE.md + AI_CONTEXT.md refletem a existência do terceiro preset
