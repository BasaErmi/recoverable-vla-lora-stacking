#!/bin/bash
# ============================================================
# SO101 demonstration recording
#
# Usage:
#   conda activate evo-rl
#   bash scripts/record_data.sh
#   bash scripts/record_data.sh guanlin8/cuhksz_pick_recalib_20260425 "pick up the letter" 30 15 5 false
#
# Prerequisite: calibration and teleoperation check have been completed.
#
# Hotkeys:
#   Right Arrow  - finish current episode and start the next one
#   Left Arrow   - rerecord current episode
#   Esc          - stop recording
# ============================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${FOLLOWER_PORT:-}" ]; then
    if [ -e "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00" ]; then
        FOLLOWER_PORT="/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00"
    else
        FOLLOWER_PORT="/dev/tty.usbmodem5B140327031"
    fi
fi
if [ -z "${LEADER_PORT:-}" ]; then
    if [ -e "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3E120040-if00" ]; then
        LEADER_PORT="/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3E120040-if00"
    else
        LEADER_PORT="/dev/tty.usbmodem5B3E1200401"
    fi
fi
FOLLOWER_ID="${FOLLOWER_ID:-my_follower}"
LEADER_ID="${LEADER_ID:-my_leader}"
DEFAULT_FRONT_CAMERA_PATH="/dev/v4l/by-id/usb-icSpring_icspring_camera_202404160005-video-index0"
DEFAULT_WRIST_CAMERA_PATH="/dev/v4l/by-id/usb-CN02KX4NLG0004ABK00_USB_Camera_CN02KX4NLG0004ABK00-video-index0"
if [ -z "${FRONT_CAMERA_INDEX:-}" ]; then
    if [ -e "$DEFAULT_FRONT_CAMERA_PATH" ]; then
        FRONT_CAMERA_INDEX="$DEFAULT_FRONT_CAMERA_PATH"
    else
        FRONT_CAMERA_INDEX="0"
    fi
fi
FRONT_CAMERA_WIDTH="${FRONT_CAMERA_WIDTH:-640}"
FRONT_CAMERA_HEIGHT="${FRONT_CAMERA_HEIGHT:-480}"
FRONT_CAMERA_FPS="${FRONT_CAMERA_FPS:-30}"
FRONT_CAMERA_FOURCC="${FRONT_CAMERA_FOURCC:-MJPG}"
FRONT_CAMERA_WARMUP_S="${FRONT_CAMERA_WARMUP_S:-1}"
if [ -z "${WRIST_CAMERA_INDEX:-}" ]; then
    if [ -e "$DEFAULT_WRIST_CAMERA_PATH" ]; then
        WRIST_CAMERA_INDEX="$DEFAULT_WRIST_CAMERA_PATH"
    else
        WRIST_CAMERA_INDEX="2"
    fi
fi
WRIST_CAMERA_WIDTH="${WRIST_CAMERA_WIDTH:-1280}"
WRIST_CAMERA_HEIGHT="${WRIST_CAMERA_HEIGHT:-720}"
WRIST_CAMERA_FPS="${WRIST_CAMERA_FPS:-30}"
WRIST_CAMERA_FOURCC="${WRIST_CAMERA_FOURCC:-MJPG}"
WRIST_CAMERA_WARMUP_S="${WRIST_CAMERA_WARMUP_S:-3}"
CAMERA_CONFIG="{ front: {type: opencv, index_or_path: $FRONT_CAMERA_INDEX, width: $FRONT_CAMERA_WIDTH, height: $FRONT_CAMERA_HEIGHT, fps: $FRONT_CAMERA_FPS, fourcc: $FRONT_CAMERA_FOURCC, warmup_s: $FRONT_CAMERA_WARMUP_S}, wrist: {type: opencv, index_or_path: $WRIST_CAMERA_INDEX, width: $WRIST_CAMERA_WIDTH, height: $WRIST_CAMERA_HEIGHT, fps: $WRIST_CAMERA_FPS, fourcc: $WRIST_CAMERA_FOURCC, warmup_s: $WRIST_CAMERA_WARMUP_S}}"
LEROBOT_BIN_DIR="${LEROBOT_BIN_DIR:-/home/ubuntu/anaconda3/envs/evo-rl/bin}"
LEROBOT_RECORD="${LEROBOT_RECORD:-$LEROBOT_BIN_DIR/lerobot-record}"
export PATH="$LEROBOT_BIN_DIR:$PATH"

