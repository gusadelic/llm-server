#!/usr/bin/env bash
set -euo pipefail

# One-script bootstrap + launch for Qwen3.6 on llama.cpp.

# ===== Config =====
WORKDIR="${WORKDIR:-$HOME/llm}"
LLAMA_DIR="${LLAMA_DIR:-$WORKDIR/llama.cpp}"
MODEL_DIR="${MODEL_DIR:-$WORKDIR/models/qwen3.6}"
STAMP_FILE="${STAMP_FILE:-$LLAMA_DIR/build/.llama_cpp_commit}"

# Default to the larger model; override for smaller instances if needed.
MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.6-35B-A3B-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-F16.gguf}"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"

# Qwen3.6 guide defaults
CTX_SIZE="${CTX_SIZE:-262144}"
N_PREDICT="${N_PREDICT:-32768}"

# instruct = non-thinking, thinking = reasoning mode, code = tighter coding settings
MODE="${MODE:-code}"

# Optional: set your GPU arch list, e.g. "86;89". Leave empty for portable CUDA build.
CUDA_ARCHS="${CUDA_ARCHS:-}"

mkdir -p "$WORKDIR" "$MODEL_DIR"

# ===== CUDA env requested by you =====
export PATH="/usr/local/cuda/bin${PATH:+:$PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$HOME/.local/bin${PATH:+:$PATH}"

prompt_yes_no() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply || true
  case "${reply:-}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    SUDO=""
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo"; fi
    $SUDO apt-get update
    $SUDO apt-get install -y \
      git cmake ninja-build build-essential pkg-config \
      python3 python3-pip
  elif command -v dnf >/dev/null 2>&1; then
    SUDO=""
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo"; fi
    $SUDO dnf install -y \
      git cmake ninja-build gcc gcc-c++ make pkgconf-pkg-config \
      python3 python3-pip
  elif command -v pacman >/dev/null 2>&1; then
    SUDO=""
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo"; fi
    $SUDO pacman -S --noconfirm \
      git cmake ninja base-devel pkgconf python python-pip
  else
    echo "Unsupported package manager. Install: git, cmake, ninja, build tools, python3, pip." >&2
    exit 1
  fi
}

ensure_hf_cli() {
  if ! command -v hf >/dev/null 2>&1; then
    python3 -m pip install --user -U huggingface_hub
  fi
}

ensure_llama_cpp() {
  if [ -d "$LLAMA_DIR/.git" ]; then
    old_commit="$(git -C "$LLAMA_DIR" rev-parse HEAD)"
    git -C "$LLAMA_DIR" pull --rebase
    new_commit="$(git -C "$LLAMA_DIR" rev-parse HEAD)"
  else
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
    old_commit=""
    new_commit="$(git -C "$LLAMA_DIR" rev-parse HEAD)"
  fi

  cmake_args=(
    -S "$LLAMA_DIR"
    -B "$LLAMA_DIR/build"
    -DGGML_CUDA=ON
    -DGGML_NATIVE=OFF
    -DCMAKE_BUILD_TYPE=Release
  )

  if [ -n "$CUDA_ARCHS" ]; then
    cmake_args+=(-DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHS")
  fi

  local server_bin="$LLAMA_DIR/build/bin/llama-server"

  if [ ! -x "$server_bin" ]; then
    echo "No llama-server build found. Building now..."
    cmake "${cmake_args[@]}"
    cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"
    printf '%s\n' "$new_commit" > "$STAMP_FILE"
    return
  fi

  local recorded_commit=""
  if [ -f "$STAMP_FILE" ]; then
    recorded_commit="$(cat "$STAMP_FILE" 2>/dev/null || true)"
  fi

  if [ "$old_commit" != "$new_commit" ] || [ "$recorded_commit" != "$new_commit" ]; then
    echo "Source code changed since the last recorded build."
    echo "Current commit: ${new_commit}"
    echo "Built commit:   ${recorded_commit:-unknown}"

    if prompt_yes_no "Rebuild llama.cpp now?"; then
      cmake "${cmake_args[@]}"
      cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"
      printf '%s\n' "$new_commit" > "$STAMP_FILE"
    else
      echo "Using the existing build."
    fi
  fi
}

ensure_models() {
  local model_path="$MODEL_DIR/$MODEL_FILE"
  local mmproj_path="$MODEL_DIR/$MMPROJ_FILE"

  if [ ! -f "$model_path" ]; then
    hf download "$MODEL_REPO" "$MODEL_FILE" \
      --local-dir "$MODEL_DIR"
  fi

  if [ ! -f "$mmproj_path" ]; then
    hf download "$MODEL_REPO" "$MMPROJ_FILE" \
      --local-dir "$MODEL_DIR"
  fi
}

start_server() {
  local server_bin="$LLAMA_DIR/build/bin/llama-server"
  local model_path="$MODEL_DIR/$MODEL_FILE"
  local mmproj_path="$MODEL_DIR/$MMPROJ_FILE"

  if [ ! -x "$server_bin" ]; then
    echo "llama-server is missing: $server_bin" >&2
    exit 1
  fi

  if [ ! -f "$model_path" ]; then
    echo "Missing model file: $model_path" >&2
    exit 1
  fi

  if [ ! -f "$mmproj_path" ]; then
    echo "Missing mmproj file: $mmproj_path" >&2
    exit 1
  fi

  SAMPLING_ARGS=(--ctx-size "$CTX_SIZE" --n-predict "$N_PREDICT")

  case "$MODE" in
    thinking)
      SAMPLING_ARGS+=(--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 1.5 --repeat-penalty 1.0)
      ;;
    code)
      SAMPLING_ARGS+=(--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0 --repeat-penalty 1.0)
      ;;
    instruct|*)
      SAMPLING_ARGS+=(--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 --presence-penalty 1.5 --repeat-penalty 1.0 --chat-template-kwargs '{"enable_thinking":false}')
      ;;
  esac

  exec "$server_bin" \
    --host "$HOST" \
    --port "$PORT" \
    --model "$model_path" \
    --mmproj "$mmproj_path" \
    "${SAMPLING_ARGS[@]}"
}

install_deps
ensure_hf_cli
ensure_llama_cpp
ensure_models
start_server

