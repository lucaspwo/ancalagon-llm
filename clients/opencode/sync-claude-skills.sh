#!/bin/bash
# sync-claude-skills.sh — deixa no opencode as mesmas skills que o Claude Code enxerga. Idempotente.
#
# O que o opencode JÁ lê sozinho: ~/.claude/skills/*/SKILL.md e ~/.agents/skills/*/SKILL.md.
# O que falta, e este script liga (só symlinks; não edita o opencode.json):
#   1. Skills de plugins habilitados no Claude Code (~/.claude/settings.json → enabledPlugins; caminho em
#      ~/.claude/plugins/installed_plugins.json). Esse caminho muda a cada versão, então:
#        ~/.config/opencode/claude-plugins/<plugin>  → installPath atual (refeito a cada execução)
#        ~/.config/opencode/skills/<skill>           → claude-plugins/<plugin>/skills/<skill> (estável)
#      Vale também para o superpowers. O plugin nativo dele para o opencode ("plugins": [<dir local>])
#      TRAVOU o `opencode run` no 2.2.5 em 3 tentativas (2026-11-04); daí só as skills, sem o bootstrap
#      automático do using-superpowers (ver clients/opencode/README.md para religá-lo via "instructions").
#   2. Skills com `disable-model-invocation: true` (só o usuário invoca, ex.: /create-prd): o opencode
#      as ignora como skill; viram commands em ~/.config/opencode/commands/<nome>.md (symlink pro SKILL.md).
#   3. Symlinks quebrados em ~/.claude/skills: só reporta (estão quebrados no Claude Code também).
#
# Rodar de novo depois de atualizar/instalar plugins no Claude Code, e então `opencode service stop` (o
# `opencode run` usa um serviço em background com a config de quando subiu; o próximo comando o sobe de novo).
# NÃO use `opencode service restart`: em 2026-11-04 o serviço reiniciado assim travava todo `run`.
# `--dry-run` só mostra.
# Não cobre as skills embutidas no binário do Claude Code (code-review, simplify, init...): não são arquivos.
set -euo pipefail

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
CLAUDE=${CLAUDE_HOME:-$HOME/.claude}
OC=${OPENCODE_HOME:-$HOME/.config/opencode}
run() { if [ "$DRY" = 1 ]; then echo "  (dry-run) $*"; else "$@"; fi; }

# Cria/atualiza um symlink nosso. Nunca sobrescreve arquivo/diretório real nem symlink de terceiros.
link() {
  local target=$1 dest=$2
  if [ -L "$dest" ]; then
    [ "$(readlink "$dest")" = "$target" ] && return 0
    case "$(readlink "$dest")" in
      "$CLAUDE"/*|"$OC"/claude-plugins/*) run ln -sfn "$target" "$dest"; echo "  atualizado: $dest" ;;
      *) echo "  PULADO (symlink de outra origem): $dest -> $(readlink "$dest")" ;;
    esac
  elif [ -e "$dest" ]; then
    echo "  PULADO (já existe e não é symlink): $dest"
  else
    run ln -s "$target" "$dest"; [ "$DRY" = 1 ] || echo "  criado: $dest -> $target"
  fi
}

run mkdir -p "$OC/claude-plugins" "$OC/skills" "$OC/commands"

echo "→ Skills dos plugins habilitados no Claude Code"
while IFS=$'\t' read -r name path; do
  [ -d "$path" ] || { echo "  $name: installPath não existe ($path)"; continue; }
  stable="$OC/claude-plugins/$name"
  n=0
  for skill in "$path"/skills/*/; do
    [ -f "$skill/SKILL.md" ] || continue
    [ "$n" = 0 ] && link "$path" "$stable"
    link "$stable/skills/$(basename "$skill")" "$OC/skills/$(basename "$skill")"; n=$((n+1))
  done
  echo "  $name: $n skill(s)"
done < <(python3 - "$CLAUDE" <<'EOF'
import json, sys, os
c = sys.argv[1]
enabled = json.load(open(os.path.join(c, "settings.json"))).get("enabledPlugins", {})
inst = json.load(open(os.path.join(c, "plugins", "installed_plugins.json")))
inst = inst.get("plugins", inst)
for key, on in enabled.items():
    if not on or key not in inst:
        continue
    entries = inst[key] if isinstance(inst[key], list) else [inst[key]]
    print(f"{key.split('@')[0]}\t{entries[-1].get('installPath', '')}")
EOF
)

echo "→ Skills só-do-usuário (disable-model-invocation) → commands"
for f in "$CLAUDE"/skills/*/SKILL.md; do
  grep -qE '^disable-model-invocation:[[:space:]]*true' "$f" || continue
  link "$f" "$OC/commands/$(basename "$(dirname "$f")").md"
done

echo "→ Symlinks quebrados em $CLAUDE/skills (corrigir à mão)"
broken=0
for s in "$CLAUDE"/skills/*; do
  [ -f "$s/SKILL.md" ] && continue
  [ -L "$s" ] || [ -d "$s" ] || continue
  # diretório que agrupa skills (ex.: synced/<id>/<skill>/SKILL.md) não é quebrado
  find -L "$s" -mindepth 2 -maxdepth 3 -name SKILL.md 2>/dev/null | grep -q . && continue
  echo "  $(basename "$s") -> $(readlink "$s" || echo '(diretório sem SKILL.md)')"; broken=$((broken+1))
done
[ "$broken" = 0 ] && echo "  nenhum"
echo "Feito. Rode \`opencode service stop\` (não restart) para o opencode ver as mudanças."
