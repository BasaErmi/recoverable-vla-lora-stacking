#!/bin/bash
# ============================================================
# SO101 wrist-roll live monitor
#
# Usage:
#   conda activate evo-rl
#   bash control_scripts/13_monitor_wrist_roll.sh leader
#   bash control_scripts/13_monitor_wrist_roll.sh follower
#
# This is read-only: it opens the Feetech bus, reads positions, and does not
# write Goal_Position, torque, calibration, or PID registers.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SIDE="${1:-leader}"
MOTOR="${MOTOR:-wrist_roll}"
INTERVAL="${INTERVAL:-0.25}"

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
CALIBRATION_ROOT="${HF_LEROBOT_CALIBRATION:-$HOME/.cache/huggingface/lerobot/calibration}"

if [ -x "$HOME/anaconda3/envs/evo-rl/bin/python" ]; then
    PYTHON_BIN="${PYTHON_BIN:-$HOME/anaconda3/envs/evo-rl/bin/python}"
else
    PYTHON_BIN="${PYTHON_BIN:-python}"
fi

case "$SIDE" in
    -h|--help)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    leader)
        PORT="${PORT:-$LEADER_PORT}"
        CALIBRATION_FILE="${CALIBRATION_FILE:-$CALIBRATION_ROOT/teleoperators/so_leader/${LEADER_ID}.json}"
        ;;
    follower)
        PORT="${PORT:-$FOLLOWER_PORT}"
        CALIBRATION_FILE="${CALIBRATION_FILE:-$CALIBRATION_ROOT/robots/so_follower/${FOLLOWER_ID}.json}"
        ;;
    *)
        echo "ERROR: side must be 'leader' or 'follower'." >&2
        exit 1
        ;;
esac

if [ ! -e "$PORT" ]; then
    echo "ERROR: serial port not found: $PORT" >&2
    exit 1
fi

if [ ! -f "$CALIBRATION_FILE" ]; then
    echo "ERROR: calibration file not found: $CALIBRATION_FILE" >&2
    exit 1
fi

if lsof "$PORT" >/dev/null 2>&1; then
    echo "ERROR: serial port is already in use: $PORT" >&2
    lsof "$PORT" || true
    exit 1
fi

echo "=== SO101 Wrist-Roll Monitor ==="
echo "Side: $SIDE"
echo "Port: $PORT"
echo "Motor: $MOTOR"
echo "Calibration: $CALIBRATION_FILE"
echo "Interval: ${INTERVAL}s"
echo ""
echo "Goal for teleop recovery: make raw return inside calibration range, ideally near center."
echo "Press Ctrl-C to stop."
echo ""

SIDE="$SIDE" \
PORT="$PORT" \
MOTOR="$MOTOR" \
INTERVAL="$INTERVAL" \
CALIBRATION_FILE="$CALIBRATION_FILE" \
PYTHONPATH="/home/ubuntu/Evo-RL/src" \
"$PYTHON_BIN" - <<'PY'
import os
import time
from pathlib import Path

import draccus

from lerobot.motors import Motor, MotorCalibration, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus


side = os.environ["SIDE"]
port = os.environ["PORT"]
motor_to_watch = os.environ["MOTOR"]
interval = float(os.environ["INTERVAL"])
calibration_file = Path(os.environ["CALIBRATION_FILE"])

body_mode = MotorNormMode.RANGE_M100_100
motors = {
    "shoulder_pan": Motor(1, "sts3215", body_mode),
    "shoulder_lift": Motor(2, "sts3215", body_mode),
    "elbow_flex": Motor(3, "sts3215", body_mode),
    "wrist_flex": Motor(4, "sts3215", body_mode),
    "wrist_roll": Motor(5, "sts3215", body_mode),
    "gripper": Motor(6, "sts3215", MotorNormMode.RANGE_0_100),
}

with calibration_file.open() as f:
    calibration = draccus.load(dict[str, MotorCalibration], f)

if motor_to_watch not in motors:
    raise SystemExit(f"Unknown motor '{motor_to_watch}'. Valid motors: {', '.join(motors)}")

cal = calibration[motor_to_watch]
center = (cal.range_min + cal.range_max) / 2
center_tol = max(50, (cal.range_max - cal.range_min) * 0.08)

print(
    f"Connected target: {side} {motor_to_watch} | "
    f"range=[{cal.range_min}, {cal.range_max}] center={center:.1f} center_tol=+/-{center_tol:.1f}"
)
print(f"{'time':>8} {'raw':>8} {'norm':>9} {'status':>16}  guidance")

bus = FeetechMotorsBus(port=port, motors=motors, calibration=calibration)
start = time.time()

try:
    bus.connect()
    while True:
        raw = bus.read("Present_Position", motor_to_watch, normalize=False, num_retry=3)
        norm = bus.read("Present_Position", motor_to_watch, normalize=True, num_retry=3)

        if raw > cal.range_max:
            status = "OUT_HIGH"
            guidance = "turn in the direction that makes raw decrease"
        elif raw < cal.range_min:
            status = "OUT_LOW"
            guidance = "turn in the direction that makes raw increase"
        elif abs(raw - center) <= center_tol:
            status = "CENTER_OK"
            guidance = "good: near center for teleop"
        else:
            status = "IN_RANGE"
            guidance = "usable; keep moving toward center if needed"

        print(f"{time.time() - start:8.2f} {raw:8.0f} {norm:9.3f} {status:>16}  {guidance}", flush=True)
        time.sleep(interval)
except KeyboardInterrupt:
    print("\nStopped.")
finally:
    if bus.is_connected:
        bus.disconnect(disable_torque=False)
PY
