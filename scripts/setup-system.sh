#!/bin/bash
# setup-system.sh — aplica configurações de sistema no Ancalagon que são
# pré-requisito para o `lmswitch sleep` funcionar corretamente.
#
# Idempotente. Roda com sudo (ou via usuário com NOPASSWD).
#
# O que faz:
#   1. Habilita nvidia-suspend/resume/hibernate.service, SE existirem (o driver
#      nvidia-open antigo falhava o suspend sem eles — observado 2026-04-24 com erro
#      NVRM "PreserveVideoMemoryAllocations ..."). A série 615 não traz mais essas
#      units: o passo vira no-op e só imprime o PreserveVideoMemoryAllocations.
#   2. Instala netplan override /etc/netplan/99-wol.yaml para armar
#      Wake-on-LAN na eno1 (default vem como "wol: d" = disabled).
#   3. Aplica netplan (netplan apply) e valida ethtool.
#   4. Instala /etc/default/console-setup com TerminusBold 16x32 / Lat15
#      (console TTY legível em 1080p+; ver docs/console-setup.md).
#   5. Instala usb-port-guard (system service): desabilita a USB port11 morta
#      no boot e a cada resume (erro -71 em loop; ver docs/usb-port11.md).
#   6. Instala openrgb-boot + videoswitch-boot (system services): apagam os LEDs RGB
#      e os monitores ao fim do boot.
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
# A série 615 do driver não traz mais nvidia-suspend/resume/hibernate.service nem o nvidia-sleep.sh
# (conferido nos .deb de 615.71.09 e 615.71.10): o suspend é tratado dentro do driver
# (PreserveVideoMemoryAllocations=1) + drop-in nvidia-suspend-nofreeze.conf no systemd-suspend.
# Habilita só as units que existirem; antes, a ausência abortava o script inteiro (set -e).
NVIDIA_SLEEP_UNITS=()
for unit in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
  if systemctl list-unit-files "$unit" --no-legend | grep -q "$unit"; then
    NVIDIA_SLEEP_UNITS+=("$unit")
  fi
done
if [ "${#NVIDIA_SLEEP_UNITS[@]}" -gt 0 ]; then
  sudo systemctl enable "${NVIDIA_SLEEP_UNITS[@]}" 2>&1 | tail -5
else
  echo "  driver sem nvidia-suspend/resume/hibernate.service (série 615+): nada a habilitar"
  grep -h PreserveVideoMemoryAllocations /proc/driver/nvidia/params | sed 's/^/  /'
fi
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
# O setupcon reconfigura o console e religa a saída de vídeo SEM uevent de hotplug, então a regra
# 90-videoswitch-reblank não age (visto em 2026-11-02: monitores "ligados de tela preta" depois do
# install-system). Respeita o último `videoswitch off`.
if [ "$(cat /run/videoswitch.state 2>/dev/null)" = off ] && [ -e /sys/class/graphics/fb0/blank ]; then
  sudo sh -c 'echo 4 > /sys/class/graphics/fb0/blank'
  echo "  vídeo reapagado (videoswitch estava em off)"
fi
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
echo "→ Instalando usb-port-guard (desabilita a USB port11 morta)..."
sudo install -m 0755 "$REPO_DIR/bin/usb-port-guard" /usr/local/bin/usb-port-guard
sudo install -m 0644 "$REPO_DIR/systemd/usb-port-guard.service" \
  /etc/systemd/system/usb-port-guard.service
sudo systemctl daemon-reload
sudo systemctl enable --now usb-port-guard.service
sudo systemctl start usb-port-guard.service

echo ""
echo "→ Instalando openrgb-boot + videoswitch-boot (LEDs e monitores apagados ao fim do boot)..."
sudo install -m 0644 -o root -g root "$REPO_DIR/systemd/openrgb-boot.service" \
  /etc/systemd/system/openrgb-boot.service
sudo install -m 0644 -o root -g root "$REPO_DIR/systemd/videoswitch-boot.service" \
  /etc/systemd/system/videoswitch-boot.service
sudo systemctl daemon-reload
# Só enable: o efeito vale a partir do próximo boot. Não apaga os monitores de quem roda isto na frente
# da máquina (para apagar agora: `videoswitch off`).
# reenable (não enable): o [Install] do openrgb-boot ganhou os targets de suspend em 2026-11-04 e a
# versão antiga, criada à mão, só tinha os links de multi-user.target.
sudo systemctl reenable openrgb-boot.service videoswitch-boot.service

echo ""
echo "Done. Teste com: lmswitch sleep (do Ancalagon) ou anc_lin_sleep (do Mac)"
echo "Acordar com: wakeonlan 10:7C:61:45:D8:38 (do Mac)"
