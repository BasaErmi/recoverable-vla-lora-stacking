#!/bin/bash
# ============================================================
# Deploy the official OpenPI pi0.5 LoRA SO101 checkpoint.
#
# Usage:
#   bash control_scripts/25_deploy_openpi_pi05_so101.sh C
#   bash control_scripts/25_deploy_openpi_pi05_so101.sh U
#   bash control_scripts/25_deploy_openpi_pi05_so101.sh "pick up the visible letter block from the top box and place it in its matching lower box"
#
# Stop/status helpers:
#   bash control_scripts/25_deploy_openpi_pi05_so101.sh --status
#   bash control_scripts/25_deploy_openpi_pi05_so101.sh --stop
#   bash control_scripts/25_deploy_openpi_pi05_so101.sh --stop-server
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OPENPI_DIR="${OPENPI_DIR:-/home/ubuntu/openpi}"
OPENPI_PYTHON="${OPENPI_PYTHON:-$OPENPI_DIR/.venv/bin/python}"
EVO_PYTHON="${EVO_PYTHON:-/home/ubuntu/anaconda3/envs/evo-rl/bin/python}"
EVO_BIN_DIR="${EVO_BIN_DIR:-$(dirname "$EVO_PYTHON")}"
EVO_REPO_DIR="${EVO_REPO_DIR:-/home/ubuntu/Evo-RL}"

OPENPI_CONFIG="${OPENPI_CONFIG:-pi05_so101_cuhksz_slots_spatial_lora}"
OPENPI_CHECKPOINT="${OPENPI_CHECKPOINT:-/home/ubuntu/outputs/openpi/checkpoints/pi05_so101_cuhksz_slots_spatial_lora/pi05_so101_cuhksz_slots_spatial_lora_20260502_224018_b2_b2/29999}"
OPENPI_HOST="${OPENPI_HOST:-127.0.0.1}"
OPENPI_PORT="${OPENPI_PORT:-8000}"

FOLLOWER_PORT="${FOLLOWER_PORT:-/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00}"
FOLLOWER_ID="${FOLLOWER_ID:-my_follower}"

CLIENT_FPS="${CLIENT_FPS:-30}"
MAX_STEPS="${MAX_STEPS:-0}"
ACTION_CHUNK_START_INDEX="${ACTION_CHUNK_START_INDEX:-0}"
ACTION_CHUNK_RAMP_STEPS="${ACTION_CHUNK_RAMP_STEPS:-8}"
AUTO_SKIP_DELAY_ACTIONS="${AUTO_SKIP_DELAY_ACTIONS:-1}"
MAX_DELAY_SKIP_STEPS="${MAX_DELAY_SKIP_STEPS:-6}"
OPEN_LOOP_HORIZON="${OPEN_LOOP_HORIZON:-12}"
REFILL_THRESHOLD="${REFILL_THRESHOLD:-7}"
ACTION_COMMIT_HORIZON="${ACTION_COMMIT_HORIZON:-4}"
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-5}"
GRIPPER_MAX_RELATIVE_TARGET="${GRIPPER_MAX_RELATIVE_TARGET:-100}"
ACTION_EMA_ALPHA="${ACTION_EMA_ALPHA:-0.5}"
ACTION_MAX_DELTA="${ACTION_MAX_DELTA:-2}"
GRIPPER_ACTION_MAX_DELTA="${GRIPPER_ACTION_MAX_DELTA:-4}"
LOG_ACTIONS="${LOG_ACTIONS:-1}"
DIAGNOSTIC_EVERY_N="${DIAGNOSTIC_EVERY_N:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-1000}"
PROMPT_STYLE="${PROMPT_STYLE:-spatial}"
DISPLAY_DATA="${DISPLAY_DATA:-0}"
DISPLAY_COMPRESSED_IMAGES="${DISPLAY_COMPRESSED_IMAGES:-0}"
DISPLAY_EVERY_N="${DISPLAY_EVERY_N:-1}"
DISPLAY_IP="${DISPLAY_IP:-}"
DISPLAY_PORT="${DISPLAY_PORT:-}"