if [ ! -x "$LEROBOT_RECORD" ]; then
    echo "ERROR: lerobot-record not found or not executable: $LEROBOT_RECORD" >&2
    echo "Set LEROBOT_RECORD=/path/to/lerobot-record or install LeRobot in evo-rl." >&2
    exit 1
fi

# --- Configurable parameters ---
DATASET_NAME="${1:-pi05_so101_demo}"
TASK_DESC="${2:-pick up the object}"
NUM_EPISODES="${3:-10}"
EPISODE_TIME_S="${4:-30}"
RESET_TIME_S="${5:-5}"
RESUME="${6:-false}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-2000}"
CAMERA_DIAG_INTERVAL_S="${CAMERA_DIAG_INTERVAL_S:-0}"
DATASET_FPS="${DATASET_FPS:-30}"
DISPLAY_DATA="${DISPLAY_DATA:-true}"
DISPLAY_COMPRESSED_IMAGES="${DISPLAY_COMPRESSED_IMAGES:-false}"
VIDEO_CODEC="${VIDEO_CODEC:-libsvtav1}"
COPY_TO_DATA_ROOT="${COPY_TO_DATA_ROOT:-0}"
DATA_ROOT="${DATA_ROOT:-/home/ubuntu/data}"
RECORD_LOG_ROOT="${RECORD_LOG_ROOT:-$ROOT_DIR/outputs/record_logs}"
RECORD_METRICS_EVERY_N="${RECORD_METRICS_EVERY_N:-1}"
if [ -z "${RECORD_TERMINAL_FILTER_REGEX+x}" ]; then
    RECORD_TERMINAL_FILTER_REGEX="CAMERA_READ_DIAG|Using camera stale-frame tolerance|OpenCVCamera\\(.*\\) connected\\. requested=|Svt\\[(info|warn)\\]|^\\[mp4 @|wgpu_|egui_wgpu|winit::platform_impl|re_grpc_server|Guessed window scale factor"
fi
if [ -n "$RECORD_TERMINAL_FILTER_REGEX" ]; then
    RECORD_TERMINAL_OUTPUT_DESC="progress/errors only (camera/SVT/Rerun noise filtered)"
else
    RECORD_TERMINAL_OUTPUT_DESC="full (unfiltered)"
fi

CALIBRATION_ROOT="${HF_HOME:-$HOME/.cache/huggingface}/lerobot/calibration"
FOLLOWER_CALIBRATION="$CALIBRATION_ROOT/robots/so_follower/${FOLLOWER_ID}.json"
LEADER_CALIBRATION="$CALIBRATION_ROOT/teleoperators/so_leader/${LEADER_ID}.json"
LOCAL_DATASET_DIR="${HF_HOME:-$HOME/.cache/huggingface}/lerobot/${DATASET_NAME}"
SAFE_DATASET_NAME="${DATASET_NAME//\//__}"
CALIBRATION_SNAPSHOT_DIR="outputs/calibration_snapshots/${SAFE_DATASET_NAME}_$(date +%Y%m%d_%H%M%S)"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RECORD_RUN_DIR="${RECORD_RUN_DIR:-$RECORD_LOG_ROOT/${RUN_STAMP}_${SAFE_DATASET_NAME}}"
RECORD_METRICS_LOG="${RECORD_METRICS_LOG:-$RECORD_RUN_DIR/record_metrics.csv}"
RECORD_STDOUT_LOG="${RECORD_STDOUT_LOG:-$RECORD_RUN_DIR/record.log}"
RUN_INFO="$RECORD_RUN_DIR/run_info.txt"

