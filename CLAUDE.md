# CLAUDE.md — ancalagon-llm

Provisionamento operacional do Ancalagon (Ubuntu Server, RTX 4070 Ti SUPER) como servidor LLM local via `llama.cpp` + systemd, consumido do Mac via Tailscale na `:1234`.

## Comandos essenciais

```bash
make status               # estado dos 5 services + health probe :1234
make coder|qwen36|qwen38|gemma4|flint|colibri  # sobe o preset (para os outros automaticamente via Conflicts=)
make off                  # para o preset ativo
make sleep                # para + suspende a máquina (wake via WoL: make wake)
make logs                 # journalctl -f do service ativo
make install               # deploy de units + wrappers (scp + daemon-reload) no Ancalagon
make install-system        # pré-requisitos de sistema (WoL, nvidia-suspend, console-font, usb-port-guard) — 1x por máquina
```

Não há build nem suíte de testes automatizada neste repo (ver [MANUTENCAO.md](MANUTENCAO.md) § Build/Test/Lint/Deploy). Validação de mudança é `make status` + benchmark manual contra os thresholds de regressão em [`AI_CONTEXT.md`](AI_CONTEXT.md) § "Como testar uma mudança" (coder <55 tok/s, qwen36 <25 tok/s, qwen38 <25 tok/s, gemma4 <40 tok/s, flint <60 tok/s, colibri <19 tok/s).

## Gotchas (top 5)

1. **KV cache assimétrico (K≠V) quebra o Qwen3.6-27B** — cai para ~1 tok/s (fallback CUDA catastrófico, testado e reproduzido). `llama-qwen36.service` usa `q8_0` simétrico nos dois lados; nunca mudar só um.
2. **Aliases SSH do Mac exigem caminho absoluto** (`/home/lucas/.local/bin/lmswitch`, não `lmswitch` via PATH) — sessão SSH não-interativa não carrega o `$PATH` do shell interativo.
3. **Services `llama-*` e `colibri-qwen36` NÃO são `enabled`** (decisão consciente — VRAM compartilhada com tarefas eventuais). `gpu-guard.service` é a exceção: **é** `enabled`, roda sempre que a máquina está de pé.
4. **Fonte de verdade é este repo, não o Ancalagon** — nunca editar `~/.config/systemd/user/*.service` ou `~/.local/bin/lmswitch` direto no remoto; editar aqui e `make install`.
5. **Ao encerrar um sweep de tuning, corrija as citações da flag no mesmo commit** — `Description=`, tabelas de `AI_CONTEXT.md`/`AGENTS.md` e os "config atual" de `benchmarks/` envelhecem juntos e em silêncio. Ao investigar um preset, a fonte de verdade é sempre o `ExecStart=` (ou `systemctl --user cat`), nunca a prosa.
6. **O Colibri exige `COLI_ALLOW_INSECURE_BIND=1`** para bindar `0.0.0.0` — sem isso o processo recusa iniciar e sobe/morre em loop (`Restart=on-failure`). Decisão consciente de paridade com os `llama-*.service`, que também não autenticam (rede confiável = Tailscale/LAN). Além disso, o host guard dele responde **403** a qualquer `Host` fora de `COLI_ALLOWED_HOSTS`: quem acessar por outro nome/IP precisa entrar na lista. E ele **não serve para o opencode** (sem tool calling nativo, contexto de 8K, prefill ~36 tok/s): ver `benchmarks/TUNING.md` §17.
7. **O Colibri não fica pronto sem `--auto-tier --cap 256`** — sem `--cap 256` (= `n_experts`), o tier CUDA fica `disabled` e o preset roda 100% CPU (~0,6 tok/s em vez de ~27 tok/s). O sintoma no log é `[qtier] cap=8 != n_experts=256 -> tier disabled`.

## Ponteiros

- Arquitetura, mapa de módulos, fluxos de dados e receitas de mudança → [MANUTENCAO.md](MANUTENCAO.md)
- Mapa de símbolos (`arquivo:linha`) e comandos exatos para agentes → [AGENTS.md](AGENTS.md)
- Bootstrap enxuto de 1 página para sessão nova (PT-BR, convenção Intellissis) → [AI_CONTEXT.md](AI_CONTEXT.md)
- Charter de delegação cloud↔Ancalagon (quando/como usar `anc-delegate`) → [docs/delegation.md](docs/delegation.md)
- Dados empíricos por trás das flags de tuning atuais → [benchmarks/TUNING.md](benchmarks/TUNING.md)
- Diagnóstico da USB port11 morta (erro `-71` em loop) e como caçar o culpado → [docs/usb-port11.md](docs/usb-port11.md)

## Memórias relacionadas

- `~/.claude/projects/-Users-lucas/memory/project_ancalagon_ubuntu.md` — setup completo do Ancalagon (hardware, drivers, modelos, MOK, Tailscale, rede)
- `~/.claude/projects/-Users-lucas/memory/reference_ancalagon_llm_repo.md` — ponteiro para este repo

## O que NÃO está aqui

- Compilação do `llama.cpp` / fork TQ3 e download de modelos GGUF (manual no Ancalagon)
- Configuração do Tailscale
- `~/git/local-claude/` — fonte do `local-claude` (backends `remote`, `remote-llama`, `llama`, `lmstudio`, `apfel`), repo separado
- Aliases do Mac `.zshrc` (vivem em `~/.zshrc` do Glaurung — adicionados manualmente, documentados aqui e no README, não sincronizados por este repo)

## Manutenção destes docs

Se sua mudança invalidar algo citado aqui ou nos docs irmãos — um comando, um
símbolo, uma referência `arquivo:linha`, a estrutura de pastas — corrija a
referência **no mesmo commit**. Não reescreva proativamente o que ainda está
correto. Para um refresh completo, use a skill `/atualizando-docs-manutencao`
(ela verifica cada ref com `git grep`).

## Commit/push

O remote `origin` aponta **só para o GitLab do homelab** (fetch e push):

```
origin  ssh://git@gitlab.lab.lucaspwo.com:2222/lucaspwo/ancalagon-llm.git (fetch)
origin  ssh://git@gitlab.lab.lucaspwo.com:2222/lucaspwo/ancalagon-llm.git (push)
```

**O GitHub (`lucaspwo/ancalagon-llm`) está congelado de propósito em `2c8c099`** — os commits
seguintes são mais "privados" e não devem ir para lá. Nunca readicionar a `pushurl` do GitHub nem
fazer push direto para ele sem pedido explícito.

Se o GitLab estiver inacessível (fora da rede/Tailscale ou homelab offline), o `git push` **trava**
(não há outro destino): interrompa e repita quando o homelab voltar — os commits ficam só locais até lá. Nunca usar `--no-verify` para pular hooks.