DEFAULT_FRONT_CAMERA_PATH="/dev/v4l/by-id/usb-icSpring_icspring_camera_202404160005-video-index0"
DEFAULT_WRIST_CAMERA_PATH="/dev/v4l/by-id/usb-CN02KX4NLG0004ABK00_USB_Camera_CN02KX4NLG0004ABK00-video-index0"

FRONT_CAMERA_INDEX="${FRONT_CAMERA_INDEX:-$DEFAULT_FRONT_CAMERA_PATH}"
FRONT_CAMERA_WIDTH="${FRONT_CAMERA_WIDTH:-640}"
FRONT_CAMERA_HEIGHT="${FRONT_CAMERA_HEIGHT:-480}"
FRONT_CAMERA_FPS="${FRONT_CAMERA_FPS:-30}"
FRONT_CAMERA_FOURCC="${FRONT_CAMERA_FOURCC-MJPG}"
FRONT_CAMERA_WARMUP_S="${FRONT_CAMERA_WARMUP_S:-1}"
WRIST_CAMERA_INDEX="${WRIST_CAMERA_INDEX:-$DEFAULT_WRIST_CAMERA_PATH}"
WRIST_CAMERA_WIDTH="${WRIST_CAMERA_WIDTH:-1280}"
WRIST_CAMERA_HEIGHT="${WRIST_CAMERA_HEIGHT:-720}"
WRIST_CAMERA_FPS="${WRIST_CAMERA_FPS:-30}"
WRIST_CAMERA_FOURCC="${WRIST_CAMERA_FOURCC:-MJPG}"
WRIST_CAMERA_WARMUP_S="${WRIST_CAMERA_WARMUP_S:-3}"

STOP_LEROBOT_GRPC_SERVER="${STOP_LEROBOT_GRPC_SERVER:-1}"
RESTART_OPENPI_SERVER="${RESTART_OPENPI_SERVER:-0}"
LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/outputs/deploy_logs}"
OPENPI_SERVER_LOG_ROOT="${OPENPI_SERVER_LOG_ROOT:-/home/ubuntu/outputs/deploy}"

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

letter_prompt() {
    local letter
    letter="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    if [ "$PROMPT_STYLE" = "task_index" ]; then
        case "$letter" in
            C) printf '%s\n' "0" ;;
            U) printf '%s\n' "1" ;;
            H) printf '%s\n' "2" ;;
            K) printf '%s\n' "3" ;;
            *) return 1 ;;
        esac
        return 0
    fi

    case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
        C) printf '%s\n' "The target slots from left to right are C, U, H, K. Pick up the visible C block and place it in the C target slot, the first slot from the left." ;;
        U) printf '%s\n' "The target slots from left to right are C, U, H, K. Pick up the visible U block and place it in the U target slot, the second slot from the left." ;;
        H) printf '%s\n' "The target slots from left to right are C, U, H, K. Pick up the visible H block and place it in the H target slot, the third slot from the left." ;;
        K) printf '%s\n' "The target slots from left to right are C, U, H, K. Pick up the visible K block and place it in the K target slot, the fourth slot from the left." ;;
        *) return 1 ;;
    esac
}

