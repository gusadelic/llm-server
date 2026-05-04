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

MODEL_REPO="${MODEL_REPO:-cloudbjorn/Qwen3.6-35B-A3B_Opus-4.6-Reasoning-3300x-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen-35B-Reasoning-Q4_K_M.gguf}"

PORT="${PORT:-8080}"
HOST="0.0.0.0"

mkdir -p "$WORKDIR" "$MODEL_DIR" "$BIN_EXPORT_DIR"

# ===== Mirror + PPA Fixes =====
remove_deadsnakes() {
  echo "Removing deadsnakes PPA..."
  sudo add-apt-repository --remove ppa:deadsnakes/ppa 2>/dev/null || true
  sudo rm -f /etc/apt/sources.list.d/deadsnakes-ubuntu-ppa*.list
}

use_az_mirror() {
  echo "Switching APT sources to University of Arizona mirror..."
  sudo sed -i 's|http://[^ ]*archive.ubuntu.com/ubuntu|http://mirror.arizona.edu/ubuntu|g' /etc/apt/sources.list
  sudo sed -i 's|http://security.ubuntu.com/ubuntu|http://mirror.arizona.edu/ubuntu|g' /etc/apt/sources.list
}

# ===== Spinner Setup =====
if [ -t 1 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi

if locale charmap 2>/dev/null | grep -qi utf-8; then
  SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  SPINNER_CHARS=('|' '/' '-' '\')
fi

create_run_script() {
  cat > "$WORKDIR/run.sh" <<EOF
#!/usr/bin/env bash

BIN="$BIN_EXPORT_DIR/llama-server"
MODEL="$MODEL_DIR/$MODEL_FILE"
LOG_FILE="$LOG_FILE"
PORT="$PORT"
HOST="$HOST"

start() {
  if pgrep -f llama-server >/dev/null; then
    echo "⚠️  Server already running"
    return
  fi
  export LD_LIBRARY_PATH="$BIN_EXPORT_DIR:/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}"
  nohup "\$BIN" \\
    --host "\$HOST" \\
    --port "\$PORT" \\
    --model "\$MODEL" \\
    >"\$LOG_FILE" 2>&1 &
  echo "Started (PID \$!)"
}

stop() {
  pkill -f llama-server || echo "No process found"
}

restart() {
  stop
  sleep 1
  start
}

status() {
  if pgrep -f llama-server >/dev/null; then
    echo "✅ Running"
  else
    echo "❌ Stopped"
  fi
}

logs() {
  tail -f "\$LOG_FILE"
}

case "\$1" in
  start|stop|restart|status|logs)
    "\$1"
    ;;
  *)
    echo "Usage: \$0 {start|stop|restart|status|logs}"
    ;;
esac
EOF

  chmod +x "$WORKDIR/run.sh"
}

# ===== UI helpers =====
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

# ===== Dependencies =====
install_deps() {
  echo "Step: install_deps"
  sudo apt-get update -o Acquire::ForceIPv4=true
  sudo apt-get install -y git curl unzip python3 python3-pip
}

# ===== Model Check =====
check_model() {
  if [ ! -f "$MODEL_DIR/$MODEL_FILE" ]; then
    echo "❌ Model not found:"
    echo "   $MODEL_DIR/$MODEL_FILE"
    echo ""
    echo "Download it manually and place it there."
    exit 1
  fi
}

# ===== Instance ID =====
load_instance_id() {
  [ -f "$INSTANCE_FILE" ] && INSTANCE_ID="$(cat "$INSTANCE_FILE")"
}

save_instance_id() {
  [ -n "${INSTANCE_ID:-}" ] && echo "$INSTANCE_ID" > "$INSTANCE_FILE"
}

prompt_instance_id() {
  load_instance_id
  [ -n "${INSTANCE_ID:-}" ] && echo "Using saved instance ID: $INSTANCE_ID" && return
  [ ! -t 0 ] && return
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

  sudo cp "$BIN_EXPORT_DIR"/lib*.so* /usr/local/lib/ || true
  sudo ldconfig
}

# ===== Server =====
start_server() {
  export LD_LIBRARY_PATH="$BIN_EXPORT_DIR:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
  nohup "$BIN_EXPORT_DIR/llama-server" \
    --host "$HOST" \
    --port "$PORT" \
    --model "$MODEL_DIR/$MODEL_FILE" \
    >"$LOG_FILE" 2>&1 &
}

# ===== Run =====
remove_deadsnakes
use_az_mirror
install_deps

download_binaries
check_model

prompt_instance_id
build_public_url

pkill -f llama-server || true
create_run_script
start_server
