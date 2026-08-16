# ancalagon-llm

Operational setup for **Ancalagon** (Ubuntu Server 24.04, dual-boot with Windows) as a dedicated local LLM server, tuned for an RTX 4070 Ti SUPER (16 GB VRAM). Replaces LM Studio with native `llama.cpp` controlled by systemd, exposing four mutually-exclusive model presets — Qwen3-Coder 30B (MoE, upstream), Qwen3.6-27B (TQ3 ternary quant, `turbo-tan/llama.cpp-tq3` fork), Qwen3.8-27B (IQ3_M, same fork) and Gemma 4 26B-A4B-it (MoE, upstream) — all on the same OpenAI-compatible port so existing clients don't need to change URLs. Consumed from a Mac (Glaurung) over Tailscale.

## Motivation

LM Studio was leaving roughly half the achievable tok/s on the table: ~30-34% GPU utilization and ~70W (of a 285W TGP budget) during inference. Two bottlenecks:

1. **Generic partial offload** — LM Studio only lets you push "N% of layers to GPU". For a MoE model that's suboptimal: what matters is keeping attention/norm on GPU and experts on CPU. `llama.cpp`'s `--n-cpu-moe` flag does exactly that; LM Studio doesn't expose it.
2. **Model larger than VRAM** — Qwen3.6-27B at Q4_K_M is 17 GB. With TQ3_4S (3-bit ternary quant, `turbo-tan/llama.cpp-tq3` fork) it drops to 13 GB and fits 100% in GPU. Measured effect: GPU util 34% → 96%, power 94W → 292W, throughput 13.7 → 36.8 tok/s.

### Measured gains

| Config | GPU util | Power | tok/s gen | pp tok/s |
|---|---|---|---|---|
| LM Studio — qwen3-coder Q4_K_M, offload 0.80 | 30% | 67W | 64.5 | ~850 |
| **llama-server upstream — qwen3-coder `-ncmoe 10`** | 36% | 101W | **81.5** | **~1850** |
| LM Studio — qwen3.6-27b Q4_K_M, offload 0.85 | 34% | 94W | 13.7 | ? |
| **llama-server TQ3 fork — Qwen3.6-27B-TQ3_4S** | **96%** | **292W** | **36.8** | **1266** |

Cross-machine over Tailscale: 96.4 tok/s gen on the coder preset, 255ms round-trip on small prompts. Raw benchmark methodology and data live in [`benchmarks/`](benchmarks/README.md).

## Architecture

```
Glaurung (Mac)                    Ancalagon-Ubuntu
                                  (Tailscale / LAN)
aliases:                          systemd --user:
  llcoder  ──────ssh─────▶        llama-coder.service ──┐
  llq36    ──────ssh─────▶        llama-qwen36.service ─┤
  (make qwen38) ─────────▶        llama-qwen38.service ─┤
  llgemma4 ──────ssh─────▶        llama-gemma4.service ─┼─ Conflicts=
  lloff    ──────ssh─────▶        (lmstudio.service    ─┘  (only one up)
  llstatus ──────ssh─────▶        + disabled)
                                       │
                                       ▼
                                  :1234 (OpenAI-compatible API)
                                       ▲
curl http://<ancalagon-tailscale-ip>:1234 ─┘
```

Port **1234** is the same one LM Studio used to bind, so existing clients keep working unmodified. The four `llama-*.service` units declare `Conflicts=` against each other and against `lmstudio.service`, so systemd guarantees only one is ever running — no manual stop/start choreography, no risk of two models fighting over the same 16 GB of VRAM.

## Stack / Requirements

- Bash (systemd wrapper scripts, `set -euo pipefail`)
- `llama.cpp` compiled with CUDA (sm_89) — upstream and the `turbo-tan/llama.cpp-tq3` fork, both built out-of-repo on Ancalagon
- systemd `--user` units (Ancalagon side)
- `curl`, `jq` for health probes and JSON handling
- Tailscale (or LAN) connectivity between the Mac client and Ancalagon
- macOS client tooling: `opencode` (or `local-claude`) to consume the OpenAI-compatible endpoint

## Installation

Prerequisites already present on Ancalagon (not managed by this repo — see [MANUTENCAO.md](MANUTENCAO.md) "Dependências e integrações"):
- `~/git/llama.cpp/build/bin/llama-server` compiled with CUDA sm_89
- `~/git/llama.cpp-tq3/build/bin/llama-server` (TQ3 fork, same flags)
- GGUF model files in `~/.lmstudio/models/…` and `~/models/gguf/…`

