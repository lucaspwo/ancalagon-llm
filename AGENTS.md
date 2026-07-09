# AGENTS — ancalagon-llm

Operational provisioning of the Ancalagon Ubuntu box as a dedicated local LLM server (llama.cpp + systemd), consumed from a Mac over Tailscale. Stack: Bash scripts, systemd `--user` units, a thin `Makefile`. No application code, no build system, no automated test suite.

## File map

| Path | Purpose |
|---|---|
| `Makefile` | Entry points: `install`, `install-system`, `install-gla`, `install-skill`, `wake`, `status`, `coder`, `qwen36`, `gemma4`, `off`, `sleep`, `logs`, `video-{off,on,status}`, `bootwin{,-dry}` |
| `systemd/llama-coder.service` | Unit — Qwen3-Coder-30B MoE, `--n-cpu-moe 16`, KV q4/q4, ctx 98304 |
| `systemd/llama-qwen36.service` | Unit — Qwen3.6-27B-TQ3_4S (fork `turbo-tan/llama.cpp-tq3`), KV q8/q8, ctx 40960 |
| `systemd/llama-gemma4.service` | Unit — Gemma 4 26B-A4B-it MoE, `--n-cpu-moe 8`, KV q4/q4, ctx 98304 |
| `systemd/gpu-guard.service` | Unit — thermal watchdog, `enabled` (persistent, unlike the three above) |
| `systemd/99-wol.yaml` | netplan override — arms Wake-on-LAN on `eno1` |
| `systemd/console-setup` | `/etc/default/console-setup` — TTY font config |
| `bin/lmswitch` | Preset switcher (runs on Ancalagon): `coder\|qwen36\|gemma4\|off\|sleep\|status\|logs` |
| `bin/gpu-guard` | Thermal watchdog daemon (nvidia-smi polling loop) |
| `bin/videoswitch` | DPMS toggle for the physical console (`off\|on\|status`) |
| `bin/bootwin` | One-shot UEFI reboot into Windows (`--dry-run` supported) |
| `scripts/install.sh` | Deploys units + `bin/` wrappers to Ancalagon via `scp` + `daemon-reload` |
| `scripts/setup-system.sh` | One-time system prerequisites (WoL, nvidia-suspend/resume/hibernate, console font, gpu-guard enable) |
| `scripts/build-llama.sh` | Reference build script for llama.cpp (manual, not wired to `make`) |
| `clients/glaurung-llm/gla` | Mac-side backend switcher (llama.cpp Metal / MLX) + opencode launcher |
| `clients/glaurung-llm/TUNING.md` | Mac-side tuning data (untracked at last audit — see coverage note) |
| `clients/opencode/opencode.json` | Template config wiring `ancalagon/*`, `glaurung/*`, `glaurung-mlx/*` providers |
| `clients/opencode/README.md` | Setup + provider-selection guide for `opencode` |
| `skills/delegando-ancalagon/anc-delegate` | Headless delegation helper: `preflight\|gen\|iter\|health` |
| `skills/delegando-ancalagon/SKILL.md` | Claude Code skill definition (Path 1 vs Path 2 routing rules) |
| `benchmarks/TUNING.md`, `benchmarks/POWER.md` | Raw empirical tuning data behind current flags |
| `docs/delegation.md` | Cloud↔Ancalagon delegation charter (three usage modes) |
| `docs/console-setup.md` | Console TTY font setup rationale |
| `AI_CONTEXT.md` | One-page PT-BR session bootstrap (pre-existing convention, not superseded by this file) |

## Key symbols

