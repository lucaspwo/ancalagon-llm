#!/usr/bin/env bash
# Build do llama-server com CUDA sm_89 (RTX 4070 Ti SUPER / Ada Lovelace).
# Roda NO Ancalagon. Uso: build-llama.sh {upstream|tq3}
set -euo pipefail

case "${1:-}" in
  upstream) REPO=/home/lucas/git/llama.cpp ;;
  tq3)      REPO=/home/lucas/git/llama.cpp-tq3 ;;
  *) echo "uso: $0 {upstream|tq3}" >&2; exit 1 ;;
esac

cd "$REPO"
# rm -rf build: cache do cmake envelhece mal entre sweeps grandes de upstream.
rm -rf build
# CMAKE_CUDA_COMPILER explícito: `ssh host build-llama.sh` não carrega
# /usr/local/cuda/bin no PATH e o cmake aborta com "No CMAKE_CUDA_COMPILER".
cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON
cmake --build build --config Release -j "$(nproc)" -t llama-server
echo "OK: $REPO/build/bin/llama-server"
