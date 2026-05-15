#!/bin/bash
# ============================================================
# Robot Client
# 连接 SO101 + 摄像头，发送观测到本机/远端 policy server，执行返回的 action
#
# 前提: lab 上已运行 10_policy_server.sh
#
# 用法:
#   conda activate evo-rl
#   bash control_scripts/11_robot_client.sh
#   bash control_scripts/11_robot_client.sh "pick up the letter" /path/to/checkpoint/pretrained_model
# ============================================================

set -e

# --- 服务器配置 ---
LAB_IP="${LAB_IP:-127.0.0.1}"
LAB_PORT=8080
SERVER_ADDRESS="${SERVER_ADDRESS:-${LAB_IP}:${LAB_PORT}}"

# --- 机器人配置 ---
if [ -z "${FOLLOWER_PORT:-}" ]; then
    if [ -e "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00" ]; then
        FOLLOWER_PORT="/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00"
    else
        FOLLOWER_PORT="/dev/tty.usbmodem5B140327031"
    fi
fi
FOLLOWER_ID="${FOLLOWER_ID:-my_follower}"
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

# --- 模型配置 ---
POLICY_TYPE="${POLICY_TYPE:-pi05}"
MODEL_PATH="${2:-${MODEL_PATH:-lerobot/pi05_base}}"
TASK="${1:-pick up the object}"

# --- 安全配置 ---
# SO101 uses normalized joint targets. Keep policy outputs bounded relative to
# current joint positions so a bad checkpoint cannot command large jumps.
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-2}"
ACTIONS_PER_CHUNK="${ACTIONS_PER_CHUNK:-10}"
CHUNK_SIZE_THRESHOLD="${CHUNK_SIZE_THRESHOLD:-0.25}"
CLIENT_FPS="${CLIENT_FPS:-10}"

echo "=== SO101 Robot Client ==="
echo "Server: ${SERVER_ADDRESS}"
echo "Policy: ${POLICY_TYPE} (${MODEL_PATH})"
echo "Task: ${TASK}"
echo "Max relative target: ${MAX_RELATIVE_TARGET}"
echo "Client FPS: ${CLIENT_FPS}"
echo "Actions per chunk: ${ACTIONS_PER_CHUNK}"
echo ""

cd /home/ubuntu/Evo-RL
PYTHONPATH=src python -m lerobot.async_inference.robot_client \
  --robot.type=so101_follower \
  --robot.port=$FOLLOWER_PORT \
  --robot.id=$FOLLOWER_ID \
  --robot.max_relative_target=$MAX_RELATIVE_TARGET \
  --robot.cameras="$CAMERA_CONFIG" \
  --task="$TASK" \
  --server_address=$SERVER_ADDRESS \
  --policy_type=$POLICY_TYPE \
  --pretrained_name_or_path=$MODEL_PATH \
  --policy_device=cuda \
  --client_device=cpu \
  --fps=$CLIENT_FPS \
  --actions_per_chunk=$ACTIONS_PER_CHUNK \
  --chunk_size_threshold=$CHUNK_SIZE_THRESHOLD \
  --aggregate_fn_name=weighted_average
