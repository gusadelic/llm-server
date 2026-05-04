#!/usr/bin/env bash
set -euo pipefail

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

# ===== Dependencies =====
install_deps() {
  sudo apt-get update
  sudo apt-get install -y git curl unzip python3 python3-pip
}

# ===== ThunderCompute (detect only) =====
install_tnr_cli() {
  if command -v tnr >/dev/null 2>&1; then
    echo "ThunderCompute CLI detected."
  else
    echo ""
    echo "⚠️  ThunderCompute CLI (tnr) not found."
    echo "   To expose this server externally:"
    echo "     1. Open ThunderCompute UI"
    echo "     2. Add port: $PORT"
    echo "     3. Use: https://<instance-id>-$PORT.thundercompute.net"
    echo ""
  fi
}

ensure_tnr_authenticated() {
  command -v tnr >/dev/null 2>&1 || return
  tnr status >/dev/null 2>&1 || return

  echo "🔐 Logging into ThunderCompute..."
  tnr login || true
}

try_expose_port() {
  command -v tnr >/dev/null 2>&1 && tnr ports add "$PORT" || true
}

detect_instance_id() {
  command -v tnr >/dev/null 2>&1 || return
  tnr status >/dev/null 2>&1 || return
  tnr status | awk 'NR==2 {print $2}'
}

load_instance_id() {
  [ -f "$INSTANCE_FILE" ] && INSTANCE_ID="$(cat "$INSTANCE_FILE")"
}

save_instance_id() {
  [ -n "${INSTANCE_ID:-}" ] && echo "$INSTANCE_ID" > "$INSTANCE_FILE"
}

prompt_instance_id() {
  load_instance_id

  if [ -n "${INSTANCE_ID:-}" ]; then
    echo "Using saved instance ID: $INSTANCE_ID"
    return
  fi

  INSTANCE_ID="$(detect_instance_id || true)"

  if [ -n "$INSTANCE_ID" ]; then
    echo "Detected instance ID: $INSTANCE_ID"
    save_instance_id
    return
  fi

  if [ ! -t 0 ]; then
    echo "Non-interactive environment, skipping instance ID prompt."
    return
  fi

  read -r -p "Enter ThunderCompute instance ID (or press Enter to skip): " INSTANCE_ID
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
  command -v hf >/dev/null 2>&1 || pip3 install --user -U huggingface_hub
}

# ===== Binaries =====
download_binaries() {
  if [ -x "$BIN_EXPORT_DIR/llama-server" ]; then
    echo "Binaries already present."
    return
  fi

  echo "Downloading binaries..."
  curl -L "$RELEASE_URL" -o /tmp/llama.zip
  unzip -o /tmp/llama.zip -d "$BIN_EXPORT_DIR"

  # Fix nested structure
  if [ -d "$BIN_EXPORT_DIR/llm/bin" ]; then
    mv "$BIN_EXPORT_DIR/llm/bin/"* "$BIN_EXPORT_DIR/"
    rm -rf "$BIN_EXPORT_DIR/llm"
  fi

  install_libs
}

install_libs() {
  echo "Installing shared libraries..."
  sudo cp "$BIN_EXPORT_DIR"/lib*.so* /usr/local/lib/ || true

  for lib in "$BIN_EXPORT_DIR"/lib*.so.*; do
    [ -e "$lib" ] || continue
    base=$(basename "$lib")
    name="${base%%.so.*}"
    sudo ln -sf "$base" "/usr/local/lib/${name}.so"
  done

  sudo ldconfig
}

# ===== Models =====
ensure_models() {
  [ -f "$MODEL_DIR/$MODEL_FILE" ] || hf download "$MODEL_REPO" "$MODEL_FILE" --local-dir "$MODEL_DIR"
  [ -f "$MODEL_DIR/$MMPROJ_FILE" ] || hf download "$MODEL_REPO" "$MMPROJ_FILE" --local-dir "$MODEL_DIR"
}

# ===== systemd =====
install_systemd_service() {
  SERVICE_FILE="/etc/systemd/system/llama-server.service"

  echo "Installing systemd service..."

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

# ===== Health Check =====
wait_for_server() {
  BASE_URL="$(get_base_url)"

  echo "Waiting for server..."

  for i in {1..30}; do
    if curl -s "$BASE_URL/models" >/dev/null 2>&1; then
      echo "✅ Server ready!"
      return
    fi
    sleep 2
  done

  echo "⚠️ Server not reachable yet."
  echo "Check logs:"
  echo "  journalctl -u llama-server -f"
}

# ===== Instructions =====
print_instructions() {
  BASE_URL="$(get_base_url)"

  echo ""
  echo "=============================================="
  echo "🚀 LLM Server Ready"
  echo "=============================================="
  echo ""
  echo "Provider: OpenAI Compatible"
  echo "Base URL: $BASE_URL"
  echo "API Key:  anything"
  echo "Model:    $(basename "$MODEL_FILE")"
  echo ""
  echo "----------------------------------------------"
  echo "Server Management"
  echo "----------------------------------------------"
  echo ""
  echo "Start:"
  echo "  sudo systemctl start llama-server"
  echo ""
  echo "Stop:"
  echo "  sudo systemctl stop llama-server"
  echo ""
  echo "Restart:"
  echo "  sudo systemctl restart llama-server"
  echo ""
  echo "Status:"
  echo "  sudo systemctl status llama-server"
  echo ""
  echo "Logs:"
  echo "  journalctl -u llama-server -f"
  echo ""
  echo "Test:"
  echo "  curl $BASE_URL/models"
  echo ""
  echo "=============================================="
}

# ===== Run =====
install_deps
install_tnr_cli
ensure_tnr_authenticated
ensure_hf_cli

download_binaries
ensure_models

try_expose_port
prompt_instance_id
build_public_url

echo "Stopping any existing instances..."
pkill -f llama-server || true

install_systemd_service
wait_for_server
print_instructions
