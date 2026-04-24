REMOTE ?= Ancalagon_Ubuntu-Tailnet

.PHONY: install status coder qwen36 off logs

install:
	@bash scripts/install.sh

status:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch status

coder:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch coder

qwen36:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch qwen36

off:
	@ssh $(REMOTE) /home/lucas/.local/bin/lmswitch off

logs:
	@ssh -t $(REMOTE) /home/lucas/.local/bin/lmswitch logs