- `bin/lmswitch:24` — `wait_ready()` — polls `/health` up to 90s after starting a service; aborts if the unit isn't active
- `bin/lmswitch:46` — main `case "$COMMAND" in` dispatch for `coder|qwen36|gemma4|off|sleep|status|logs`
- `bin/lmswitch:71` — `sleep|suspend` case — stops all three llama services, detaches `sudo -n systemctl suspend` via `nohup … & disown`
- `bin/gpu-guard:12` — `WARN_TEMP`/`CRIT_TEMP` defaults (82°C / 86°C), empirically calibrated
- `bin/gpu-guard:22` — `active_llama()` — finds which of the three `llama-*.service` units is active
- `bin/gpu-guard:28` — main polling loop — escalates WARN (log only) → sustained CRIT (`HOLD` seconds) → `systemctl --user stop` on the active service
- `bin/videoswitch:23` — `require_fb()` — guards that `/sys/class/graphics/fb0/blank` exists
- `bin/videoswitch:30` — `off|on|status` dispatch — writes to `fb0` via `sudo -n sh -c`, persists last state to `/run/videoswitch.state` (the `nvidia-drm` driver returns empty on read)
- `bin/bootwin:13` — locates the "Windows Boot Manager" entry via `efibootmgr`
- `bin/bootwin:21` — parses `BootNum` with `awk`, validates a 4-hex-digit regex before use
- `bin/bootwin:42` — sets `BootNext` and detaches `systemctl reboot` (one-shot — firmware clears `BootNext` after the next boot)
- `scripts/install.sh:14` — `scp` of the three `systemd/llama-*.service` units to `~/.config/systemd/user/`
- `scripts/install.sh:19` — `scp` of `lmswitch`/`videoswitch`/`bootwin` to `~/.local/bin/` + remote `chmod +x`
- `scripts/setup-system.sh:29` — enables `nvidia-suspend/resume/hibernate.service`
- `scripts/setup-system.sh:33` — installs `systemd/99-wol.yaml` to `/etc/netplan/` + `netplan apply`
- `scripts/setup-system.sh:50` — installs and `enable --now`s `gpu-guard.service`
- `clients/glaurung-llm/gla:16` — `_pids_on_port()` / `:20` `_kill_port()` — port-based process discovery/kill via `lsof`
- `clients/glaurung-llm/gla:47` — `_mutex()` — frees ports 1235 (llama.cpp) and 1236 (MLX) before starting a new backend
- `clients/glaurung-llm/gla:56` — `_start_lcpp_qwen36()` / `:68` `_start_lcpp_gemma4()` — start local `llama-server` with tuned flags (KV q8/q8, `--no-mmap --jinja`)
- `clients/glaurung-llm/gla:80` — `_start_mlx()` — starts `mlx_lm.server` (lazy load, no `--model` flag)
- `clients/glaurung-llm/gla:103` — `_set_opencode_model()` — rewrites `.model` in `opencode.json` via `jq`
- `clients/glaurung-llm/gla:159` — `cmd_run()` — preflight validation → mutex → start → wait → write model → `exec opencode`
- `skills/delegando-ancalagon/anc-delegate:36` — `active_service()` — SSH probe for the currently active `llama-*.service`
- `skills/delegando-ancalagon/anc-delegate:45` — `ensure_model()` — keeps the active service if healthy, else starts via `lmswitch`
- `skills/delegando-ancalagon/anc-delegate:59` — `wake_and_wait()` — sends `wakeonlan`, polls SSH up to `BOOT_TIMEOUT` (120s)
- `skills/delegando-ancalagon/anc-delegate:87` — `preflight()` — SSH-alive → WoL → Windows-reachable-reboot escalation; returns terminal error rather than looping
- `skills/delegando-ancalagon/anc-delegate:113` — `gen()` — Path 1: one-shot `curl` to `/v1/chat/completions`, aborts if the briefing is ~40K+ estimated tokens
- `skills/delegando-ancalagon/anc-delegate:150` — `iter()` — Path 2: headless `local-claude --backend remote -p <briefing> --output-format json`
- `skills/delegando-ancalagon/anc-delegate:179` — `health_snapshot()` — JSON of active service + `nvidia-smi` temp/power/throttle

## Commands

