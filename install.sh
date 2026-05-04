#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
WORKDIR="${WORKDIR:-$HOME/llm}"
LLAMA_DIR="${LLAMA_DIR:-$WORKDIR/llama.cpp}"
MODEL_DIR="${MODEL_DIR:-$WORKDIR/models/qwen3.6}"
STAMP_FILE="${STAMP_FILE:-$LLAMA_DIR/build/.llama_cpp_commit}"
BIN_EXPORT_DIR="${BIN_EXPORT_DIR:-$WORKDIR/bin}"

# 🔥 Release URL (NEW)
RELEASE_URL="${RELEASE_URL:-https://github.com/gusadelic/llm-server/releases/download/v0.1.0/llama-bin.zip}"

MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.6-35B-A3B-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-F16.gguf}"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"

CTX_SIZE="${CTX_SIZE:-262144}"
N_PREDICT="${N_PREDICT:-32768}"

MODE="${MODE:-code}"
CUDA_ARCHS="${CUDA_ARCHS:-}"

mkdir -p "$WORKDIR" "$MODEL_DIR" "$BIN_EXPORT_DIR"

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
      python3 python3-pip curl unzip
  else
    echo "Unsupported package manager." >&2
    exit 1
  fi
}

ensure_hf_cli() {
  if ! command -v hf >/dev/null 2>&1; then
    python3 -m pip install --user -U huggingface_hub
  fi
}

# 🔥 NEW: Download binaries from release
download_binaries() {
  if [ -x "$BIN_EXPORT_DIR/llama-server" ]; then
    echo "Binaries already present."
    return 0
  fi

  echo "Downloading prebuilt binaries..."
  mkdir -p "$BIN_EXPORT_DIR"

  if curl -L --fail "$RELEASE_URL" -o /tmp/llama-bin.zip; then
    unzip -o /tmp/llama-bin.zip -d "$BIN_EXPORT_DIR"
    echo "Binaries downloaded successfully."
    return 0
  else
    echo "Download failed."
    return 1
  fi
}

export_binaries() {
  echo "Exporting binaries to $BIN_EXPORT_DIR"
  rm -rf "$BIN_EXPORT_DIR"/*
  cp -r "$LLAMA_DIR/build/bin/"* "$BIN_EXPORT_DIR/"
  cp "$STAMP_FILE" "$BIN_EXPORT_DIR/.llama_cpp_commit"
}

ensure_llama_cpp() {
  if [ -d "$LLAMA_DIR/.git" ]; then
    git -C "$LLAMA_DIR" pull --rebase
  else
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  fi

  local new_commit
  new_commit="$(git -C "$LLAMA_DIR" rev-parse HEAD)"

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

  # 🔥 Try downloading first
  download_binaries || true

  # 🔁 Fallback to build
  if [ ! -x "$BIN_EXPORT_DIR/llama-server" ]; then
    echo "No binaries available. Building..."
    cmake "${cmake_args[@]}"
    cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"
    printf '%s\n' "$new_commit" > "$STAMP_FILE"
    export_binaries
  else
    echo "Using prebuilt binaries."
  fi
}

ensure_models() {
  local model_path="$MODEL_DIR/$MODEL_FILE"
  local mmproj_path="$MODEL_DIR/$MMPROJ_FILE"

  [ -f "$model_path" ] || hf download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODEL_DIR"
  [ -f "$mmproj_path" ] || hf download "$MODEL_REPO" "$MMPROJ_FILE" --local-dir "$MODEL_DIR"
}

start_server() {
  exec "$BIN_EXPORT_DIR/llama-server" \
    --host "$HOST" \
    --port "$PORT" \
    --model "$MODEL_DIR/$MODEL_FILE" \
    --mmproj "$MODEL_DIR/$MMPROJ_FILE" \
    --ctx-size "$CTX_SIZE" \
    --n-predict "$N_PREDICT"
}

install_deps
ensure_hf_cli
ensure_llama_cpp
ensure_models
start_server
