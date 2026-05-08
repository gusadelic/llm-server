#!/usr/bin/env bash
set -euo pipefail
trap 'echo "❌ Error on line $LINENO"; exit 1' ERR

# ===== Config =====
WORKDIR="${WORKDIR:-$HOME/llm}"
MODEL_DIR="${MODEL_DIR:-$WORKDIR/models}"
BIN_EXPORT_DIR="${BIN_EXPORT_DIR:-$WORKDIR/bin}"
LOG_FILE="${LOG_FILE:-$WORKDIR/llama-server.log}"
INSTANCE_FILE="$WORKDIR/.instance_id"

RELEASE_URL="${RELEASE_URL:-https://github.com/gusadelic/llm-server/releases/download/v0.1.0/llama-bin.zip}"

MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3-Coder-Next-GGUF }"
MODEL_FILE="${MODEL_FILE:-Qwen3-Coder-Next-UD-Q4_K_XL.gguf}"

PORT="${PORT:-8080}"
HOST="0.0.0.0"

mkdir -p "$WORKDIR" "$MODEL_DIR" "$BIN_EXPORT_DIR"

# ===== System Fixes =====
remove_deadsnakes() {
  sudo add-apt-repository --remove ppa:deadsnakes/ppa 2>/dev/null || true
  sudo rm -f /etc/apt/sources.list.d/deadsnakes-ubuntu-ppa*.list
}

use_az_mirror() {
  sudo sed -i 's|http://[^ ]*archive.ubuntu.com/ubuntu|http://mirror.arizona.edu/ubuntu|g' /etc/apt/sources.list
  sudo sed -i 's|http://security.ubuntu.com/ubuntu|http://mirror.arizona.edu/ubuntu|g' /etc/apt/sources.list
}

install_deps() {
  sudo apt-get update -o Acquire::ForceIPv4=true
  sudo apt-get install -y git curl unzip python3 python3-pip
}

# ===== Spinner =====
if [ -t 1 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi
SPINNER=('|' '/' '-' '\')
spin_i=0
spin() { spin_i=$(( (spin_i+1)%4 )); printf "%s" "${SPINNER[$spin_i]}"; }

update_line() {
  [ "$INTERACTIVE" = "1" ] && printf "\r\033[K%s %s" "$1" "$(spin)" || echo "$1..."
}
finish_line() {
  if [ "$INTERACTIVE" = "1" ]; then
    printf "\r\033[K%s ✓\n" "$1"
  else
    echo "$1 ✓"
  fi
}

# ===== Model =====
resolve_model() {
  DEFAULT_URL="https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE"
  DEFAULT_PATH="$MODEL_DIR/$MODEL_FILE"

  if [ -f "$DEFAULT_PATH" ]; then
    MODEL_PATH="$DEFAULT_PATH"
    return
  fi

  echo ""
  echo "Model not found:"
  echo "  $DEFAULT_PATH"
  echo ""

  FILE_SIZE=$(curl -sI "$DEFAULT_URL" | awk '/Content-Length/ {print $2}' | tr -d '\r')
  [ -n "$FILE_SIZE" ] && SIZE="~$((FILE_SIZE/1024/1024)) MB" || SIZE="unknown"

  echo "Default model:"
  echo "  Repo : $MODEL_REPO"
  echo "  File : $MODEL_FILE"
  echo "  URL  : $DEFAULT_URL"
  echo "  Size : $SIZE"
  echo ""

  echo "[Enter] Download | c = custom | n = cancel"
  read -r -p "Choice: " choice

  case "$choice" in
    ""|"y") MODEL_URL="$DEFAULT_URL" ;;
    "c")
      read -r -p "Enter URL: " MODEL_URL
      ;;
    *) exit 1 ;;
  esac

  FILE="$(basename "$MODEL_URL")"
  MODEL_PATH="$MODEL_DIR/$FILE"

  echo "Downloading → $MODEL_PATH"
  curl -L --fail --progress-bar -C - "$MODEL_URL" -o "$MODEL_PATH"
  echo ""
}

# ===== Binaries =====
download_binaries() {
  if [ -x "$BIN_EXPORT_DIR/llama-server" ]; then return; fi

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
    --model "$MODEL_PATH" \
    >"$LOG_FILE" 2>&1 &
}