mkdir -p "$RECORD_RUN_DIR"
ln -sfn "$RECORD_RUN_DIR" "$RECORD_LOG_ROOT/latest"
{
    echo "started_at=$(date -Is)"
    echo "dataset_name=$DATASET_NAME"
    echo "task_desc=$TASK_DESC"
    echo "num_episodes=$NUM_EPISODES"
    echo "episode_time_s=$EPISODE_TIME_S"
    echo "reset_time_s=$RESET_TIME_S"
    echo "resume=$RESUME"
    echo "dataset_fps=$DATASET_FPS"
    echo "camera_diag_interval_s=$CAMERA_DIAG_INTERVAL_S"
    echo "display_data=$DISPLAY_DATA"
    echo "metrics_log=$RECORD_METRICS_LOG"
    echo "record_log=$RECORD_STDOUT_LOG"
    echo "record_metrics_every_n=$RECORD_METRICS_EVERY_N"
    echo "record_terminal_filter_regex=$RECORD_TERMINAL_FILTER_REGEX"
    echo "record_terminal_output=$RECORD_TERMINAL_OUTPUT_DESC"
    echo "camera_config=$CAMERA_CONFIG"
} > "$RUN_INFO"

echo "=== SO101 demonstration recording ==="
echo "Dataset: $DATASET_NAME"
echo "Task: $TASK_DESC"
echo "Episodes: $NUM_EPISODES"
echo "Dataset FPS: ${DATASET_FPS}fps"
echo "Episode duration: ${EPISODE_TIME_S}s"
echo "Camera stale-frame tolerance: ${CAMERA_MAX_AGE_MS}ms"
echo "Camera diagnostic interval: ${CAMERA_DIAG_INTERVAL_S}s (0=off)"
echo "Cameras: $CAMERA_CONFIG"
echo "Video codec: $VIDEO_CODEC"
echo "Rerun display: $DISPLAY_DATA"
echo "Rerun compressed images: $DISPLAY_COMPRESSED_IMAGES"
echo "Terminal output: $RECORD_TERMINAL_OUTPUT_DESC"
echo "Copy finished dataset to data root: $COPY_TO_DATA_ROOT ($DATA_ROOT)"
echo "Follower calibration: $FOLLOWER_CALIBRATION"
echo "Leader calibration: $LEADER_CALIBRATION"
echo "LeRobot: $LEROBOT_RECORD"
echo "Metrics log: $RECORD_METRICS_LOG"
echo "Record log: $RECORD_STDOUT_LOG"
echo ""
echo "Press Enter to start..."
read

RESUME_FLAG="--resume=false"
if [ "$RESUME" = "true" ]; then
    RESUME_FLAG="--resume=true"
    echo "(resume mode)"
fi

mkdir -p "$CALIBRATION_SNAPSHOT_DIR"
if [ -f "$FOLLOWER_CALIBRATION" ]; then
    cp "$FOLLOWER_CALIBRATION" "$CALIBRATION_SNAPSHOT_DIR/follower_${FOLLOWER_ID}.json"
else
    echo "ERROR: follower calibration file not found: " >&2
    exit 1
fi

if [ -f "$LEADER_CALIBRATION" ]; then
    cp "$LEADER_CALIBRATION" "$CALIBRATION_SNAPSHOT_DIR/leader_${LEADER_ID}.json"
else
    echo "ERROR: leader calibration file not found: " >&2
    exit 1
fi

echo "Calibration snapshot saved: "

