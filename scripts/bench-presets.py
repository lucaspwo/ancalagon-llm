#!/usr/bin/env python3
"""A/B bench dos presets do Ancalagon. Roda NO Ancalagon (localhost:1234).

Uso: bench-presets.py LABEL preset [preset...]
  ex.: scp scripts/bench-presets.py Anc_U-T:~ && ssh Anc_U-T 'python3 ~/bench-presets.py before coder gemma4'
Sobe cada preset via lmswitch, mede decode (prompt canônico, 4 runs, 1º descartado)
e prefill (prompt ~2.1K tokens, cache_prompt=false; só presets llama.cpp). Imprime uma
linha JSON por preset e grava ~/bench-LABEL.json. Desliga o preset ao final.
Método e números de referência em benchmarks/TUNING.md § 16.
"""
import json
import subprocess
import sys
import time
import urllib.request

URL = "http://localhost:1234"
LMSWITCH = "/home/lucas/.local/bin/lmswitch"
CANON = "Explain quantum entanglement in 5 paragraphs."
MAX_TOKENS = 400
RUNS = 4
LONG_PROMPT = " ".join(
    f"Paragraph {i}: The quick brown fox jumps over the lazy dog while the "
    f"engineer measures throughput of a local language model server." for i in range(80)
) + "\nSummarize the text above in one sentence."


def post(path, payload, timeout=600):
    req = urllib.request.Request(URL + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.load(r)
    return body, time.monotonic() - t0


def vram_mib():
    out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                         capture_output=True, text=True, check=True).stdout
    return int(out.strip())


def model_id():
    with urllib.request.urlopen(URL + "/v1/models", timeout=30) as r:
        return json.load(r)["data"][0]["id"]


def decode_run(seed):
    # Colibri responde 404 model_not_found sem "model"; o llama-server ignora o campo.
    body, dt = post("/v1/chat/completions", {
        "model": model_id(),
        "messages": [{"role": "user", "content": CANON}],
        "max_tokens": MAX_TOKENS, "temperature": 0, "seed": seed, "cache_prompt": False,
    })
    n = body["usage"]["completion_tokens"]
    # Só confia em timings no formato do llama-server; o Colibri tem outro formato
    # (tokens_per_sec) e hoje não o devolve nesta rota — cai no tempo de parede.
    t = body.get("timings") or {}
    tps = t["predicted_per_second"] if "predicted_per_second" in t else n / dt
    return round(tps, 2), n


def prefill_run():
    body, _ = post("/v1/chat/completions", {
        "messages": [{"role": "user", "content": LONG_PROMPT}],
        "model": model_id(), "max_tokens": 8, "temperature": 0, "cache_prompt": False,
    })
    t = body.get("timings") or {}
    if "prompt_per_second" not in t:
        return None, None
    return round(t["prompt_per_second"], 1), t["prompt_n"]


def bench(preset):
    subprocess.run([LMSWITCH, preset], check=True, stdout=subprocess.DEVNULL)
    runs = [decode_run(i) for i in range(RUNS)][1:]
    tps = [r[0] for r in runs]
    res = {"preset": preset, "decode": round(sum(tps) / len(tps), 2), "decode_runs": tps,
           "tokens": [r[1] for r in runs], "vram_mib": vram_mib()}
    if preset != "colibri":
        prefill_run()  # aquecimento
        res["prefill"], res["prompt_n"] = prefill_run()
    return res


def main():
    label, presets = sys.argv[1], sys.argv[2:]
    results = []
    for p in presets:
        r = bench(p)
        print(json.dumps(r), flush=True)
        results.append(r)
    subprocess.run([LMSWITCH, "off"], check=True, stdout=subprocess.DEVNULL)
    with open(f"/home/lucas/bench-{label}.json", "w") as f:
        json.dump({"label": label, "kernel": subprocess.run(["uname", "-r"], capture_output=True,
                   text=True).stdout.strip(), "results": results}, f, indent=1)


if __name__ == "__main__":
    main()
