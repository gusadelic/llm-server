#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
WORKDIR="${WORKDIR:-$HOME/llm}"
LLAMA_DIR="${LLAMA_DIR:-$WORKDIR/llama.cpp}"
MODEL_DIR="${MODEL_DIR:-$WORKDIR/models/qwen3.6}"
BIN_EXPORT_DIR="${BIN_EXPORT_DIR:-$WORKDIR/bin}"
LOG_FILE="${LOG_FILE:-$WORKDIR/llama-server.log}"

RELEASE_URL="${RELEASE_URL:-https://github.com/gusadelic/llm-server/releases/download/v0.1.0/llama-bin.zip}"

MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.6-35B-A3B-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-F16.gguf}"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"

CTX_SIZE="${CTX_SIZE:-262144}"
N_PREDICT="${N_PREDICT:-32768}"

mkdir -p "$WORKDIR" "$MODEL_DIR" "$BIN_EXPORT_DIR"

# ===== Dependencies =====
install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    SUDO=""
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo"; fi
    $SUDO apt-get update
    $SUDO apt-get install -y git curl unzip python3 python3-pip
  else
    echo "Unsupported package manager." >&2
    exit 1
  fi
}

# ===== ThunderCompute CLI =====
install_tnr_cli() {
  if command -v tnr >/dev/null 2>&1; then return; fi

  echo "Attempting to install ThunderCompute CLI..."
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --user thundercompute >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

try_expose_port() {
  if command -v tnr >/dev/null 2>&1; then
    echo "Attempting to expose port $PORT..."
    tnr ports add "$PORT" >/dev/null 2>&1 || true
  fi
}

detect_instance_id() {
  if ! command -v tnr >/dev/null 2>&1; then return; fi
  tnr status 2>/dev/null | awk 'NR==2 {print $2}'
}

prompt_instance_id() {
  INSTANCE_ID="$(detect_instance_id || true)"

  if [ -n "${INSTANCE_ID:-}" ]; then
    echo "Detected instance ID: $INSTANCE_ID"
    return
  fi

  echo ""
  read -r -p "Enter ThunderCompute instance ID (or press Enter to skip): " INSTANCE_ID
}

build_public_url() {
  if [ -n "${INSTANCE_ID:-}" ]; then
    PUBLIC_BASE_URL="https://${INSTANCE_ID}-${PORT}.thundercompute.net"
  else
    PUBLIC_BASE_URL="http://localhost:${PORT}"
  fi
}

get_base_url() {
  echo "${PUBLIC_BASE_URL}/v1"
}

# ===== HuggingFace =====
ensure_hf_cli() {
  if ! command -v hf >/dev/null 2>&1; then
    python3 -m pip install --user -U huggingface_hub
  fi
}

# ===== Download binaries =====
download_binaries() {
  if [ -x "$BIN_EXPORT_DIR/llama-server" ]; then
    echo "Binaries already present."
    return
  fi

  echo "Downloading prebuilt binaries..."
  curl -L --fail "$RELEASE_URL" -o /tmp/llama-bin.zip
  unzip -o /tmp/llama-bin.zip -d "$BIN_EXPORT_DIR"

  # Fix nested zip structure
  if [ -d "$BIN_EXPORT_DIR/llm/bin" ]; then
    mv "$BIN_EXPORT_DIR/llm/bin/"* "$BIN_EXPORT_DIR/"
    rm -rf "$BIN_EXPORT_DIR/llm"
  fi

  install_shared_libs
  fix_library_symlinks
}

# ===== Install libs =====
install_shared_libs() {
  local SUDO=""
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo"; fi

  echo "Installing shared libraries..."
  $SUDO cp "$BIN_EXPORT_DIR"/lib*.so* /usr/local/lib/ || true
  $SUDO ldconfig
}

fix_library_symlinks() {
  local SUDO=""
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo"; fi

  for lib in "$BIN_EXPORT_DIR"/lib*.so.*; do
    [ -e "$lib" ] || continue
    base=$(basename "$lib")
    name="${base%%.so.*}"
    $SUDO ln -sf "$base" "/usr/local/lib/${name}.so"
  done
}

# ===== Models =====
ensure_models() {
  [ -f "$MODEL_DIR/$MODEL_FILE" ] || hf download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODEL_DIR"
  [ -f "$MODEL_DIR/$MMPROJ_FILE" ] || hf download "$MODEL_REPO" "$MMPROJ_FILE" --local-dir "$MODEL_DIR"
}

# ===== Instructions =====
print_openai_instructions() {
  BASE_URL="$(get_base_url)"

  echo ""
  echo "=============================================="
  echo "🚀 LLM Server Ready"
  echo "=============================================="
  echo ""
  echo "Use in Cline / Codex:"
  echo ""
  echo "Provider: OpenAI Compatible"
  echo "Base URL: $BASE_URL"
  echo "API Key:  anything"
  echo "Model:    $(basename "$MODEL_FILE")"
  echo ""
  echo "Logs:"
  echo "  tail -f $LOG_FILE"
  echo ""
  echo "Test:"
  echo "  curl $BASE_URL/models"
  echo ""
  echo "=============================================="
}

check_port_message() {
  echo ""
  echo "⚠️  If connection fails:"
  echo "   Ensure port $PORT is exposed in ThunderCompute UI"
  echo ""
}

# ===== Start server =====
start_server() {
  echo ""
  echo "Starting llama-server..."
  echo "Logs: $LOG_FILE"

  mkdir -p "$(dirname "$LOG_FILE")"
  export LD_LIBRARY_PATH="$BIN_EXPORT_DIR:${LD_LIBRARY_PATH:-}"

  nohup "$BIN_EXPORT_DIR/llama-server" \
    --host "$HOST" \
    --port "$PORT" \
    --model "$MODEL_DIR/$MODEL_FILE" \
    --mmproj "$MODEL_DIR/$MMPROJ_FILE" \
    --ctx-size "$CTX_SIZE" \
    --n-predict "$N_PREDICT" \
    >"$LOG_FILE" 2>&1 &

  sleep 2
}

# ===== Run =====
install_deps
install_tnr_cli
ensure_hf_cli

download_binaries
ensure_models

try_expose_port
prompt_instance_id
build_public_url

start_server

check_port_message
print_openai_instructions
