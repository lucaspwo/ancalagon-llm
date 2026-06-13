REMOTE ?= Ancalagon_Ubuntu-Tailnet

.PHONY: install install-system install-gla install-skill wake status coder qwen36 gemma4 off sleep logs video-off video-on video-status bootwin bootwin-dry

install:
	@bash scripts/install.sh

install-system:
	@ssh $(REMOTE) 'mkdir -p /tmp/ancalagon-system/systemd /tmp/ancalagon-system/scripts'
	@scp systemd/99-wol.yaml systemd/console-setup $(REMOTE):/tmp/ancalagon-system/systemd/
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

wake:
	@wakeonlan 10:7C:61:45:D8:38

status:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch status

coder:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch coder

qwen36:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch qwen36

gemma4:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch gemma4

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
