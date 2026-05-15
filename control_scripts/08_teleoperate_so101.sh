#!/bin/bash
# ============================================================
# SO101 遥操作验证
#
# 用法:
#   conda activate evo-rl
#   bash control_scripts/08_teleoperate_so101.sh
#
# 前提: 已完成标定 (07_calibrate_so101.sh)
# ============================================================

set -e

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
FRONT_CAMERA_FOURCC="${FRONT_CAMERA_FOURCC-MJPG}"
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
FRONT_CAMERA_SPEC="front: {type: opencv, index_or_path: $FRONT_CAMERA_INDEX, width: $FRONT_CAMERA_WIDTH, height: $FRONT_CAMERA_HEIGHT, fps: $FRONT_CAMERA_FPS, warmup_s: $FRONT_CAMERA_WARMUP_S"
if [ -n "$FRONT_CAMERA_FOURCC" ]; then
    FRONT_CAMERA_SPEC="$FRONT_CAMERA_SPEC, fourcc: $FRONT_CAMERA_FOURCC"
fi
FRONT_CAMERA_SPEC="$FRONT_CAMERA_SPEC}"
CAMERA_CONFIG="{ $FRONT_CAMERA_SPEC, wrist: {type: opencv, index_or_path: $WRIST_CAMERA_INDEX, width: $WRIST_CAMERA_WIDTH, height: $WRIST_CAMERA_HEIGHT, fps: $WRIST_CAMERA_FPS, fourcc: $WRIST_CAMERA_FOURCC, warmup_s: $WRIST_CAMERA_WARMUP_S}}"
LEROBOT_BIN_DIR="${LEROBOT_BIN_DIR:-/home/ubuntu/anaconda3/envs/evo-rl/bin}"
LEROBOT_TELEOPERATE="${LEROBOT_TELEOPERATE:-$LEROBOT_BIN_DIR/lerobot-teleoperate}"
export PATH="$LEROBOT_BIN_DIR:$PATH"
TELEOP_LOG_ROOT="${TELEOP_LOG_ROOT:-$ROOT_DIR/outputs/teleop_logs}"
TELEOP_METRICS_EVERY_N="${TELEOP_METRICS_EVERY_N:-1}"
TELEOP_FPS="${TELEOP_FPS:-60}"
TELEOP_ASYNC_DISPLAY="${TELEOP_ASYNC_DISPLAY:-1}"
TELEOP_DISPLAY_FPS="${TELEOP_DISPLAY_FPS:-30}"
# Local Rerun viewer does not need per-frame JPEG compression; compression was
# measured as the main source of unstable video teleop loop frequency.
DISPLAY_COMPRESSED_IMAGES="${DISPLAY_COMPRESSED_IMAGES:-false}"

if [ ! -x "$LEROBOT_TELEOPERATE" ]; then
    echo "ERROR: lerobot-teleoperate not found or not executable: $LEROBOT_TELEOPERATE" >&2
    echo "Set LEROBOT_TELEOPERATE=/path/to/lerobot-teleoperate or install LeRobot in evo-rl." >&2
    exit 1
fi

echo "=== SO101 遥操作验证 ==="
echo "LeRobot: $LEROBOT_TELEOPERATE"
echo ""
echo "方式 1: 纯遥操作 (无摄像头)"
echo "方式 2: 遥操作 + 摄像头预览"
echo ""
echo "请选择 (1/2): "
read choice

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${TELEOP_RUN_DIR:-$TELEOP_LOG_ROOT/${RUN_STAMP}_mode_${choice}}"
TELEOP_METRICS_LOG="${TELEOP_METRICS_LOG:-$RUN_DIR/teleop_metrics.csv}"
RUN_INFO="$RUN_DIR/run_info.txt"
mkdir -p "$RUN_DIR"
ln -sfn "$RUN_DIR" "$TELEOP_LOG_ROOT/latest"

{
    echo "started_at=$(date -Is)"
    echo "mode=$choice"
    echo "metrics_log=$TELEOP_METRICS_LOG"
    echo "follower_port=$FOLLOWER_PORT"
    echo "leader_port=$LEADER_PORT"
    echo "camera_config=$CAMERA_CONFIG"
    echo "teleop_metrics_every_n=$TELEOP_METRICS_EVERY_N"
    echo "teleop_fps=$TELEOP_FPS"
    echo "teleop_async_display=$TELEOP_ASYNC_DISPLAY"
    echo "teleop_display_fps=$TELEOP_DISPLAY_FPS"
    echo "display_compressed_images=$DISPLAY_COMPRESSED_IMAGES"
} > "$RUN_INFO"

echo "Metrics log: $TELEOP_METRICS_LOG"
echo "Monitor: bash control_scripts/20_monitor_teleop_fps.sh"
echo ""

case "$choice" in
    2)
        echo "启动遥操作 + 摄像头..."
        LEROBOT_TELEOP_METRICS_LOG="$TELEOP_METRICS_LOG" \
        LEROBOT_TELEOP_METRICS_EVERY_N="$TELEOP_METRICS_EVERY_N" \
        LEROBOT_TELEOP_ASYNC_DISPLAY="$TELEOP_ASYNC_DISPLAY" \
        LEROBOT_TELEOP_DISPLAY_FPS="$TELEOP_DISPLAY_FPS" \
        "$LEROBOT_TELEOPERATE" \
          --robot.type=so101_follower \
          --robot.port="$FOLLOWER_PORT" \
          --robot.id="$FOLLOWER_ID" \
          --robot.cameras="$CAMERA_CONFIG" \
          --teleop.type=so101_leader \
          --teleop.port="$LEADER_PORT" \
          --teleop.id="$LEADER_ID" \
          --fps="$TELEOP_FPS" \
          --display_data=true \
          --display_compressed_images="$DISPLAY_COMPRESSED_IMAGES"
        ;;
    1)
        echo "启动纯遥操作..."
        LEROBOT_TELEOP_METRICS_LOG="$TELEOP_METRICS_LOG" \
        LEROBOT_TELEOP_METRICS_EVERY_N="$TELEOP_METRICS_EVERY_N" \
        "$LEROBOT_TELEOPERATE" \
          --robot.type=so101_follower \
          --robot.port="$FOLLOWER_PORT" \
          --robot.id="$FOLLOWER_ID" \
          --teleop.type=so101_leader \
          --teleop.port="$LEADER_PORT" \
          --teleop.id="$LEADER_ID" \
          --fps="$TELEOP_FPS"
        ;;
    *)
        echo "ERROR: 请选择 1 或 2" >&2
        exit 1
        ;;
esac