From the Mac (this repo's checkout):

```bash
# Deploy systemd units + lmswitch/videoswitch/bootwin wrappers to Ancalagon
make install

# One-time system prerequisites for `lmswitch sleep` (WoL, nvidia-suspend, console font)
make install-system

# Optional: install the `gla` local-backend wrapper on the Mac itself
make install-gla

# Optional: install the delegando-ancalagon Claude Code skill on the Mac
make install-skill
```

Services are **not enabled by default** — a clean boot starts nothing; you invoke a preset on demand. See [`scripts/install.sh`](scripts/install.sh) and [`scripts/setup-system.sh`](scripts/setup-system.sh) for exactly what gets copied/configured.

## How to run

```bash
make coder     # start Qwen3-Coder-30B (MoE, --n-cpu-moe 16, ctx 96K)
make qwen36    # start Qwen3.6-27B-TQ3_4S (100% GPU, ctx 40K)
make qwen38    # start Qwen3.8-27B-IQ3_M (100% GPU, ctx 40K)
make gemma4    # start Gemma 4 26B-A4B-it (MoE, --n-cpu-moe 8, ctx 96K)
make off       # stop whichever preset is active
make sleep     # stop + suspend the whole machine (wake via WoL)
make status    # service states + health probe on :1234
make logs      # tail the journal of the active preset
```

Equivalent aliases from the Mac's `.zshrc` (`llcoder`, `llq36`, `llgemma4`, `lloff`, `llsleep`, `llstatus`, `lllogs`) wrap the same `ssh … lmswitch <subcommand>` calls — see [MANUTENCAO.md](MANUTENCAO.md) for the full list and the `srl-coder`/`srl-tq` Claude Code entry points.

Typical flow:

```zsh
llcoder && srl-coder   # code work, MoE, ~80 tok/s
llq36 && srl-tq        # reasoning-heavy work, TQ3, ~37 tok/s, 100% GPU
lloff                  # free the GPU, machine stays up
llsleep                # suspend the whole box (wakes via Wake-on-LAN)
```

### Dual-boot (Windows)

The machine dual-boots Windows; the UEFI default is Ubuntu, so a normal reboot always lands on Ubuntu. Two one-shot `BootNext` helpers cross over (both revert after that single boot):

```zsh
anc_bootwin        # from Ubuntu → next boot is Windows (runs bootwin → efibootmgr -n)
anc_win_bootwin    # from Windows → next boot STAYS on Windows instead of falling back to Ubuntu
anc_win_restart    # from Windows → normal reboot, lands on Ubuntu (the default)
```

`anc_win_bootwin` runs `bcdedit /set {fwbootmgr} bootsequence {bootmgr}` + reboot over SSH (`$ANC_WIN` Tailnet; `anc_win_bootwin_lan` uses the direct LAN path). The same logic lives locally on Windows as `bootwin` (`C:\Users\lucas\bin\bootwin.cmd`, supports `--dry-run`). The `lucas@` SSH session on Windows is already elevated, so `bcdedit` runs headless.

## Folder structure

```
bin/                    lmswitch, gpu-guard, videoswitch, bootwin — the operational wrapper scripts
systemd/                llama-{coder,qwen36,qwen38,gemma4}.service, gpu-guard.service, 99-wol.yaml, console-setup
scripts/                install.sh (deploy), setup-system.sh (WoL/nvidia-suspend/console prerequisites), build-llama.sh
clients/glaurung-llm/   gla — Mac-side backend switcher (llama.cpp Metal / MLX) + TUNING.md
clients/opencode/       opencode.json template + README for wiring opencode to Ancalagon/Glaurung backends
skills/delegando-ancalagon/  Claude Code skill + anc-delegate — headless delegation from cloud Claude to Ancalagon
benchmarks/             TUNING.md, POWER.md — raw empirical data behind the current flags
docs/                   delegation.md (cloud↔Ancalagon charter), console-setup.md, handoff-llm-local-8gb.md
Makefile                all `make <target>` entry points, thin wrappers around ssh + the bin/ scripts
```

## Documentation related

- [MANUTENCAO.md](MANUTENCAO.md) — maintenance guide (architecture, where things live, change recipes)
- [AGENTS.md](AGENTS.md) — dense map for LLM agents (file map, symbol index, commands, constraints)
- [CLAUDE.md](CLAUDE.md) — Claude Code specific notes (commands, gotchas, commit/push)
- [AI_CONTEXT.md](AI_CONTEXT.md) — one-page PT-BR bootstrap for a fresh assistant session (Intellissis convention)
- [docs/delegation.md](docs/delegation.md) — charter for delegating work from cloud Claude to Ancalagon
- [docs/handoff-llm-local-8gb.md](docs/handoff-llm-local-8gb.md) — handoff guide for replicating this setup on 8 GB AMD hardware (PT-BR)

## License

MIT — see [LICENSE](LICENSE).
