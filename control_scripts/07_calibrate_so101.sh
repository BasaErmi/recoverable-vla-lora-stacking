#!/bin/bash
# ============================================================
# SO101 单套主从臂标定
#
# 用法:
#   conda activate evo-rl
#   bash control_scripts/07_calibrate_so101.sh
#
# 标定过程:
#   每个臂需要把各关节转到极限位置，跟着终端提示操作
#   标定文件保存在 ~/.cache/huggingface/lerobot/calibration/
# ============================================================

set -e

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
LEROBOT_BIN_DIR="${LEROBOT_BIN_DIR:-/home/ubuntu/anaconda3/envs/evo-rl/bin}"
LEROBOT_CALIBRATE="${LEROBOT_CALIBRATE:-$LEROBOT_BIN_DIR/lerobot-calibrate}"
export PATH="$LEROBOT_BIN_DIR:$PATH"

if [ ! -x "$LEROBOT_CALIBRATE" ]; then
    echo "ERROR: lerobot-calibrate not found or not executable: $LEROBOT_CALIBRATE" >&2
    echo "Set LEROBOT_CALIBRATE=/path/to/lerobot-calibrate or install LeRobot in evo-rl." >&2
    exit 1
fi

echo "=== SO101 标定 ==="
echo "Follower: $FOLLOWER_PORT"
echo "Leader:   $LEADER_PORT"
echo "LeRobot:  $LEROBOT_CALIBRATE"
echo ""

# Step 1: 标定 follower
echo "============================="
echo "Step 1: 标定 Follower（从臂）"
echo "============================="
echo "请准备好从臂，按回车开始..."
read

"$LEROBOT_CALIBRATE" \
  --robot.type=so101_follower \
  --robot.port="$FOLLOWER_PORT" \
  --robot.id="$FOLLOWER_ID"

echo ""
echo "Follower 标定完成!"
echo ""

# Step 2: 标定 leader
echo "============================="
echo "Step 2: 标定 Leader（主臂）"
echo "============================="
echo "请准备好主臂，按回车开始..."
read

"$LEROBOT_CALIBRATE" \
  --teleop.type=so101_leader \
  --teleop.port="$LEADER_PORT" \
  --teleop.id="$LEADER_ID"

echo ""
echo "============================="
echo "全部标定完成!"
echo "============================="
echo ""
echo "标定文件位置:"
ls -la ~/.cache/huggingface/lerobot/calibration/robots/ 2>/dev/null
ls -la ~/.cache/huggingface/lerobot/calibration/teleoperators/ 2>/dev/null
echo ""
echo "下一步: 运行遥操作验证"
echo "  bash control_scripts/08_teleoperate_so101.sh"
