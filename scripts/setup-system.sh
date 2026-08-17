#!/bin/bash
# setup-system.sh — aplica configurações de sistema no Ancalagon que são
# pré-requisito para o `lmswitch sleep` funcionar corretamente.
#
# Idempotente. Roda com sudo (ou via usuário com NOPASSWD).
#
# O que faz:
#   1. Habilita nvidia-suspend/resume/hibernate.service (o driver nvidia-open
#      falha o suspend se esses services não estiverem ativos — observado
#      2026-04-24 com erro NVRM "PreserveVideoMemoryAllocations ...").
#   2. Instala netplan override /etc/netplan/99-wol.yaml para armar
#      Wake-on-LAN na eno1 (default vem como "wol: d" = disabled).
#   3. Aplica netplan (netplan apply) e valida ethtool.
#   4. Instala /etc/default/console-setup com TerminusBold 16x32 / Lat15
#      (console TTY legível em 1080p+; ver docs/console-setup.md).
#
# Pré-requisito não gerenciado aqui:
#   - /etc/sudoers.d/lucas-nopasswd com "lucas ALL=(ALL) NOPASSWD: ALL"
#     (feito out-of-band na primeira instalação — trocar senha root pós-install)
#
# Uso: no Ancalagon, `bash scripts/setup-system.sh`
# Deploy remoto: `make install-system` do Mac.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "→ Habilitando nvidia-*.service..."
sudo systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service 2>&1 | tail -5
echo ""

echo "→ Instalando netplan override 99-wol.yaml..."
sudo install -m 0600 -o root -g root \
  "$REPO_DIR/systemd/99-wol.yaml" /etc/netplan/99-wol.yaml
sudo netplan apply

echo ""
echo "→ Validando WoL armado..."
sleep 2
sudo ethtool eno1 | grep -E "Wake-on" | sed 's/^/  /'

echo ""
echo "→ Instalando /etc/default/console-setup (TerminusBold 16x32)..."
sudo install -m 0644 -o root -g root \
  "$REPO_DIR/systemd/console-setup" /etc/default/console-setup
sudo setupcon --save --force 2>&1 | tail -5 || true
sudo update-initramfs -u 2>&1 | tail -2

echo ""
echo "→ Instalando gpu-guard (watchdog térmico, user service persistente)..."
install -m 0755 "$REPO_DIR/bin/gpu-guard" "$HOME/.local/bin/gpu-guard"
install -d "$HOME/.config/systemd/user"
install -m 0644 "$REPO_DIR/systemd/gpu-guard.service" "$HOME/.config/systemd/user/gpu-guard.service"
systemctl --user daemon-reload
systemctl --user enable --now gpu-guard.service
systemctl --user is-active gpu-guard.service && echo "  gpu-guard ativo"

echo ""
echo "Done. Teste com: lmswitch sleep (do Ancalagon) ou anc_lin_sleep (do Mac)"
echo "Acordar com: wakeonlan 10:7C:61:45:D8:38 (do Mac)"
