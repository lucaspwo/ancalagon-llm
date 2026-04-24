#!/bin/bash
# install.sh — sincroniza systemd units + lmswitch para o Ancalagon via Tailscale.
# Idempotente: reexecutar sobrescreve. Não desabilita LM Studio automaticamente.
set -euo pipefail

REMOTE="${REMOTE_SSH_HOST:-Ancalagon_Ubuntu-Tailnet}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Target: $REMOTE"
echo "Source: $REPO_DIR"
echo ""

echo "→ Copying systemd units..."
scp "$REPO_DIR"/systemd/llama-coder.service "$REPO_DIR"/systemd/llama-qwen36.service \
  "$REMOTE":/home/lucas/.config/systemd/user/

echo "→ Copying lmswitch wrapper..."
scp "$REPO_DIR"/bin/lmswitch "$REMOTE":/home/lucas/.local/bin/lmswitch
ssh "$REMOTE" 'chmod +x /home/lucas/.local/bin/lmswitch'

echo "→ Reloading systemd..."
ssh "$REMOTE" 'systemctl --user daemon-reload'

echo ""
echo "Done. Test with: ssh $REMOTE /home/lucas/.local/bin/lmswitch status"
echo ""
echo "If LM Studio is still running on :1234, stop it first:"
echo "  ssh $REMOTE 'systemctl --user stop lmstudio.service && systemctl --user disable lmstudio.service'"