task_from_args() {
    if [ $# -eq 0 ]; then
        letter_prompt C
    elif [ $# -eq 1 ] && letter_prompt "$1" >/dev/null 2>&1; then
        letter_prompt "$1"
    else
        printf '%s\n' "$*"
    fi
}

openpi_server_pids() {
    pgrep -f "scripts/serve_policy.py.*$OPENPI_CONFIG" 2>/dev/null || true
}

status() {
    echo "=== OpenPI SO101 client ==="
    pgrep -af "openpi_so101_client.py" || true
    echo ""
    echo "=== OpenPI policy server ==="
    pgrep -af "scripts/serve_policy.py.*$OPENPI_CONFIG" || true
    ss -ltnp 2>/dev/null | grep ":$OPENPI_PORT" || true
    echo ""
    echo "=== LeRobot gRPC policy server ==="
    pgrep -af "lerobot.async_inference.policy_server" || true
    ss -ltnp 2>/dev/null | grep ":8080" || true
    echo ""
    echo "=== Serial port ==="
    lsof "$FOLLOWER_PORT" 2>/dev/null || true
    echo ""
    nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader || true
}

stop_client() {
    echo "Stopping OpenPI SO101 client..."
    pkill -INT -f "openpi_so101_client.py" 2>/dev/null || true
    sleep 2
    pkill -TERM -f "openpi_so101_client.py" 2>/dev/null || true
    bash "$SCRIPT_DIR/12_deploy_pick_letter.sh" --stop || true
}

stop_server() {
    echo "Stopping OpenPI policy server..."
    pkill -TERM -f "scripts/serve_policy.py.*$OPENPI_CONFIG" 2>/dev/null || true
    sleep 2
    ss -ltnp 2>/dev/null | grep ":$OPENPI_PORT" || true
    nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader || true
}

wait_for_server() {
    for _ in $(seq 1 360); do
        if "$EVO_PYTHON" - <<PY >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:${OPENPI_PORT}/healthz", timeout=1).read()
PY
        then
            return 0
        fi
        sleep 1
    done
    return 1
}

ensure_server() {
    local run_id="$1"
    local server_log="$OPENPI_SERVER_LOG_ROOT/openpi_policy_server_pi05_so101_${run_id}.log"

    if [ "$STOP_LEROBOT_GRPC_SERVER" = "1" ]; then
        pkill -TERM -f "lerobot.async_inference.policy_server" 2>/dev/null || true
    fi

    if [ "$RESTART_OPENPI_SERVER" = "1" ]; then
        pkill -TERM -f "scripts/serve_policy.py.*$OPENPI_CONFIG" 2>/dev/null || true
        sleep 2
    fi

    if ss -ltnp 2>/dev/null | grep -q ":$OPENPI_PORT"; then
        echo "$(ls -t "$OPENPI_SERVER_LOG_ROOT"/openpi_policy_server_pi05_so101_*.log 2>/dev/null | head -1 || true)"
        return 0
    fi

    mkdir -p "$OPENPI_SERVER_LOG_ROOT"
    echo "Starting OpenPI policy server..." >&2
    (
        cd "$OPENPI_DIR"
        exec setsid env \
            HF_LEROBOT_HOME=/home/ubuntu/data \
            PYTHONPATH="$EVO_REPO_DIR/src" \
            XLA_PYTHON_CLIENT_PREALLOCATE=false \
            XLA_PYTHON_CLIENT_MEM_FRACTION="${XLA_PYTHON_CLIENT_MEM_FRACTION:-0.90}" \
            XLA_FLAGS="${XLA_FLAGS:-} --xla_gpu_enable_triton_gemm=false" \
            "$OPENPI_PYTHON" scripts/serve_policy.py \
            --port "$OPENPI_PORT" \
            policy:checkpoint \
            --policy.config "$OPENPI_CONFIG" \
            --policy.dir "$OPENPI_CHECKPOINT"
    ) > "$server_log" 2>&1 &

    if ! wait_for_server; then
        echo "ERROR: OpenPI policy server did not become healthy. Check: $server_log" >&2
        tail -80 "$server_log" >&2 || true
        exit 1
    fi

    echo "$server_log"
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --status)
        status
        exit 0
        ;;
    --stop)
        stop_client
        exit 0
        ;;
    --stop-server)
        stop_server
        exit 0
        ;;
esac