- Build: none — `llama-server` (upstream + TQ3 fork) is compiled manually on Ancalagon, outside this repo's scope (`scripts/build-llama.sh` is a reference only)
- Test: none — no automated suite. Manual validation via `make status` + a fixed benchmark prompt against the regression thresholds in `AI_CONTEXT.md` § "Como testar uma mudança" (coder <55 tok/s, qwen36 <25 tok/s, gemma4 <40 tok/s = regression)
- Lint: `shellcheck bin/*` (manual, not hooked into CI — there is no CI in this repo)
- Deploy: `make install` (units + wrappers) · `make install-system` (one-time host prerequisites) · `make install-gla` / `make install-skill` (Mac-side components)
- Run: `make coder` / `make qwen36` / `make gemma4` (start a preset) · `make status` (health) · `make logs` (tail journal) · `make off` / `make sleep` (stop / suspend)

## Conventions & constraints

- Bash scripts in `bin/` and `scripts/` are `set -euo pipefail`, shellcheck-clean, everything quoted — keep new scripts to the same bar.
- `systemd/llama-*.service` units declare `Conflicts=` against **all** the other llama/lmstudio units, not just one — when adding a new preset, update the existing units too (systemd doesn't infer symmetry).
- All three llama presets bind port `1234` on purpose — never assign a new preset a different port; `Conflicts=` is what makes that safe.
- KV cache must stay symmetric (K quant == V quant) per service — an asymmetric K≠V pairing caused a catastrophic CUDA fallback (~1 tok/s) on Qwen3.6-27B; this was tested, not theoretical.
- SSH aliases from the Mac must use the **absolute path** `/home/lucas/.local/bin/<script>` — non-interactive SSH sessions don't source the interactive shell's `$PATH`.
- `gpu-guard.service` is `enabled` (persistent); the three `llama-*.service` units are intentionally **not** — don't "fix" this asymmetry, it's a deliberate VRAM-sharing decision (see MANUTENCAO.md gotchas).

## Common change recipes

1. **Add a new model preset**: create `systemd/llama-<name>.service` mirroring the existing three (cross `Conflicts=`), add `Conflicts=llama-<name>.service` to the other units, add a case in `bin/lmswitch:46`, add the `scp` in `scripts/install.sh:14` and a `make <name>` target in `Makefile`. Deploy with `make install`, verify with `make <name>` + `make status`.
2. **Change context window (`-c`) of a preset**: edit `ExecStart=` in the relevant `systemd/llama-*.service`, check whether `--n-cpu-moe` needs a matching bump (KV cache grows linearly with context — see `benchmarks/TUNING.md` for the ctx/ncmoe tradeoff table), update `limit.context` for the matching provider in `clients/opencode/opencode.json`, then `make install` + restart + `make status`.
3. **Tune thermal watchdog thresholds**: edit `WARN_TEMP`/`CRIT_TEMP`/`HOLD` in `bin/gpu-guard:12-14` (or override via `GPU_GUARD_WARN_TEMP`/`GPU_GUARD_CRIT_TEMP`/`GPU_GUARD_HOLD` env in the unit), redeploy with `make install-system`, validate with `journalctl --user -u gpu-guard.service -f` under sustained load.
4. **Add a new `make` target**: follow the existing pattern `@ssh $(REMOTE) /home/lucas/.local/bin/<script> <args>` for remote operations; if it invokes a new `bin/` script, add its `scp` to `scripts/install.sh`.

## Do NOT touch

- `AI_CONTEXT.md` is a pre-existing PT-BR bootstrap doc (Intellissis repo convention) — it is not superseded by this file; keep both in sync when architecture changes, don't delete it.
- `.specstory/` — SpecStory session history, auto-managed, gitignored.
- `.claude/settings.local.json` — local Claude Code permission allowlist, gitignored, machine-specific.
- Model binaries and GGUF weight files — never live in this repo; they're provisioned manually on Ancalagon/Glaurung per MANUTENCAO.md "Dependências e integrações".
