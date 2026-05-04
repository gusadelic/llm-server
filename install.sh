#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ Error on line $LINENO"; exit 1' ERR

# ===== Config =====
WORKDIR="${WORKDIR:-$HOME/llm}"
MODEL_DIR="${MODEL_DIR:-$WORKDIR/models/qwen3.6}"
BIN_EXPORT_DIR="${BIN_EXPORT_DIR:-$WORKDIR/bin}"
LOG_FILE="${LOG_FILE:-$WORKDIR/llama-server.log}"
INSTANCE_FILE="$WORKDIR/.instance_id"

RELEASE_URL="${RELEASE_URL:-https://github.com/gusadelic/llm-server/releases/download/v0.1.0/llama-bin.zip}"

MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.6-35B-A3B-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-F16.gguf}"

PORT="${PORT:-8080}"
HOST="0.0.0.0"

mkdir -p "$WORKDIR" "$MODEL_DIR" "$BIN_EXPORT_DIR"

# ===== Spinner Setup =====
if [ -t 1 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi

if locale charmap 2>/dev/null | grep -qi utf-8; then
  SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  SPINNER_CHARS=('|' '/' '-' '\')
fi

spin_i=0
spin_char() {
  spin_i=$(( (spin_i + 1) % ${#SPINNER_CHARS[@]} ))
  printf "%s" "${SPINNER_CHARS[$spin_i]}"
}

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

update_line() {
  if [ "$INTERACTIVE" = "1" ]; then
    printf "\r\033[K${CYAN}%-55s${RESET} %s" "$1" "$(spin_char)"
  else
    echo "$1..."
  fi
}

finish_line() {
  if [ "$INTERACTIVE" = "1" ]; then
    printf "\r\033[K${GREEN}%-55s ✓${RESET}\n" "$1"
  else
    echo "$1 ✓"
  fi
}

fail_line() {
  if [ "$INTERACTIVE" = "1" ]; then
    printf "\r\033[K${RED}%-55s ✗${RESET}\n" "$1"
  else
    echo "$1 ✗"
  fi
}

# ===== Dependencies =====
install_deps() {
  echo "Step: install_deps"
  sudo apt-get update
  sudo apt-get install -y git curl unzip python3 python3-pip
}

# ===== Instance ID =====
load_instance_id() {
  if [ -f "$INSTANCE_FILE" ]; then
    INSTANCE_ID="$(cat "$INSTANCE_FILE")"
  fi
}

save_instance_id() {
  if [ -n "${INSTANCE_ID:-}" ]; then
    echo "$INSTANCE_ID" > "$INSTANCE_FILE"
  fi
}

prompt_instance_id() {
  load_instance_id

  if [ -n "${INSTANCE_ID:-}" ]; then
    echo "Using saved instance ID: $INSTANCE_ID"
    return
  fi

  if [ ! -t 0 ]; then return; fi

  echo ""
  echo "🌐 ThunderCompute setup (optional)"
  echo "Expose port $PORT in UI to access externally"
  echo ""

  read -r -p "Enter instance ID (or press Enter for localhost): " INSTANCE_ID || true
  save_instance_id
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
    pip3 install --user -U huggingface_hub || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

# ===== Binaries =====
download_binaries() {
  if [ -x "$BIN_EXPORT_DIR/llama-server" ]; then
    echo "Binaries already present."
    return
  fi

  echo "Downloading binaries..."
  curl -L --fail "$RELEASE_URL" -o /tmp/llama.zip
  unzip -o /tmp/llama.zip -d "$BIN_EXPORT_DIR"

  if [ -d "$BIN_EXPORT_DIR/llm/bin" ]; then
    mv "$BIN_EXPORT_DIR/llm/bin/"* "$BIN_EXPORT_DIR/" || true
    rm -rf "$BIN_EXPORT_DIR/llm"
  fi

  install_libs
}

install_libs() {
  sudo cp "$BIN_EXPORT_DIR"/lib*.so* /usr/local/lib/ || true

  for lib in "$BIN_EXPORT_DIR"/lib*.so.*; do
    if [ -e "$lib" ]; then
      base=$(basename "$lib")
      name="${base%%.so.*}"
      sudo ln -sf "$base" "/usr/local/lib/${name}.so"
    fi
  done

  sudo ldconfig
}

# ===== Models =====
ensure_models() {
  if [ ! -f "$MODEL_DIR/$MODEL_FILE" ]; then
    hf download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODEL_DIR"
  fi

  if [ ! -f "$MODEL_DIR/$MMPROJ_FILE" ]; then
    hf download "$MODEL_REPO" "$MMPROJ_FILE" --local-dir "$MODEL_DIR"
  fi
}

# ===== Server =====
start_server() {
  export LD_LIBRARY_PATH="$BIN_EXPORT_DIR:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

  nohup "$BIN_EXPORT_DIR/llama-server" \
    --host "$HOST" \
    --port "$PORT" \
    --model "$MODEL_DIR/$MODEL_FILE" \
    --mmproj "$MODEL_DIR/$MMPROJ_FILE" \
    >"$LOG_FILE" 2>&1 &
}

# ===== Wait =====
wait_for_server() {
  BASE_URL="$(get_base_url)"

  echo ""

  msg="[1/4] Starting server process..."
  for i in {1..6}; do update_line "$msg"; sleep 0.15; done
  finish_line "$msg"

  msg="[2/4] Waiting for port $PORT..."
  for i in {1..20}; do
    if ss -tuln | grep -q ":$PORT"; then finish_line "$msg"; break; fi
    update_line "$msg"; sleep 0.3
  done

  msg="[3/4] Loading model..."
  for i in {1..120}; do
    if grep -qi "model loaded\|server listening" "$LOG_FILE" 2>/dev/null; then
      finish_line "$msg"; break
    fi
    update_line "$msg"; sleep 1
  done

  msg="[4/4] Checking API..."
  for i in {1..30}; do
    if curl -s "$BASE_URL/models" >/dev/null 2>&1; then
      finish_line "$msg"
      echo -e "${GREEN}🚀 Server ready!${RESET}"
      return
    fi
    update_line "$msg"; sleep 0.3
  done

  fail_line "$msg"
}

# ===== Instructions =====
print_instructions() {
  BASE_URL="$(get_base_url)"

  echo ""
  echo "=============================================="
  echo "🚀 LLM Server Ready"
  echo "=============================================="
  echo "Base URL: $BASE_URL"
  echo "Model: $(basename "$MODEL_FILE")"
  echo ""
  echo "Start:   (already running)"
  echo "Stop:    pkill -f llama-server"
  echo "Logs:    tail -f $LOG_FILE"
  echo ""
}

# ===== Run =====
install_deps
ensure_hf_cli
download_binaries
ensure_models

prompt_instance_id
build_public_url

pkill -f llama-server || true

start_server
wait_for_server
print_instructions
