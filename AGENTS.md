# AGENTS — ancalagon-llm

Operational provisioning of the Ancalagon Ubuntu box as a dedicated local LLM server (llama.cpp + systemd), consumed from a Mac over Tailscale. Stack: Bash scripts, systemd `--user` units, a thin `Makefile`. No application code, no build system, no automated test suite.

## File map

| Path | Purpose |
|---|---|
| `Makefile` | Entry points: `install`, `install-system`, `install-gla`, `install-skill`, `install-gateway-local`, `uninstall-gateway-local`, `wake`, `status`, `coder`, `qwen36`, `qwen38`, `gemma4`, `flint`, `off`, `sleep`, `logs`, `video-{off,on,status}`, `bootwin{,-dry}` |
| `systemd/llama-coder.service` | Unit — Qwen3-Coder-30B MoE, `--n-cpu-moe 17 -ub 2048 -t 6`, KV q4/q4, ctx 98304 |
| `systemd/llama-qwen36.service` | Unit — Qwen3.6-27B-TQ3_4S (fork `turbo-tan/llama.cpp-tq3`), KV q8/q8, ctx 40960 |
| `systemd/llama-qwen38.service` | Unit — Qwen3.8-27B-IQ3_M (fork `turbo-tan/llama.cpp-tq3`), KV q8/q8, ctx 40960, `-np 1` (one slot owns the whole KV; with the default 4 slots the opencode's parallel requests overflowed it — `benchmarks/TUNING.md` §20) |
| `systemd/llama-gemma4.service` | Unit — Gemma 4 26B-A4B-it MoE, `--n-cpu-moe 8 -ub 2048 -t 6`, KV q4/q4, ctx 98304 |
| `systemd/llama-flint.service` | Unit — Recursive Flint 40B-A2.5B MoE (UD-Q4_K_XL, upstream llama.cpp ≥ `a37cc461`), `--n-cpu-moe 25 -ub 2048 -t 6`, KV q8/q8, ctx 131072 |
| `systemd/colibri-qwen36.service` | Unit — Qwen3.6-35B-A3B MoE via the [Colibrì](https://github.com/JustVugg/colibri) engine (not llama.cpp), CUDA VRAM expert tier, `--auto-tier --cap 256`, `COLI_ALLOW_INSECURE_BIND=1`, `COLI_ALLOWED_HOSTS` (Host guard → 403 otherwise), `OMP_WAIT_POLICY=PASSIVE` |
| `systemd/gpu-guard.service` | Unit — thermal watchdog, `enabled` (persistent, unlike the four services above) |
| `systemd/usb-port-guard.service` | System unit — disables the dead USB port11 on boot and on every resume (see `docs/usb-port11.md`) |
| `systemd/openrgb-boot.service` | System unit — `openrgb -c 000000` (RGB off: 2× ENE DRAM + ASUS AURA USB `0b05:19af`) on boot **and on every resume** (resume re-enumerates USB and the AURA controller resets to factory colors) |
| `systemd/videoswitch-boot.service` | System unit — `videoswitch off` at the end of boot (monitors off; `make video-on` to restore) |
| `systemd/99-wol.yaml` | netplan override — arms Wake-on-LAN on `eno1` |
| `systemd/console-setup` | `/etc/default/console-setup` — TTY font config |
| `bin/lmswitch` | Preset switcher (runs on Ancalagon): `coder\|qwen36\|qwen38\|gemma4\|flint\|colibri\|off\|sleep\|status\|logs` |
| `bin/gpu-guard` | Thermal watchdog daemon (nvidia-smi polling loop) |
| `bin/usb-port-guard` | Disables a dead USB port by PCI address (bus number is not stable across boots) |
| `bin/videoswitch` | DPMS toggle for the physical console (`off\|on\|status`) |
| `bin/videoswitch-reblank` + `systemd/90-videoswitch-reblank.rules` | udev hook (`drm change HOTPLUG=1`) that re-blanks `fb0` when a monitor's sleep/HPD drop makes nvidia-drm relight the output after `videoswitch off` |
| `bin/bootwin` | One-shot UEFI reboot into Windows (`--dry-run` supported) |
| `scripts/install.sh` | Deploys units + `bin/` wrappers to Ancalagon via `scp` + `daemon-reload` |
| `scripts/setup-system.sh` | One-time system prerequisites (WoL, nvidia-suspend/resume/hibernate when the driver still ships them, console font, gpu-guard enable, usb-port-guard, openrgb-boot + videoswitch-boot) |
| `scripts/build-llama.sh` | Reference build script for llama.cpp (manual, not wired to `make`) |
| `scripts/bench-presets.py` | A/B benchmark of the presets (decode + prefill), run on Ancalagon; method in `benchmarks/TUNING.md` §16 |
| `benchmarks/agentic/` | Agentic benchmark: opencode solves `hard`/`bugfix`/`refactor` tasks, graded from outside with hidden tests (`matrix.sh MODEL TAG`, `run.sh`); results in `benchmarks/TUNING.md` §20 |
| `clients/glaurung-llm/gla` | Mac-side backend switcher (llama.cpp Metal / MLX) + opencode launcher |
| `clients/glaurung-llm/TUNING.md` | Mac-side tuning data (untracked at last audit — see coverage note) |
| `clients/opencode/opencode.json` | Template config wiring `ancalagon/*`, `glaurung/*`, `glaurung-mlx/*` providers |
| `clients/opencode/README.md` | Setup + provider-selection guide for `opencode` |
| `clients/opencode/AGENTS.md` | Rules pre-prompt for local models in opencode (wired via `instructions` in `~/.config/opencode/opencode.json`) |
| `skills/delegando-ancalagon/anc-delegate` | Headless delegation helper: `preflight\|gen\|iter\|health` |
| `skills/delegando-ancalagon/SKILL.md` | Claude Code skill definition (Path 1 vs Path 2 routing rules) |
| `benchmarks/TUNING.md`, `benchmarks/POWER.md` | Raw empirical tuning data behind current flags |
| `docs/delegation.md` | Cloud↔Ancalagon delegation charter (three usage modes) |
| `docs/console-setup.md` | Console TTY font setup rationale |
| `AI_CONTEXT.md` | One-page PT-BR session bootstrap (pre-existing convention, not superseded by this file) |

## Key symbols

- `bin/lmswitch:27` — `wait_ready()` — polls `/health` up to 90s (or the optional 3rd-arg timeout) after starting a service; aborts if the unit isn't active
- `bin/lmswitch:50` — `ALL_SERVICES` array + `stop_all()` — single source of the six service names, shared by every case that needs to stop everything else first
- `bin/lmswitch:58` — main `case "$COMMAND" in` dispatch for `coder|qwen36|qwen38|gemma4|flint|colibri|off|sleep|status|logs` (`flint` waits up to 180 s: `wait_ready` takes an optional timeout, the 25 GB GGUF took 75 s cold)
- `bin/lmswitch:94` — `sleep|suspend` case — stops all six services via `stop_all`, detaches `sudo -n systemctl suspend` via `nohup … & disown`
- `bin/gpu-guard:12` — `WARN_TEMP`/`CRIT_TEMP` defaults (82°C / 86°C), empirically calibrated
- `bin/gpu-guard:22` — `active_service()` — finds which of the six presets is active (`llama-flint` added 2026-11-02) (renamed from `active_llama` on 2026-09-27 while fixing a real gap: the list was stuck at three names — coder/qwen36/gemma4 — and had never picked up `qwen38`, so the thermal watchdog couldn't cut that preset under sustained overheat; fixed alongside adding `colibri-qwen36`)
- `bin/gpu-guard:28` — main polling loop — escalates WARN (log only) → sustained CRIT (`HOLD` seconds) → `systemctl --user stop` on the active service
- `bin/videoswitch:23` — `require_fb()` — guards that `/sys/class/graphics/fb0/blank` exists
- `bin/videoswitch:30` — `off|on|status` dispatch — writes to `fb0` via `sudo -n sh -c`, persists last state to `/run/videoswitch.state` (the `nvidia-drm` driver returns empty on read)
- `bin/videoswitch-reblank:22` — re-blank loop (10 × 0.5 s after each DRM hotplug uevent), only when `/run/videoswitch.state` is `off`; counts only `connected` connectors (disconnected ones also report `dpms=On`)
- `bin/bootwin:13` — locates the "Windows Boot Manager" entry via `efibootmgr`
- `bin/bootwin:21` — parses `BootNum` with `awk`, validates a 4-hex-digit regex before use
- `bin/bootwin:42` — sets `BootNext` and detaches `systemctl reboot` (one-shot — firmware clears `BootNext` after the next boot)
- `scripts/install.sh:14` — `scp` of the four `systemd/llama-*.service` units plus `colibri-qwen36.service` to `~/.config/systemd/user/`
- `scripts/install.sh:19` — `scp` of `lmswitch`/`videoswitch`/`bootwin` to `~/.local/bin/` + remote `chmod +x`
- `scripts/install.sh:24` — `sudo install` of `videoswitch-reblank` to `/usr/local/bin/` and the udev rule to `/etc/udev/rules.d/` + `udevadm control --reload`
- `scripts/setup-system.sh:31` — enables `nvidia-suspend/resume/hibernate.service` only if present (driver series 615 dropped them; suspend is in-driver with `PreserveVideoMemoryAllocations=1` — before 2026-11-02 their absence aborted the whole script)
- `scripts/setup-system.sh:50` — installs `systemd/99-wol.yaml` to `/etc/netplan/` + `netplan apply`
- `scripts/setup-system.sh:75` — installs and `enable --now`s `gpu-guard.service`
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

- Build: none — `llama-server` (upstream + TQ3 fork) and the Colibrì `qwen36` engine are compiled manually on Ancalagon, outside this repo's scope (`scripts/build-llama.sh` is a reference only)
- Test: none — no automated suite. Manual validation via `make status` + a fixed benchmark prompt (`scripts/bench-presets.py`) against the regression thresholds in `AI_CONTEXT.md` § "Como testar uma mudança" (coder <55 tok/s, qwen36 <25 tok/s, qwen38 <25 tok/s, gemma4 <40 tok/s, colibri <19 tok/s = regression)
- Lint: `shellcheck bin/*` (manual, not hooked into CI — there is no CI in this repo)
- Deploy: `make install` (units + wrappers) · `make install-system` (one-time host prerequisites) · `make install-gla` / `make install-skill` / `make install-gateway-local` (Mac-side components; the last one is a LaunchAgent running the homelab llm-gateway on 127.0.0.1:8090 while Scatha is down)
- Run: `make coder` / `make qwen36` / `make qwen38` / `make gemma4` / `make flint` / `make colibri` (start a preset) · `make status` (health) · `make logs` (tail journal) · `make off` / `make sleep` (stop / suspend)

## Conventions & constraints

- Bash scripts in `bin/` and `scripts/` are `set -euo pipefail`, shellcheck-clean, everything quoted — keep new scripts to the same bar.
- Every service unit (`llama-*.service` and `colibri-qwen36.service`) declares `Conflicts=` against **all** the other presets and against `lmstudio.service`, not just one — when adding a new preset, update the existing units too (systemd doesn't infer symmetry).
- All five presets bind port `1234` on purpose — never assign a new preset a different port; `Conflicts=` is what makes that safe.
- A non-llama.cpp engine (like Colibrì) is a first-class preset too: same port, same `Conflicts=` set, same `lmswitch` dispatch — `bin/lmswitch` doesn't assume every preset is a `llama-*.service`/`llama-server` invocation, it only assumes an OpenAI-compatible `/health` + `/v1/chat/completions` on `:1234`.
- KV cache must stay symmetric (K quant == V quant) per service — an asymmetric K≠V pairing caused a catastrophic CUDA fallback (~1 tok/s) on Qwen3.6-27B; this was tested, not theoretical.
- SSH aliases from the Mac must use the **absolute path** `/home/lucas/.local/bin/<script>` — non-interactive SSH sessions don't source the interactive shell's `$PATH`.
- `gpu-guard.service` is `enabled` (persistent); the four `llama-*.service` units and `colibri-qwen36.service` are intentionally **not** — don't "fix" this asymmetry, it's a deliberate VRAM-sharing decision (see MANUTENCAO.md gotchas).

## Common change recipes

1. **Add a new model preset**: create `systemd/<engine>-<name>.service` mirroring an existing one (cross `Conflicts=` against **all** current presets, llama.cpp-based or not), add `Conflicts=<engine>-<name>.service` to the other units, add its name to `ALL_SERVICES` and a case in `bin/lmswitch:58`, add the `scp` in `scripts/install.sh:14` and a `make <name>` target in `Makefile`. Deploy with `make install`, verify with `make <name>` + `make status`. The preset need not be `llama.cpp` at all — `colibri-qwen36.service` runs a different engine (Colibrì) and only has to satisfy `lmswitch`'s two assumptions (`:1234`, `/health` + `/v1/chat/completions`).
2. **Change context window (`-c`) of a preset**: edit `ExecStart=` in the relevant `systemd/llama-*.service`, check whether `--n-cpu-moe` needs a matching bump (KV cache grows linearly with context — see `benchmarks/TUNING.md` for the ctx/ncmoe tradeoff table), update `limit.context` for the matching provider in `clients/opencode/opencode.json`, then `make install` + restart + `make status`.
3. **Tune thermal watchdog thresholds**: edit `WARN_TEMP`/`CRIT_TEMP`/`HOLD` in `bin/gpu-guard:12-14` (or override via `GPU_GUARD_WARN_TEMP`/`GPU_GUARD_CRIT_TEMP`/`GPU_GUARD_HOLD` env in the unit), redeploy with `make install-system`, validate with `journalctl --user -u gpu-guard.service -f` under sustained load.
4. **Add a new `make` target**: follow the existing pattern `@ssh $(REMOTE) /home/lucas/.local/bin/<script> <args>` for remote operations; if it invokes a new `bin/` script, add its `scp` to `scripts/install.sh`.

## Do NOT touch

- `AI_CONTEXT.md` is a pre-existing PT-BR bootstrap doc (Intellissis repo convention) — it is not superseded by this file; keep both in sync when architecture changes, don't delete it.
- `.specstory/` — SpecStory session history, auto-managed, gitignored.
- `.claude/settings.local.json` — local Claude Code permission allowlist, gitignored, machine-specific.
- Model binaries and GGUF weight files — never live in this repo; they're provisioned manually on Ancalagon/Glaurung per MANUTENCAO.md "Dependências e integrações".
