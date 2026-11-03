#!/bin/bash
# Roda o llm-gateway (repo homelab, compose/llm-gateway) no proprio Mac, em 127.0.0.1:8090, falando
# direto com o Ancalagon via Tailscale. Substitui o gateway do Scatha quando ele esta fora do ar:
# o opencode continua com "escolher o modelo e ele sobe sozinho" (lmswitch + hot-swap por request).
# Instalado como LaunchAgent por `make install-gateway-local`; logs em ~/Library/Logs/llm-gateway-local.log.
# WoL so chega ao Ancalagon se o Mac estiver na mesma LAN (broadcast); via Tailscale, so com ele acordado.
set -euo pipefail

GW_DIR="${LLM_GATEWAY_DIR:-$HOME/git/homelab/compose/llm-gateway}"
cd "$GW_DIR"

# Defaults do app/config.py ja apontam para os nos MagicDNS (ancalagon-ubuntu / ancalagon).
export ANC_SSH_KEY="${ANC_SSH_KEY:-$HOME/.ssh/id_ed25519}"
export ANC_MODELS="${ANC_MODELS:-coder,qwen36,qwen38,gemma4,flint}"
export LISTEN_PORT="${LISTEN_PORT:-8090}"

# O __main__.py do gateway binda 0.0.0.0; aqui so o proprio Mac precisa acessar.
exec "$GW_DIR/.venv/bin/python" -c '
import logging
from aiohttp import web
from app.config import Config
from app.gateway import make_app
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
cfg = Config()
web.run_app(make_app(cfg), host="127.0.0.1", port=cfg.listen_port)
'