FINALIZED_DATASET_ARTIFACTS=0
finalize_dataset_artifacts() {
    if [ "$FINALIZED_DATASET_ARTIFACTS" -eq 1 ]; then
        return
    fi
    FINALIZED_DATASET_ARTIFACTS=1

    if [ -d "$LOCAL_DATASET_DIR" ]; then
        mkdir -p "$LOCAL_DATASET_DIR/meta/calibration"
        cp "$CALIBRATION_SNAPSHOT_DIR"/*.json "$LOCAL_DATASET_DIR/meta/calibration/"
        echo "Calibration snapshot copied to dataset: /meta/calibration/"

        if [ "$COPY_TO_DATA_ROOT" = "1" ]; then
            DATASET_DATA_ROOT="$DATA_ROOT/$DATASET_NAME"
            mkdir -p "$DATA_ROOT/$(dirname "$DATASET_NAME")"
            rsync -a --progress "$LOCAL_DATASET_DIR/" "$DATASET_DATA_ROOT/"
            echo "Dataset synced to: "
        fi
    fi
}

RECORD_CMD=(
  "$LEROBOT_RECORD"
  --robot.type=so101_follower
  --robot.port="$FOLLOWER_PORT"
  --robot.id="$FOLLOWER_ID"
  --robot.cameras="$CAMERA_CONFIG"
  --teleop.type=so101_leader
  --teleop.port="$LEADER_PORT"
  --teleop.id="$LEADER_ID"
  --dataset.repo_id="$DATASET_NAME"
  --dataset.single_task="$TASK_DESC"
  --dataset.fps="$DATASET_FPS"
  --dataset.num_episodes="$NUM_EPISODES"
  --dataset.episode_time_s="$EPISODE_TIME_S"
  --dataset.reset_time_s="$RESET_TIME_S"
  --dataset.vcodec="$VIDEO_CODEC"
  --dataset.push_to_hub=false
  --display_data="$DISPLAY_DATA"
  --display_compressed_images="$DISPLAY_COMPRESSED_IMAGES"
  "$RESUME_FLAG"
)

set +e
if [ -n "$RECORD_TERMINAL_FILTER_REGEX" ]; then
    LEROBOT_CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
    LEROBOT_CAMERA_DIAG_INTERVAL_S="$CAMERA_DIAG_INTERVAL_S" \
    LEROBOT_RECORD_METRICS_LOG="$RECORD_METRICS_LOG" \
    LEROBOT_RECORD_METRICS_EVERY_N="$RECORD_METRICS_EVERY_N" \
    "${RECORD_CMD[@]}" \
      2>&1 | tee "$RECORD_STDOUT_LOG" | grep --line-buffered -Ev "$RECORD_TERMINAL_FILTER_REGEX"
    RECORD_STATUS=${PIPESTATUS[0]}
else
    LEROBOT_CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
    LEROBOT_CAMERA_DIAG_INTERVAL_S="$CAMERA_DIAG_INTERVAL_S" \
    LEROBOT_RECORD_METRICS_LOG="$RECORD_METRICS_LOG" \
    LEROBOT_RECORD_METRICS_EVERY_N="$RECORD_METRICS_EVERY_N" \
    "${RECORD_CMD[@]}" \
      2>&1 | tee "$RECORD_STDOUT_LOG"
    RECORD_STATUS=${PIPESTATUS[0]}
fi
set -e

finalize_dataset_artifacts

if [ "$RECORD_STATUS" -ne 0 ]; then
    echo "WARNING: saved dataset artifacts were finalized before returning the recording error." >&2
    echo "ERROR: lerobot-record exited with status $RECORD_STATUS" >&2
    exit "$RECORD_STATUS"
fi

echo ""
echo "=== Recording complete ==="
echo "Local dataset: ~/.cache/huggingface/lerobot/$DATASET_NAME"
echo "Calibration snapshot: $CALIBRATION_SNAPSHOT_DIR"
echo ""
echo "Upload to HuggingFace Hub:"
echo "  huggingface-cli upload $DATASET_NAME ~/.cache/huggingface/lerobot/$DATASET_NAME"
echo ""
echo "Copy to lab data directory:"
echo "  mkdir -p /home/ubuntu/data/$(dirname "$DATASET_NAME")"
echo "  rsync -av --progress ~/.cache/huggingface/lerobot/$DATASET_NAME/ /home/ubuntu/data/$DATASET_NAME/"
