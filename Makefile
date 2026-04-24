REMOTE ?= Ancalagon_Ubuntu-Tailnet

.PHONY: install install-system wake status coder qwen36 gemma4 off sleep logs

install:
	@bash scripts/install.sh

install-system:
	@scp systemd/99-wol.yaml scripts/setup-system.sh $(REMOTE):/tmp/
	@ssh $(REMOTE) 'bash /tmp/setup-system.sh'

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