wait_for_server() {
  echo ""

  # Step 1: startup spinner
  msg="Starting server..."
  for i in {1..10}; do
    update_line "$msg"
    sleep 0.2
  done
  finish_line "$msg"

  # Step 2: wait for port
  msg="Waiting for port $PORT..."
  for i in {1..40}; do
    if ss -tuln | grep -q ":$PORT"; then
      finish_line "$msg"
      break
    fi
    update_line "$msg"
    sleep 0.25
  done

  echo ""
  echo "Loading model..."

  # Step 3: model loading (dot progress)
  DOT_COUNT=0
  MAX_DOTS=80

  while true; do
    # success condition
    if grep -qi "model loaded\|server listening" "$LOG_FILE" 2>/dev/null; then
      echo ""
      echo "✓ Model loaded"
      break
    fi

    # failure condition
    if ! pgrep -f llama-server >/dev/null; then
      echo ""
      echo "❌ Server process exited"
      echo "Check logs:"
      echo "  tail -f $LOG_FILE"
      return 1
    fi

    # print dot
    printf "."
    DOT_COUNT=$((DOT_COUNT + 1))

    # wrap line
    if [ "$DOT_COUNT" -ge "$MAX_DOTS" ]; then
      printf "\n"
      DOT_COUNT=0
    fi

    sleep 1
  done

  echo ""

  # Step 4: API check
  msg="Checking API..."
  for i in {1..30}; do
    if curl -s "http://localhost:$PORT/v1/models" >/dev/null 2>&1; then
      finish_line "$msg"
      echo "🚀 Server ready!"
      return
    fi
    update_line "$msg"
    sleep 0.3
  done

  # fallback if API didn’t respond
  echo ""
  echo "⚠️ Server started but API check failed"
}

# ===== Instance =====
load_instance_id() {
  if [[ -f "$INSTANCE_FILE" ]]; then
    INSTANCE_ID=$(<"$INSTANCE_FILE")
  fi
}
save_instance_id() {
  if [[ -n "${INSTANCE_ID:-}" ]]; then
    echo "$INSTANCE_ID" > "$INSTANCE_FILE"
  fi
}

prompt_instance_id() {
  load_instance_id
  [ -n "${INSTANCE_ID:-}" ] && return
  read -r -p "Instance ID (Enter for localhost): " INSTANCE_ID || true
  save_instance_id
}

build_url() {
  if [[ -n "${INSTANCE_ID:-}" ]]; then
    BASE_URL="https://${INSTANCE_ID}-${PORT}.thundercompute.net"
  else
    BASE_URL="http://localhost:${PORT}"
  fi
}

# ===== Run Script =====
create_run_script() {
cat > "$WORKDIR/run.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  start) nohup "$BIN_EXPORT_DIR/llama-server" --model "$MODEL_PATH" --port "$PORT" & ;;
  stop) pkill -f llama-server ;;
  restart) pkill -f llama-server; sleep 1; "\$0" start ;;
  status) pgrep -f llama-server && echo running || echo stopped ;;
  logs) tail -f "$LOG_FILE" ;;
esac
EOF
chmod +x "$WORKDIR/run.sh"
}

# ===== Instructions =====
print_instructions() {
  echo ""
  echo "=============================================="
  echo "🚀 LLM Server Ready"
  echo "=============================================="
  echo "Base URL: ${BASE_URL}/v1"
  echo "Model: $(basename "$MODEL_PATH")"
  echo ""

  if [[ "$BASE_URL" == https://*thundercompute.net* ]]; then
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

  echo "Server control:"
  echo "  $WORKDIR/run.sh start"
  echo "  $WORKDIR/run.sh stop"
  echo "  $WORKDIR/run.sh restart"
  echo "  $WORKDIR/run.sh status"
  echo "  $WORKDIR/run.sh logs"
  echo ""
  echo "Test with:"
  echo "  curl ${BASE_URL}/v1/models"
  echo ""
}

# ===== Main =====
remove_deadsnakes
use_az_mirror
install_deps

download_binaries
resolve_model
export MODEL_PATH

prompt_instance_id
build_url

pkill -f llama-server || true
create_run_script
start_server
wait_for_server
print_instructions
