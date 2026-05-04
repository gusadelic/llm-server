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

# ===== Helpers =====
has_systemd() {
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

# ===== Dependencies =====
install_deps() {
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

  if [ ! -t 0 ]; then
    echo "Non-interactive mode, skipping instance ID."
    return
  fi

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
    echo "Installing HuggingFace CLI..."
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
  echo "Installing shared libraries..."

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

# ===== systemd =====
install_systemd_service() {
  SERVICE_FILE="/etc/systemd/system/llama-server.service"

  sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=llama.cpp Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$WORKDIR
Environment=LD_LIBRARY_PATH=$BIN_EXPORT_DIR
ExecStart=$BIN_EXPORT_DIR/llama-server \\
  --host $HOST \\
  --port $PORT \\
  --model $MODEL_DIR/$MODEL_FILE \\
  --mmproj $MODEL_DIR/$MMPROJ_FILE
Restart=always
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reexec
  sudo systemctl daemon-reload
  sudo systemctl enable llama-server
  sudo systemctl restart llama-server
}

# ===== Fallback server =====
start_background_server() {
  echo "Starting server (background mode)..."

  export LD_LIBRARY_PATH="$BIN_EXPORT_DIR:${LD_LIBRARY_PATH:-}"

  nohup "$BIN_EXPORT_DIR/llama-server" \
    --host "$HOST" \
    --port "$PORT" \
    --model "$MODEL_DIR/$MODEL_FILE" \
    --mmproj "$MODEL_DIR/$MMPROJ_FILE" \
    >"$LOG_FILE" 2>&1 &

  echo "Server started (PID $!)"
}

# ===== Health Check =====
wait_for_server() {
  BASE_URL="$(get_base_url)"

  for i in {1..30}; do
    if curl -s "$BASE_URL/models" >/dev/null 2>&1; then
      echo "✅ Server ready!"
      return
    fi
    sleep 2
  done

  echo "⚠️ Server not reachable yet"
}

# ===== Instructions =====
print_instructions() {
  BASE_URL="$(get_base_url)"

  echo ""
  echo "=============================================="
  echo "🚀 LLM Server Ready"
  echo "=============================================="
  echo ""
  echo "Base URL: $BASE_URL"
  echo "Model:    $(basename "$MODEL_FILE")"
  echo ""
  if [[ "$PUBLIC_BASE_URL" == https://*thundercompute.net* ]]; then
    echo "⚠️  ThunderCompute Port Setup Required"
    echo ""
    echo "If you cannot connect, you must expose port $PORT:"
    echo ""
    echo "  1. Open ThunderCompute UI"
    echo "  2. Go to your instance"
    echo "  3. Add port: $PORT"
    echo "  4. Refresh the URL"
    echo ""
  fi
  if has_systemd; then
    echo "Start:   sudo systemctl start llama-server"
    echo "Stop:    sudo systemctl stop llama-server"
    echo "Restart: sudo systemctl restart llama-server"
    echo "Logs:    journalctl -u llama-server -f"
  else
    echo "Start:   (already running)"
    echo "Stop:    pkill -f llama-server"
    echo "Logs:    tail -f $LOG_FILE"
  fi

  echo ""
  echo "Test:"
  echo "  curl $BASE_URL/models"
  echo ""
}

# ===== Run =====
install_deps
ensure_hf_cli
download_binaries
ensure_models

prompt_instance_id
build_public_url

echo "Stopping any existing processes..."
pkill -f llama-server || true

if has_systemd; then
  install_systemd_service
else
  echo "⚠️ systemd not available, using background mode"
  start_background_server
fi

wait_for_server
print_instructions
