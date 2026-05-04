#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/llm}"
LLAMA_DIR="${LLAMA_DIR:-$WORKDIR/llama.cpp}"
MODEL_DIR="${MODEL_DIR:-$WORKDIR/models/qwen3.6}"
STAMP_FILE="${STAMP_FILE:-$LLAMA_DIR/build/.llama_cpp_commit}"
BIN_EXPORT_DIR="${BIN_EXPORT_DIR:-$WORKDIR/bin}"

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
      git git-lfs cmake ninja-build build-essential pkg-config \
      python3 python3-pip unzip
  else
    echo "Unsupported package manager." >&2
    exit 1
  fi
}

ensure_git_lfs() {
  git lfs install --skip-repo
  git -C "$WORKDIR" lfs pull || true
}

ensure_hf_cli() {
  if ! command -v hf >/dev/null 2>&1; then
    python3 -m pip install --user -U huggingface_hub
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

  local recorded_commit=""
  if [ -f "$STAMP_FILE" ]; then
    recorded_commit="$(cat "$STAMP_FILE" 2>/dev/null || true)"
  elif [ -f "$BIN_EXPORT_DIR/.llama_cpp_commit" ]; then
    recorded_commit="$(cat "$BIN_EXPORT_DIR/.llama_cpp_commit" 2>/dev/null || true)"
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

  local exported_bin="$BIN_EXPORT_DIR/llama-server"

  if [ ! -x "$exported_bin" ]; then
    echo "No exported binaries found. Building..."
    cmake "${cmake_args[@]}"
    cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"
    printf '%s\n' "$new_commit" > "$STAMP_FILE"
    export_binaries
    return
  fi

  if [ "$recorded_commit" != "$new_commit" ]; then
    echo "llama.cpp updated."
    if prompt_yes_no "Rebuild binaries?"; then
      cmake "${cmake_args[@]}"
      cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"
      printf '%s\n' "$new_commit" > "$STAMP_FILE"
      export_binaries
    fi
  else
    echo "Binaries are up to date."
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
ensure_git_lfs
ensure_hf_cli
ensure_llama_cpp
ensure_models
start_server