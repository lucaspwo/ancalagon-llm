#!/bin/bash
# install.sh — sincroniza systemd units + lmswitch para o Ancalagon via Tailscale.
# Idempotente: reexecutar sobrescreve. Não desabilita LM Studio automaticamente.
set -euo pipefail

REMOTE="${REMOTE_SSH_HOST:-Anc_U-T}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Target: $REMOTE"
echo "Source: $REPO_DIR"
echo ""

echo "→ Copying systemd units..."
scp "$REPO_DIR"/systemd/llama-coder.service "$REPO_DIR"/systemd/llama-qwen36.service \
  "$REPO_DIR"/systemd/llama-qwen38.service "$REPO_DIR"/systemd/llama-gemma4.service \
  "$REPO_DIR"/systemd/colibri-qwen36.service \
  "$REMOTE":/home/lucas/.config/systemd/user/

echo "→ Copying lmswitch / videoswitch / bootwin wrappers..."
scp "$REPO_DIR"/bin/lmswitch "$REPO_DIR"/bin/videoswitch "$REPO_DIR"/bin/bootwin \
  "$REMOTE":/home/lucas/.local/bin/
ssh "$REMOTE" 'chmod +x /home/lucas/.local/bin/lmswitch /home/lucas/.local/bin/videoswitch /home/lucas/.local/bin/bootwin'

echo "→ Installing videoswitch-reblank + udev rule (keeps video off across DRM hotplug)..."
scp "$REPO_DIR"/bin/videoswitch-reblank "$REPO_DIR"/systemd/90-videoswitch-reblank.rules "$REMOTE":/tmp/
ssh "$REMOTE" 'sudo install -m 0755 -o root -g root /tmp/videoswitch-reblank /usr/local/bin/videoswitch-reblank \
  && sudo install -m 0644 -o root -g root /tmp/90-videoswitch-reblank.rules /etc/udev/rules.d/90-videoswitch-reblank.rules \
  && sudo udevadm control --reload \
  && rm -f /tmp/videoswitch-reblank /tmp/90-videoswitch-reblank.rules'

echo "→ Reloading systemd..."
ssh "$REMOTE" 'systemctl --user daemon-reload'

echo ""
echo "Done. Test with: ssh $REMOTE /home/lucas/.local/bin/lmswitch status"
echo ""
echo "If LM Studio is still running on :1234, stop it first:"
echo "  ssh $REMOTE 'systemctl --user stop lmstudio.service && systemctl --user disable lmstudio.service'"
