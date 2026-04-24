# benchmarks/

Dados empíricos coletados durante o tuning que resultou nos services deste repo.

- **TUNING.md** — análise consolidada: impacto de KV quant, sweep `-ncmoe`, ubatch, threads, TQ3 vs Q4_K_M.

Resumos vivem em `/Users/lucas/.claude/projects/-Users-lucas/memory/project_ancalagon_ubuntu.md` (memória Claude).

## Metodologia

- Prompt fixo: `"Explain quantum entanglement in 5 paragraphs."`, max_tokens=400, T=0.2 (determinístico dentro do possível)
- `llama-bench` com `-r 2` ou `-r 3` repetições para sweeps de parâmetros
- GPU telemetry: `nvidia-smi --query-gpu=utilization.gpu,power.draw -lms 100`
- Prompt processing medido via `timings` object na resposta OpenAI-compat do llama-server
- Baseline "GPU saturada": Qwen3.5-9B Q4_K_M 100% GPU → 91.7% util, 217W, 90 tok/s

## Scripts usados (reproduzíveis)

Não commitados aqui porque são one-shot — scripts em `/tmp/` do Mac e Ancalagon durante o tuning. Substituir por `llama-bench` direto para reproduzir:

```bash
# Sweep ncmoe em qwen3-coder
llama-bench \
  -m ~/.lmstudio/models/lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf \
  -p 0 -n 128 \
  -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -t 12 \
  -ncmoe 20,16,12,10,8 \
  -r 3

# Telemetry durante inference real
nvidia-smi --query-gpu=utilization.gpu,power.draw --format=csv,noheader,nounits -lms 100 > /tmp/gpu.csv &
curl -s http://localhost:1234/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"..."}],"max_tokens":400}' > /tmp/resp.json
kill %1
awk -F, 'NR>3 { g+=$1; p+=$2; n++ } END { printf "util=%.1f%% power=%.1fW (n=%d)\n", g/n, p/n, n }' /tmp/gpu.csv
```
