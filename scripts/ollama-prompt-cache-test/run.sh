#!/usr/bin/env bash
# Builds ollama's per-model prompt_cache branch (jzila/ollama
# per-model-prompt-cache) on Apple Silicon and checks it on both runners:
# llama-server (a GGUF model) and MLX (a safetensors model).
#
# Run on the macbook:
#   nix run .#ollama-prompt-cache-test
#
# Everything lives under $OLLAMA_PC_DIR (default ~/src/ollama-prompt-cache):
# the checkout, its own model store and the server log. The server listens
# on 127.0.0.1:11435 and is stopped on exit, so nothing else on the machine
# changes. Needs Xcode with the Metal toolchain for MLX; the script says how
# to install it if it's missing.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${OLLAMA_PC_DIR:-$HOME/src/ollama-prompt-cache}
repo=https://github.com/jzila/ollama.git
branch=per-model-prompt-cache
# A small model on each runner: Qwen3-0.6B as GGUF from ollama's library
# (llama-server) and as safetensors from Hugging Face (MLX).
gguf=qwen3:0.6b
hf=Qwen/Qwen3-0.6B
hfRev=c1899de289a04d12100db370d81485cdf75e47ca

[ "$(uname -s)" = Darwin ] || { echo "This test is for macOS (MLX)." >&2; exit 1; }
if ! xcrun -f metal >/dev/null 2>&1; then
  cat >&2 <<'MSG'
The MLX build needs Xcode's Metal toolchain, which Nix can't provide:
  1. Install Xcode from the App Store and open it once.
  2. sudo xcode-select -s /Applications/Xcode.app
  3. xcodebuild -downloadComponent MetalToolchain
Then run this again.
MSG
  exit 1
fi

mkdir -p "$work"
cd "$work"

echo "== Checkout ($repo $branch)"
[ -d src/.git ] || git clone --quiet "$repo" src
git -C src fetch --quiet origin "$branch"
git -C src checkout --quiet -B "$branch" "origin/$branch"
git -C src log -1 --format='   %h %s'

echo "== Build"
# The branch pins a newer Go than nixpkgs has; let Go fetch that toolchain.
export GOTOOLCHAIN=auto
# MLX's Metal sources take a lot of memory each to compile; at Ninja's
# default of cores + 2 jobs a 24 GB macbook ran out.
export CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL:-6}
if ! { cmake -S src -B src/build -G Ninja && cmake --build src/build; } >build.log 2>&1; then
  tail -40 build.log
  echo "Build failed; full log: $work/build.log" >&2
  exit 1
fi

# ollama finds its MLX library under ./build, so run it from the checkout.
cd src
echo "== Server (127.0.0.1:11435, log: $work/serve.log)"
export OLLAMA_HOST=127.0.0.1:11435 OLLAMA_MODELS=$work/models
# One model at a time, so each variant gets a fresh runner.
OLLAMA_DEBUG=1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_KEEP_ALIVE=10m \
  ./ollama serve >"$work/serve.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null' EXIT
until curl -fs "http://$OLLAMA_HOST/api/version" >/dev/null; do
  kill -0 $server 2>/dev/null || { tail -20 "$work/serve.log"; exit 1; }
  sleep 1
done

echo "== Models"
./ollama pull "$gguf" >/dev/null
mkdir -p "$work/hf"
for f in config.json generation_config.json merges.txt model.safetensors \
  tokenizer.json tokenizer_config.json vocab.json; do
  [ -s "$work/hf/$f" ] || curl -fsSL -o "$work/hf/$f" "https://huggingface.co/$hf/resolve/$hfRev/$f"
done

# Variants per runner: prompt_cache unset (today's default), 0 and 2048.
for runner in gguf mlx; do
  from=$gguf
  [ $runner = mlx ] && from=$work/hf
  for c in unset 0 2048; do
    {
      echo "FROM $from"
      echo "PARAMETER num_ctx 32768"
      [ $c = unset ] || echo "PARAMETER prompt_cache $c"
    } >"$work/Modelfile"
    ./ollama create "pc-$runner-$c" -f "$work/Modelfile" >/dev/null
  done
done

echo "== Checks"
python3 -I "$here/check.py" "$work/serve.log"
