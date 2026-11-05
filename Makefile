REMOTE ?= Anc_U-T
# WoL: o ASUS (modo AP) manda o magic packet de dentro da LAN; a rota 192.168.1.2/32
# anunciada pelo Apple TV no Tailscale faz isso funcionar também de fora de casa.
WOL_MAC ?= 10:7C:61:45:D8:38
WOL_ROUTER ?= lucaspwo@192.168.1.2
WOL_IFACE ?= br0

.PHONY: install install-system install-gla install-skill install-gateway-local uninstall-gateway-local sync-opencode-skills wake status coder qwen36 qwen38 gemma4 flint colibri off sleep logs video-off video-on video-status bootwin bootwin-dry

install:
	@bash scripts/install.sh

install-system:
	@ssh $(REMOTE) 'mkdir -p /tmp/ancalagon-system/systemd /tmp/ancalagon-system/scripts /tmp/ancalagon-system/bin'
	@scp systemd/99-wol.yaml systemd/console-setup systemd/gpu-guard.service systemd/usb-port-guard.service systemd/openrgb-boot.service systemd/videoswitch-boot.service $(REMOTE):/tmp/ancalagon-system/systemd/
	@scp bin/gpu-guard bin/usb-port-guard $(REMOTE):/tmp/ancalagon-system/bin/
	@scp scripts/setup-system.sh $(REMOTE):/tmp/ancalagon-system/scripts/
	@ssh $(REMOTE) 'bash /tmp/ancalagon-system/scripts/setup-system.sh'

install-gla:
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(CURDIR)/clients/glaurung-llm/gla $(HOME)/.local/bin/gla
	@echo "installed: $(HOME)/.local/bin/gla -> $(CURDIR)/clients/glaurung-llm/gla"
	@command -v gla >/dev/null && echo "gla in PATH" || echo "WARN: ~/.local/bin not in PATH; add 'export PATH=\$$HOME/.local/bin:\$$PATH' to ~/.zshrc"

install-skill:
	@mkdir -p $(HOME)/.claude/skills
	@chmod +x $(CURDIR)/skills/delegando-ancalagon/anc-delegate
	@ln -sfn $(CURDIR)/skills/delegando-ancalagon $(HOME)/.claude/skills/delegando-ancalagon
	@echo "installed: $(HOME)/.claude/skills/delegando-ancalagon -> $(CURDIR)/skills/delegando-ancalagon"

install-gateway-local:
	@chmod +x $(CURDIR)/clients/opencode/llm-gateway-local.sh
	@sed -e 's|__REPO__|$(CURDIR)|g' -e 's|__HOME__|$(HOME)|g' clients/opencode/com.lucaspwo.llm-gateway-local.plist > $(HOME)/Library/LaunchAgents/com.lucaspwo.llm-gateway-local.plist
	@launchctl bootout gui/$$(id -u)/com.lucaspwo.llm-gateway-local 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/com.lucaspwo.llm-gateway-local.plist
	@echo "llm-gateway local em http://127.0.0.1:8090/v1 (log: ~/Library/Logs/llm-gateway-local.log)"

uninstall-gateway-local:
	@launchctl bootout gui/$$(id -u)/com.lucaspwo.llm-gateway-local 2>/dev/null || true
	@rm -f $(HOME)/Library/LaunchAgents/com.lucaspwo.llm-gateway-local.plist
	@echo "llm-gateway local removido"

sync-opencode-skills:
	@bash clients/opencode/sync-claude-skills.sh

wake:
	@if ssh -o BatchMode=yes -o ConnectTimeout=5 $(WOL_ROUTER) 'ether-wake -i $(WOL_IFACE) $(WOL_MAC)'; then \
		echo "WoL enviado via ASUS ($(WOL_ROUTER), $(WOL_IFACE)) para $(WOL_MAC)"; \
	else \
		echo "ASUS ($(WOL_ROUTER)) inacessível — fallback para wakeonlan local (só alcança a LAN)" >&2; \
		wakeonlan $(WOL_MAC); \
	fi

status:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch status

coder:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch coder

qwen36:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch qwen36

qwen38:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch qwen38

gemma4:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch gemma4

flint:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch flint

colibri:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch colibri

off:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch off

sleep:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch sleep

logs:
	@ssh -t $(REMOTE) /home/lucas/.local/bin/lmswitch logs

video-off:
	@ssh $(REMOTE) /home/lucas/.local/bin/videoswitch off

video-on:
	@ssh $(REMOTE) /home/lucas/.local/bin/videoswitch on

video-status:
	@ssh $(REMOTE) /home/lucas/.local/bin/videoswitch status

bootwin-dry:
	@ssh $(REMOTE) /home/lucas/.local/bin/bootwin --dry-run

bootwin:
	@ssh $(REMOTE) /home/lucas/.local/bin/bootwin