REQUESTED_LETTER=""
if [ $# -eq 1 ] && letter_prompt "$1" >/dev/null 2>&1; then
    REQUESTED_LETTER="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
fi
TASK="$(task_from_args "$@")"
SAFE_TASK="$(printf '%s' "$TASK" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_-' | tr -s '_')"
RUN_ID="$(date +%Y%m%d_%H%M%S)_openpi_pi05_${SAFE_TASK}"
RUN_DIR="$LOG_ROOT/$RUN_ID"
CLIENT_LOG="$RUN_DIR/robot_client.log"
RUN_INFO="$RUN_DIR/run_info.txt"
mkdir -p "$RUN_DIR"

if [ ! -d "$OPENPI_CHECKPOINT/params" ]; then
    echo "ERROR: OpenPI checkpoint params not found: $OPENPI_CHECKPOINT/params" >&2
    exit 1
fi
if [ ! -e "$FOLLOWER_PORT" ]; then
    echo "ERROR: follower port not found: $FOLLOWER_PORT" >&2
    exit 1
fi
if pgrep -f "openpi_so101_client.py" >/dev/null; then
    echo "ERROR: OpenPI SO101 client already running. Stop it with:" >&2
    echo "  bash control_scripts/25_deploy_openpi_pi05_so101.sh --stop" >&2
    exit 1
fi
if lsof "$FOLLOWER_PORT" >/dev/null 2>&1; then
    echo "ERROR: follower port is already in use: $FOLLOWER_PORT" >&2
    lsof "$FOLLOWER_PORT" || true
    exit 1
fi

SERVER_LOG="$(ensure_server "$RUN_ID")"

cat > "$RUN_INFO" <<EOF
run_id=$RUN_ID
task=$TASK
prompt_style=$PROMPT_STYLE
requested_letter=$REQUESTED_LETTER
openpi_config=$OPENPI_CONFIG
openpi_checkpoint=$OPENPI_CHECKPOINT
openpi_server=$OPENPI_HOST:$OPENPI_PORT
server_log=$SERVER_LOG
client_log=$CLIENT_LOG
follower_port=$FOLLOWER_PORT
client_fps=$CLIENT_FPS
max_steps=$MAX_STEPS
action_chunk_start_index=$ACTION_CHUNK_START_INDEX
action_chunk_ramp_steps=$ACTION_CHUNK_RAMP_STEPS
auto_skip_delay_actions=$AUTO_SKIP_DELAY_ACTIONS
max_delay_skip_steps=$MAX_DELAY_SKIP_STEPS
open_loop_horizon=$OPEN_LOOP_HORIZON
refill_threshold=$REFILL_THRESHOLD
action_commit_horizon=$ACTION_COMMIT_HORIZON
max_relative_target=$MAX_RELATIVE_TARGET
gripper_max_relative_target=$GRIPPER_MAX_RELATIVE_TARGET
action_ema_alpha=$ACTION_EMA_ALPHA
action_max_delta=$ACTION_MAX_DELTA
gripper_action_max_delta=$GRIPPER_ACTION_MAX_DELTA
display_data=$DISPLAY_DATA
display_compressed_images=$DISPLAY_COMPRESSED_IMAGES
display_every_n=$DISPLAY_EVERY_N
display_ip=$DISPLAY_IP
display_port=$DISPLAY_PORT
evo_bin_dir=$EVO_BIN_DIR
front_camera=$FRONT_CAMERA_INDEX ${FRONT_CAMERA_WIDTH}x${FRONT_CAMERA_HEIGHT}@${FRONT_CAMERA_FPS} fourcc=${FRONT_CAMERA_FOURCC:-none}
wrist_camera=$WRIST_CAMERA_INDEX ${WRIST_CAMERA_WIDTH}x${WRIST_CAMERA_HEIGHT}@${WRIST_CAMERA_FPS} fourcc=${WRIST_CAMERA_FOURCC:-none}
started_at=$(date)
stop_client=bash control_scripts/25_deploy_openpi_pi05_so101.sh --stop
stop_server=bash control_scripts/25_deploy_openpi_pi05_so101.sh --stop-server
EOF

echo "=== SO101 OpenPI pi0.5 Deployment ===" | tee -a "$CLIENT_LOG"
echo "Run dir: $RUN_DIR" | tee -a "$CLIENT_LOG"
echo "Task: $TASK" | tee -a "$CLIENT_LOG"
echo "Prompt style: $PROMPT_STYLE" | tee -a "$CLIENT_LOG"
if [ -n "$REQUESTED_LETTER" ]; then
    echo "Requested letter: $REQUESTED_LETTER" | tee -a "$CLIENT_LOG"
fi
echo "Checkpoint: $OPENPI_CHECKPOINT" | tee -a "$CLIENT_LOG"
echo "Server: $OPENPI_HOST:$OPENPI_PORT" | tee -a "$CLIENT_LOG"
echo "Server log: $SERVER_LOG" | tee -a "$CLIENT_LOG"
echo "Client log: $CLIENT_LOG" | tee -a "$CLIENT_LOG"
echo "Runtime: FPS=$CLIENT_FPS ACTION_CHUNK_START_INDEX=$ACTION_CHUNK_START_INDEX ACTION_CHUNK_RAMP_STEPS=$ACTION_CHUNK_RAMP_STEPS AUTO_SKIP_DELAY_ACTIONS=$AUTO_SKIP_DELAY_ACTIONS MAX_DELAY_SKIP_STEPS=$MAX_DELAY_SKIP_STEPS OPEN_LOOP_HORIZON=$OPEN_LOOP_HORIZON REFILL_THRESHOLD=$REFILL_THRESHOLD ACTION_COMMIT_HORIZON=$ACTION_COMMIT_HORIZON" | tee -a "$CLIENT_LOG"
echo "Action controls: EMA=$ACTION_EMA_ALPHA ACTION_MAX_DELTA=$ACTION_MAX_DELTA GRIPPER_ACTION_MAX_DELTA=$GRIPPER_ACTION_MAX_DELTA MAX_RELATIVE_TARGET=$MAX_RELATIVE_TARGET GRIPPER_MAX_RELATIVE_TARGET=$GRIPPER_MAX_RELATIVE_TARGET" | tee -a "$CLIENT_LOG"
echo "Display: DISPLAY_DATA=$DISPLAY_DATA DISPLAY_EVERY_N=$DISPLAY_EVERY_N DISPLAY_COMPRESSED_IMAGES=$DISPLAY_COMPRESSED_IMAGES DISPLAY_IP=${DISPLAY_IP:-none} DISPLAY_PORT=${DISPLAY_PORT:-none}" | tee -a "$CLIENT_LOG"
echo "Cameras: front=cv$FRONT_CAMERA_INDEX ${FRONT_CAMERA_WIDTH}x${FRONT_CAMERA_HEIGHT} fourcc=${FRONT_CAMERA_FOURCC:-none}, wrist=cv$WRIST_CAMERA_INDEX ${WRIST_CAMERA_WIDTH}x${WRIST_CAMERA_HEIGHT} fourcc=${WRIST_CAMERA_FOURCC:-none}" | tee -a "$CLIENT_LOG"
echo "" | tee -a "$CLIENT_LOG"
echo "Press Ctrl-C to stop the robot client. Keep one hand near power/estop." | tee -a "$CLIENT_LOG"
echo "" | tee -a "$CLIENT_LOG"

LOG_ACTION_FLAG="--log-actions"
if [ "$LOG_ACTIONS" != "1" ]; then
    LOG_ACTION_FLAG="--no-log-actions"
fi
AUTO_SKIP_DELAY_FLAG="--auto-skip-delay-actions"
if [ "$AUTO_SKIP_DELAY_ACTIONS" != "1" ]; then
    AUTO_SKIP_DELAY_FLAG="--no-auto-skip-delay-actions"
fi
DISPLAY_DATA_FLAG="--no-display-data"
if [ "$DISPLAY_DATA" = "1" ]; then
    DISPLAY_DATA_FLAG="--display-data"
fi
DISPLAY_COMPRESSED_FLAG="--no-display-compressed-images"
if [ "$DISPLAY_COMPRESSED_IMAGES" = "1" ]; then
    DISPLAY_COMPRESSED_FLAG="--display-compressed-images"
fi
DISPLAY_ARGS=(
    "$DISPLAY_DATA_FLAG"
    "$DISPLAY_COMPRESSED_FLAG"
    --display-every-n "$DISPLAY_EVERY_N"
)
if [ -n "$DISPLAY_IP" ]; then
    DISPLAY_ARGS+=(--display-ip "$DISPLAY_IP")
fi
if [ -n "$DISPLAY_PORT" ]; then
    DISPLAY_ARGS+=(--display-port "$DISPLAY_PORT")
fi

set +e
printf '\n' | env \
    PATH="$EVO_BIN_DIR:$PATH" \
    PYTHONPATH="$EVO_REPO_DIR/src:$OPENPI_DIR/packages/openpi-client/src" \
    "$EVO_PYTHON" "$SCRIPT_DIR/openpi_so101_client.py" \
    --host "$OPENPI_HOST" \
    --port "$OPENPI_PORT" \
    --task "$TASK" \
    --follower-port "$FOLLOWER_PORT" \
    --follower-id "$FOLLOWER_ID" \
    --fps "$CLIENT_FPS" \
    --max-steps "$MAX_STEPS" \
    --chunk-start-index "$ACTION_CHUNK_START_INDEX" \
    --chunk-ramp-steps "$ACTION_CHUNK_RAMP_STEPS" \
    "$AUTO_SKIP_DELAY_FLAG" \
    --max-delay-skip-steps "$MAX_DELAY_SKIP_STEPS" \
    --open-loop-horizon "$OPEN_LOOP_HORIZON" \
    --refill-threshold "$REFILL_THRESHOLD" \
    --commit-horizon "$ACTION_COMMIT_HORIZON" \
    --max-relative-target "$MAX_RELATIVE_TARGET" \
    --gripper-max-relative-target "$GRIPPER_MAX_RELATIVE_TARGET" \
    --action-ema-alpha "$ACTION_EMA_ALPHA" \
    --action-max-delta "$ACTION_MAX_DELTA" \
    --gripper-action-max-delta "$GRIPPER_ACTION_MAX_DELTA" \
    --diagnostic-every-n "$DIAGNOSTIC_EVERY_N" \
    --camera-max-age-ms "$CAMERA_MAX_AGE_MS" \
    --front-index "$FRONT_CAMERA_INDEX" \
    --front-width "$FRONT_CAMERA_WIDTH" \
    --front-height "$FRONT_CAMERA_HEIGHT" \
    --front-fps "$FRONT_CAMERA_FPS" \
    --front-fourcc "${FRONT_CAMERA_FOURCC:-}" \
    --front-warmup-s "$FRONT_CAMERA_WARMUP_S" \
    --wrist-index "$WRIST_CAMERA_INDEX" \
    --wrist-width "$WRIST_CAMERA_WIDTH" \
    --wrist-height "$WRIST_CAMERA_HEIGHT" \
    --wrist-fps "$WRIST_CAMERA_FPS" \
    --wrist-fourcc "${WRIST_CAMERA_FOURCC:-}" \
    --wrist-warmup-s "$WRIST_CAMERA_WARMUP_S" \
    "${DISPLAY_ARGS[@]}" \
    "$LOG_ACTION_FLAG" 2>&1 | tee -a "$CLIENT_LOG"
STATUS=${PIPESTATUS[1]}
set -e

echo "" | tee -a "$CLIENT_LOG"
echo "OpenPI SO101 client exited with status $STATUS" | tee -a "$CLIENT_LOG"
echo "finished_at=$(date)" >> "$RUN_INFO"
echo "exit_status=$STATUS" >> "$RUN_INFO"

exit "$STATUS"
