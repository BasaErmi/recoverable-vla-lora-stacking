#!/bin/bash
# ============================================================
# SO101 pick-letter deployment with logs
#
# Usage:
#   conda activate evo-rl
#   bash control_scripts/12_deploy_pick_letter.sh C
#   bash control_scripts/12_deploy_pick_letter.sh "pick up the letter U"
#
# Stop/status helpers:
#   bash control_scripts/12_deploy_pick_letter.sh --stop
#   bash control_scripts/12_deploy_pick_letter.sh --status
#   bash control_scripts/12_deploy_pick_letter.sh --stop-server
#
# Ctrl-C stops the local robot client. The lab policy server is intentionally
# left running so the checkpoint does not need to reload between tests.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Lab/server config ---
# Use LAB_HOST=local when this control checkout is running directly on the lab
# machine. Set LAB_HOST=lab or another SSH host only for a split Mac->lab setup.
LAB_HOST="${LAB_HOST:-local}"
if [ -z "${LAB_IP:-}" ]; then
    case "$LAB_HOST" in
        local|localhost|127.0.0.1)
            LAB_IP="127.0.0.1"
            ;;
        *)
            LAB_IP="10.31.1.254"
            ;;
    esac
fi
LAB_PORT="${LAB_PORT:-8080}"
SERVER_ADDRESS="${SERVER_ADDRESS:-${LAB_IP}:${LAB_PORT}}"
REMOTE_DEPLOY_DIR="${REMOTE_DEPLOY_DIR:-/home/ubuntu/outputs/deploy}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-/home/ubuntu/Evo-RL}"
REMOTE_PYTHON="${REMOTE_PYTHON:-/home/ubuntu/anaconda3/envs/evo-rl/bin/python}"
LOCAL_REPO_DIR="${LOCAL_REPO_DIR:-$REMOTE_REPO_DIR}"

# --- Robot config ---
if [ -z "${FOLLOWER_PORT:-}" ]; then
    if [ -e "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00" ]; then
        FOLLOWER_PORT="/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00"
    else
        FOLLOWER_PORT="/dev/tty.usbmodem5B140327031"
    fi
fi
FOLLOWER_ID="${FOLLOWER_ID:-my_follower}"
CALIBRATION_ROOT="${HF_LEROBOT_CALIBRATION:-$HOME/.cache/huggingface/lerobot/calibration}"
DEFAULT_FOLLOWER_CALIBRATION_FILE="$CALIBRATION_ROOT/robots/so_follower/${FOLLOWER_ID}.json"
FALLBACK_FOLLOWER_CALIBRATION_FILE="/home/ubuntu/data/guanlin8/cuhksz_pick_C_corrective_20260426/meta/calibration/follower_${FOLLOWER_ID}.json"
if [ -z "${FOLLOWER_CALIBRATION_FILE:-}" ] && [ ! -f "$DEFAULT_FOLLOWER_CALIBRATION_FILE" ] && [ -f "$FALLBACK_FOLLOWER_CALIBRATION_FILE" ]; then
    FOLLOWER_CALIBRATION_FILE="$FALLBACK_FOLLOWER_CALIBRATION_FILE"
else
    FOLLOWER_CALIBRATION_FILE="${FOLLOWER_CALIBRATION_FILE:-$DEFAULT_FOLLOWER_CALIBRATION_FILE}"
fi
AUTO_USE_CALIBRATION="${AUTO_USE_CALIBRATION:-1}"

# --- Policy/checkpoint config ---
POLICY_TYPE="${POLICY_TYPE:-act}"
MODEL_PATH="${MODEL_PATH:-/home/ubuntu/outputs/train/act_cuhksz_pick_place_slots_ordered_b8_100000_20260430_195941/checkpoints/100000/pretrained_model}"

# --- Deployment defaults ---
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-5}"
CLIENT_FPS="${CLIENT_FPS:-30}"
ACTIONS_PER_CHUNK="${ACTIONS_PER_CHUNK:-50}"
CHUNK_SIZE_THRESHOLD="${CHUNK_SIZE_THRESHOLD:-0.5}"
ACTION_EMA_ALPHA="${ACTION_EMA_ALPHA:-0.35}"
ACTION_MAX_DELTA="${ACTION_MAX_DELTA:-5}"
GRIPPER_ACTION_MAX_DELTA="${GRIPPER_ACTION_MAX_DELTA:-$ACTION_MAX_DELTA}"
GRIPPER_MAX_RELATIVE_TARGET="${GRIPPER_MAX_RELATIVE_TARGET:-100}"
LOG_ACTIONS="${LOG_ACTIONS:-1}"
AGGREGATE_FN_NAME="${AGGREGATE_FN_NAME:-weighted_average}"
# JPEG-compress image observations before sending them to lab. q85 keeps the
# current two-camera payload around 1 MB/s at 10Hz on the current scene.
if [ -z "${OBS_IMAGE_JPEG_QUALITY:-}" ]; then
    case "$LAB_HOST" in
        local|localhost|127.0.0.1)
            OBS_IMAGE_JPEG_QUALITY="0"
            ;;
        *)
            OBS_IMAGE_JPEG_QUALITY="85"
            ;;
    esac
fi
LOG_OBSERVATION_TRANSPORT="${LOG_OBSERVATION_TRANSPORT:-0}"
# Realtime mode: keep local motor control running even if remote observation
# upload stalls. A single-slot queue drops old frames and sends only the latest.
ASYNC_OBSERVATION_SEND="${ASYNC_OBSERVATION_SEND:-1}"
OBSERVATION_SEND_QUEUE_SIZE="${OBSERVATION_SEND_QUEUE_SIZE:-1}"
OBSERVATION_SEND_TIMEOUT_MS="${OBSERVATION_SEND_TIMEOUT_MS:-800}"
MAX_ACTION_AGE_MS="${MAX_ACTION_AGE_MS:-500}"
REBASE_ACTION_TIMESTAMPS_ON_RECEIVE="${REBASE_ACTION_TIMESTAMPS_ON_RECEIVE:-1}"
SINGLE_ACTION_REQUEST_IN_FLIGHT="${SINGLE_ACTION_REQUEST_IN_FLIGHT:-1}"
ACTION_COMMIT_HORIZON="${ACTION_COMMIT_HORIZON:-12}"
# End-to-end timing diagnostics. Keep enabled while investigating jerky rollout.
DIAGNOSTIC_LOGS="${DIAGNOSTIC_LOGS:-1}"
DIAGNOSTIC_EVERY_N="${DIAGNOSTIC_EVERY_N:-1}"
RESTART_SERVER_FOR_DIAGNOSTICS="${RESTART_SERVER_FOR_DIAGNOSTICS:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-1000}"
CAMERA_MAX_CONSECUTIVE_READ_FAILURES="${CAMERA_MAX_CONSECUTIVE_READ_FAILURES:-10}"
CAMERA_RESTART_ON_READ_FAILURE="${CAMERA_RESTART_ON_READ_FAILURE:-1}"
CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS="${CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS:-0}"
CAMERA_READ_FAILURE_BACKOFF_MS="${CAMERA_READ_FAILURE_BACKOFF_MS:-0}"
CAMERA_DIAG_INTERVAL_S="${CAMERA_DIAG_INTERVAL_S:-5}"
CAMERA_FRAME_GAP_WARN_MS="${CAMERA_FRAME_GAP_WARN_MS:-200}"
STOP_ON_OBSERVATION_ERROR="${STOP_ON_OBSERVATION_ERROR:-1}"
OBSERVATION_ERROR_LIMIT="${OBSERVATION_ERROR_LIMIT:-3}"
DEPLOY_KERNEL_LOG="${DEPLOY_KERNEL_LOG:-1}"
DEPLOY_SYSTEM_STATS_LOG="${DEPLOY_SYSTEM_STATS_LOG:-1}"
DEPLOY_SYSTEM_STATS_INTERVAL_S="${DEPLOY_SYSTEM_STATS_INTERVAL_S:-1}"

# Camera defaults match the datasets/checkpoints. Override only after running
# control_scripts/17_so101_camera_soak_test.sh and confirming the new settings are stable.
DEFAULT_FRONT_CAMERA_PATH="/dev/v4l/by-id/usb-icSpring_icspring_camera_202404160005-video-index0"
DEFAULT_WRIST_CAMERA_PATH="/dev/v4l/by-id/usb-CN02KX4NLG0004ABK00_USB_Camera_CN02KX4NLG0004ABK00-video-index0"
if [ -z "${FRONT_CAMERA_INDEX:-}" ]; then
    FRONT_CAMERA_INDEX="$DEFAULT_FRONT_CAMERA_PATH"
fi
FRONT_CAMERA_WIDTH="${FRONT_CAMERA_WIDTH:-640}"
FRONT_CAMERA_HEIGHT="${FRONT_CAMERA_HEIGHT:-480}"
FRONT_CAMERA_FPS="${FRONT_CAMERA_FPS:-30}"
FRONT_CAMERA_BACKEND="${FRONT_CAMERA_BACKEND:-}"
FRONT_CAMERA_FOURCC="${FRONT_CAMERA_FOURCC-MJPG}"
FRONT_CAMERA_WARMUP_S="${FRONT_CAMERA_WARMUP_S:-1}"
if [ -z "${WRIST_CAMERA_INDEX:-}" ]; then
    WRIST_CAMERA_INDEX="$DEFAULT_WRIST_CAMERA_PATH"
fi
WRIST_CAMERA_WIDTH="${WRIST_CAMERA_WIDTH:-1280}"
WRIST_CAMERA_HEIGHT="${WRIST_CAMERA_HEIGHT:-720}"
WRIST_CAMERA_FPS="${WRIST_CAMERA_FPS:-30}"
WRIST_CAMERA_BACKEND="${WRIST_CAMERA_BACKEND:-}"
WRIST_CAMERA_FOURCC="${WRIST_CAMERA_FOURCC:-MJPG}"
WRIST_CAMERA_WARMUP_S="${WRIST_CAMERA_WARMUP_S:-3}"
ALLOW_BUILTIN_CAMERA="${ALLOW_BUILTIN_CAMERA:-0}"
STRICT_CAMERA_NAME_GUARD="${STRICT_CAMERA_NAME_GUARD:-0}"

# --- Local runtime/log config ---
if [ -x "$HOME/anaconda3/envs/evo-rl/bin/python" ]; then
    PYTHON_BIN="${PYTHON_BIN:-$HOME/anaconda3/envs/evo-rl/bin/python}"
else
    PYTHON_BIN="${PYTHON_BIN:-python}"
fi
LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/outputs/deploy_logs}"

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

is_local_lab() {
    case "$LAB_HOST" in
        local|localhost|127.0.0.1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

lab_exec() {
    local command="$1"

    if is_local_lab; then
        bash -lc "$command"
    else
        ssh "$LAB_HOST" "$command"
    fi
}

camera_spec() {
    local name="$1"
    local index="$2"
    local width="$3"
    local height="$4"
    local fps="$5"
    local backend="$6"
    local fourcc="$7"
    local warmup_s="$8"
    local spec=""

    spec="$name: {type: opencv, index_or_path: $index, width: $width, height: $height, fps: $fps, warmup_s: $warmup_s"
    if [ -n "$backend" ]; then
        spec="$spec, backend: $backend"
    fi
    if [ -n "$fourcc" ]; then
        spec="$spec, fourcc: $fourcc"
    fi
    spec="$spec}"
    printf '%s' "$spec"
}

camera_device_node() {
    local index_or_path="$1"
    if [[ "$index_or_path" =~ ^[0-9]+$ ]]; then
        printf '/dev/video%s' "$index_or_path"
    else
        printf '%s' "$index_or_path"
    fi
}

macos_camera_devices() {
    if ! command -v ffmpeg >/dev/null 2>&1; then
        return 1
    fi
    { ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true; } \
        | sed -n '/AVFoundation video devices:/,/AVFoundation audio devices:/p'
}

macos_camera_name_for_index() {
    local index="$1"
    macos_camera_devices \
        | sed -n "s/^.*\\[$index\\] //p" \
        | head -1
}

validate_camera_indexes() {
    local front_name=""
    local wrist_name=""

    if [ "$(uname -s)" != "Darwin" ]; then
        return 0
    fi
    if ! command -v ffmpeg >/dev/null 2>&1; then
        echo "WARNING: ffmpeg not found; cannot verify macOS AVFoundation camera indexes." >&2
        return 0
    fi

    front_name="$(macos_camera_name_for_index "$FRONT_CAMERA_INDEX")"
    wrist_name="$(macos_camera_name_for_index "$WRIST_CAMERA_INDEX")"

    echo "macOS camera map:" >&2
    macos_camera_devices >&2
    echo "Selected front OpenCV index=$FRONT_CAMERA_INDEX AVFoundation_name_hint=${front_name:-UNKNOWN}" >&2
    echo "Selected wrist OpenCV index=$WRIST_CAMERA_INDEX AVFoundation_name_hint=${wrist_name:-UNKNOWN}" >&2

    if [ -z "$front_name" ] || [ -z "$wrist_name" ]; then
        echo "ERROR: selected camera index was not found. Override FRONT_CAMERA_INDEX/WRIST_CAMERA_INDEX after checking the map above." >&2
        exit 1
    fi
    if [ "$FRONT_CAMERA_INDEX" = "$WRIST_CAMERA_INDEX" ]; then
        echo "ERROR: front and wrist camera indexes are the same." >&2
        exit 1
    fi
    if [ "$ALLOW_BUILTIN_CAMERA" != "1" ]; then
        case "$front_name $wrist_name" in
            *FaceTime*|*"Capture screen"*|*Continuity*)
                echo "WARNING: AVFoundation name hint includes a built-in/virtual camera. On this Mac, AVFoundation names may not match OpenCV indexes; verify the actual images with control_scripts/19_preview_camera_indices.sh before deployment." >&2
                if [ "$STRICT_CAMERA_NAME_GUARD" = "1" ]; then
                    echo "ERROR: STRICT_CAMERA_NAME_GUARD=1 rejected this camera selection." >&2
                    exit 1
                fi
                ;;
        esac
    fi
}

validate_linux_camera_nodes() {
    if [ "$(uname -s)" != "Linux" ]; then
        return 0
    fi

    local missing=0
    local front_node
    local wrist_node
    front_node="$(camera_device_node "$FRONT_CAMERA_INDEX")"
    wrist_node="$(camera_device_node "$WRIST_CAMERA_INDEX")"

    for item in "front:$front_node" "wrist:$wrist_node"; do
        local name="${item%%:*}"
        local node="${item#*:}"
        if [ ! -e "$node" ]; then
            echo "ERROR: $name camera node not found: $node" >&2
            missing=1
            continue
        fi
        if [[ "$node" == /dev/v4l/by-id/* ]]; then
            echo "$name camera: $node -> $(readlink -f "$node")" >&2
        else
            echo "$name camera: $node" >&2
        fi
    done

    if [ "$missing" = "1" ]; then
        echo "" >&2
        echo "Current /dev/v4l/by-id:" >&2
        ls -l /dev/v4l/by-id 2>&1 >&2 || true
        echo "" >&2
        echo "The deploy script now requires the stable by-id camera paths by default." >&2
        echo "If the wrist camera is missing, replug/move the wrist camera, then run:" >&2
        echo "  sudo control_scripts/22_disable_usb_power_save.sh" >&2
        echo "  bash control_scripts/12_deploy_pick_letter.sh --status" >&2
        exit 1
    fi
}

status() {
    echo "=== Local robot client ==="
    pgrep -af "lerobot.async_inference.robot_client" || true
    echo ""
    echo "=== Local serial ports ==="
    lsof "$FOLLOWER_PORT" 2>/dev/null || true
    echo ""
    echo "=== Lab policy server ==="
    lab_exec "ps -ef | grep -E 'lerobot.async_inference.policy_server|policy_server' | grep -v grep || true; ss -ltnp 2>/dev/null | grep ':$LAB_PORT' || true; nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits" || true
}

stop_client() {
    echo "Stopping local robot client..."
    stop_robot_client_processes
    disable_follower_torque
    lsof "$FOLLOWER_PORT" 2>/dev/null || true
}

stop_robot_client_processes() {
    pkill -INT -f "lerobot.async_inference.robot_client" 2>/dev/null || true
    sleep 2
    pkill -TERM -f "lerobot.async_inference.robot_client" 2>/dev/null || true
}

stop_server() {
    echo "Stopping lab policy server..."
    lab_exec "pkill -TERM -f 'lerobot.async_inference.policy_server' 2>/dev/null || true; sleep 2; ss -ltnp 2>/dev/null | grep ':$LAB_PORT' || true; nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits" || true
}

ensure_server() {
    local run_id="$1"
    local server_log=""

    if lab_exec "ss -ltnp 2>/dev/null | grep -q ':$LAB_PORT'"; then
        if [ "$DIAGNOSTIC_LOGS" = "1" ] && [ "$RESTART_SERVER_FOR_DIAGNOSTICS" = "1" ]; then
            echo "Restarting lab policy server so diagnostic logging is active..." >&2
            lab_exec "pkill -TERM -f 'lerobot.async_inference.policy_server' 2>/dev/null || true"
            for _ in $(seq 1 10); do
                if ! lab_exec "ss -ltnp 2>/dev/null | grep -q ':$LAB_PORT'"; then
                    break
                fi
                sleep 1
            done
        else
            server_log="$(lab_exec "ls -t $REMOTE_DEPLOY_DIR/policy_server_*_pick_*.log 2>/dev/null | head -1 || true")"
            echo "Lab policy server already listening on :$LAB_PORT" >&2
            echo "$server_log"
            return 0
        fi
    fi

    if lab_exec "ss -ltnp 2>/dev/null | grep -q ':$LAB_PORT'"; then
        server_log="$(lab_exec "ls -t $REMOTE_DEPLOY_DIR/policy_server_*_pick_*.log 2>/dev/null | head -1 || true")"
        echo "Lab policy server still listening on :$LAB_PORT" >&2
    else
        server_log="$REMOTE_DEPLOY_DIR/policy_server_${POLICY_TYPE}_pick_${run_id}.log"
        echo "Starting lab policy server..." >&2
        lab_exec "mkdir -p '$REMOTE_DEPLOY_DIR'; cd '$REMOTE_REPO_DIR'; nohup bash -lc 'HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_DATASETS_OFFLINE=1 LEROBOT_DIAGNOSTIC_LOGS=$DIAGNOSTIC_LOGS LEROBOT_DIAGNOSTIC_EVERY_N=$DIAGNOSTIC_EVERY_N PYTHONPATH=$REMOTE_REPO_DIR/src $REMOTE_PYTHON -m lerobot.async_inference.policy_server --host=0.0.0.0 --port=$LAB_PORT --fps=30' > '$server_log' 2>&1 &"

        for _ in $(seq 1 60); do
            if lab_exec "ss -ltnp 2>/dev/null | grep -q ':$LAB_PORT'"; then
                break
            fi
            sleep 1
        done

        if ! lab_exec "ss -ltnp 2>/dev/null | grep -q ':$LAB_PORT'"; then
            echo "ERROR: lab policy server did not start. Check: $server_log" >&2
            exit 1
        fi
    fi

    echo "$server_log"
}

disable_follower_torque() {
    if [ ! -e "$FOLLOWER_PORT" ]; then
        echo "Follower port not found; cannot disable torque: $FOLLOWER_PORT" >&2
        return 0
    fi

    if lsof "$FOLLOWER_PORT" >/dev/null 2>&1; then
        echo "Follower port still in use; skipping direct torque disable: $FOLLOWER_PORT" >&2
        return 0
    fi

    PYTHONPATH="$LOCAL_REPO_DIR/src" \
    FOLLOWER_PORT="$FOLLOWER_PORT" \
    FOLLOWER_CALIBRATION_FILE="$FOLLOWER_CALIBRATION_FILE" \
    "$PYTHON_BIN" - <<'PY' || true
import os
import time
from pathlib import Path

import draccus

from lerobot.motors import Motor, MotorCalibration, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

port = os.environ["FOLLOWER_PORT"]
calibration_file = Path(os.environ["FOLLOWER_CALIBRATION_FILE"])

if calibration_file.exists():
    with calibration_file.open() as f:
        calibration = draccus.load(dict[str, MotorCalibration], f)
else:
    print(f"WARNING: follower calibration file not found; using raw torque-off only: {calibration_file}")
    calibration = None

body_mode = MotorNormMode.RANGE_M100_100
body_motors = {
    "shoulder_pan": Motor(1, "sts3215", body_mode),
    "shoulder_lift": Motor(2, "sts3215", body_mode),
    "elbow_flex": Motor(3, "sts3215", body_mode),
    "wrist_flex": Motor(4, "sts3215", body_mode),
    "wrist_roll": Motor(5, "sts3215", body_mode),
}
gripper_motor = {
    "gripper": Motor(6, "sts3215", MotorNormMode.RANGE_0_100),
}

def _subset_calibration(motors: dict[str, Motor]) -> dict[str, MotorCalibration] | None:
    if calibration is None:
        return None
    return {motor: calibration[motor] for motor in motors if motor in calibration}


def read_torque_states(bus: FeetechMotorsBus, motors: dict[str, Motor]) -> dict[str, int | str]:
    states = {}
    for motor in motors:
        try:
            states[motor] = bus.read("Torque_Enable", motor, normalize=False, num_retry=10)
        except Exception as exc:
            states[motor] = f"UNKNOWN({type(exc).__name__})"
    return states


def disable_subset(name: str, motors: dict[str, Motor]) -> bool:
    subset_calibration = _subset_calibration(motors)
    bus = FeetechMotorsBus(port, motors, subset_calibration)
    try:
        bus.connect()
        bus.disable_torque(num_retry=10)
        states = read_torque_states(bus, motors)
        print(f"Disabled follower torque for {name}: {states}")
        return all(value == 0 for value in states.values())
    except Exception as exc:
        print(f"WARNING: failed to disable follower torque for {name}: {type(exc).__name__}: {exc}")
        return False
    finally:
        if bus.is_connected:
            bus.disconnect(disable_torque=False)

def blind_disable_subset(name: str, motors: dict[str, Motor]) -> bool:
    """Best-effort stop path for motors that do not answer ping/readback.

    Gripper motor 6 can temporarily stop responding after a tight close or
    overload protection. Handshake-based connect then raises "missing motor",
    but a sync-write can still put a torque-off packet on the bus without
    waiting for a status packet from the motor.
    """
    subset_calibration = _subset_calibration(motors)
    bus = FeetechMotorsBus(port, motors, subset_calibration)
    try:
        bus.connect(handshake=False)
        bus.port_handler.clearPort()
        zeroes = {motor: 0 for motor in motors}
        for _ in range(3):
            bus.sync_write("Torque_Enable", zeroes, normalize=False, num_retry=10)
            bus.sync_write("Lock", zeroes, normalize=False, num_retry=10)
            time.sleep(0.05)
        states = read_torque_states(bus, motors)
        print(f"Blind torque-off sent for {name}: {states}")
        return all(value == 0 for value in states.values())
    except Exception as exc:
        print(f"WARNING: blind torque-off failed for {name}: {type(exc).__name__}: {exc}")
        return False
    finally:
        if bus.is_connected:
            bus.disconnect(disable_torque=False)

body_ok = disable_subset("body motors 1-5", body_motors)
gripper_ok = disable_subset("gripper motor 6", gripper_motor)
if not gripper_ok:
    gripper_ok = blind_disable_subset("gripper motor 6", gripper_motor)
if not body_ok or not gripper_ok:
    print("WARNING: torque-off was incomplete. Use physical power cutoff if any joint remains stiff.")
PY
}

log_usb_snapshot() {
    local stage="$1"
    local front_node
    local wrist_node
    front_node="$(camera_device_node "$FRONT_CAMERA_INDEX")"
    wrist_node="$(camera_device_node "$WRIST_CAMERA_INDEX")"

    {
        echo "===== USB SNAPSHOT stage=$stage time=$(date -Is) ====="
        echo "--- selected settings ---"
        echo "front=$front_node ${FRONT_CAMERA_WIDTH}x${FRONT_CAMERA_HEIGHT}@${FRONT_CAMERA_FPS} fourcc=${FRONT_CAMERA_FOURCC:-default}"
        echo "wrist=$wrist_node ${WRIST_CAMERA_WIDTH}x${WRIST_CAMERA_HEIGHT}@${WRIST_CAMERA_FPS} fourcc=${WRIST_CAMERA_FOURCC:-default}"
        echo "follower_port=$FOLLOWER_PORT"
        echo "--- /dev/video* ---"
        ls -l /dev/video* 2>&1 || true
        echo "--- /dev/serial/by-id ---"
        ls -l /dev/serial/by-id 2>&1 || true
        echo "--- lsusb -t ---"
        lsusb -t 2>&1 || true
        echo "--- lsusb ---"
        lsusb 2>&1 || true
        echo "--- selected video sysfs/udev ---"
        for node in "$front_node" "$wrist_node"; do
            echo "[$node]"
            if [ ! -e "$node" ]; then
                echo "missing"
                continue
            fi
            local resolved_node
            resolved_node="$(readlink -f "$node" 2>/dev/null || printf '%s' "$node")"
            echo "resolved_node=$resolved_node"
            local base
            base="$(basename "$resolved_node")"
            local sysfs="/sys/class/video4linux/$base"
            if [ -e "$sysfs/name" ]; then
                echo "name=$(cat "$sysfs/name")"
            fi
            if [ -e "$sysfs/device" ]; then
                echo "sysfs_device=$(readlink -f "$sysfs/device" 2>/dev/null || true)"
                udevadm info -q property -p "$sysfs/device" 2>/dev/null \
                    | grep -E '^(DEVNAME|ID_PATH|ID_PATH_TAG|ID_MODEL|ID_MODEL_ID|ID_VENDOR|ID_VENDOR_ID|ID_SERIAL|ID_SERIAL_SHORT|ID_USB_DRIVER|ID_V4L_PRODUCT|ID_V4L_VERSION)=' \
                    || true
            fi
        done
        echo "--- selected USB runtime/power state ---"
        for node in "$front_node" "$wrist_node"; do
            [ -e "$node" ] || continue
            local resolved_node
            resolved_node="$(readlink -f "$node" 2>/dev/null || printf '%s' "$node")"
            local base
            base="$(basename "$resolved_node")"
            local device_path
            device_path="$(readlink -f "/sys/class/video4linux/$base/device" 2>/dev/null || true)"
            echo "[$node] resolved_node=$resolved_node device_path=$device_path"
            local cursor="$device_path"
            while [ -n "$cursor" ] && [ "$cursor" != "/" ]; do
                if [ -e "$cursor/idVendor" ] && [ -e "$cursor/idProduct" ]; then
                    echo "usb_device=$cursor vendor=$(cat "$cursor/idVendor") product=$(cat "$cursor/idProduct") speed=$(cat "$cursor/speed" 2>/dev/null || true) busnum=$(cat "$cursor/busnum" 2>/dev/null || true) devnum=$(cat "$cursor/devnum" 2>/dev/null || true)"
                    [ -e "$cursor/power/control" ] && echo "power_control=$(cat "$cursor/power/control")"
                    [ -e "$cursor/power/runtime_status" ] && echo "runtime_status=$(cat "$cursor/power/runtime_status")"
                    break
                fi
                cursor="$(dirname "$cursor")"
            done
        done
        echo "--- recent kernel USB/UVC lines ---"
        journalctl -k --since "5 minutes ago" --no-pager 2>/dev/null \
            | grep -Ei 'usb|uvc|video|xhci' \
            | tail -120 \
            || true
        echo ""
    } >> "$USB_SNAPSHOT_LOG" 2>&1
}

KERNEL_MONITOR_PID=""
SYSTEM_STATS_MONITOR_PID=""

start_background_monitors() {
    if [ "$DEPLOY_KERNEL_LOG" = "1" ] && command -v journalctl >/dev/null 2>&1; then
        (journalctl -kf -o short-iso --since now) > "$KERNEL_LOG" 2>&1 &
        KERNEL_MONITOR_PID=$!
        echo "kernel_log=$KERNEL_LOG pid=$KERNEL_MONITOR_PID" >> "$RUN_INFO"
    fi

    if [ "$DEPLOY_SYSTEM_STATS_LOG" = "1" ]; then
        (
            while true; do
                echo "===== SYSTEM STATS time=$(date -Is) ====="
                echo "--- uptime/load ---"
                uptime || true
                cat /proc/loadavg 2>/dev/null || true
                echo "--- selected device nodes ---"
                ls -l "$(camera_device_node "$FRONT_CAMERA_INDEX")" "$(camera_device_node "$WRIST_CAMERA_INDEX")" "$FOLLOWER_PORT" 2>&1 || true
                echo "--- top processes ---"
                ps -eo pid,ppid,pcpu,pmem,stat,comm,args --sort=-pcpu | head -25 || true
                echo "--- relevant processes ---"
                ps -ef | grep -E 'lerobot.async_inference.robot_client|lerobot.async_inference.policy_server|python -m lerobot' | grep -v grep || true
                echo "--- pressure ---"
                for pressure in cpu io memory; do
                    [ -e "/proc/pressure/$pressure" ] && { echo "[$pressure]"; cat "/proc/pressure/$pressure"; }
                done
                echo "--- gpu ---"
                nvidia-smi --query-gpu=timestamp,memory.used,utilization.gpu,utilization.memory,power.draw,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true
                echo ""
                sleep "$DEPLOY_SYSTEM_STATS_INTERVAL_S"
            done
        ) > "$SYSTEM_STATS_LOG" 2>&1 &
        SYSTEM_STATS_MONITOR_PID=$!
        echo "system_stats_log=$SYSTEM_STATS_LOG pid=$SYSTEM_STATS_MONITOR_PID interval_s=$DEPLOY_SYSTEM_STATS_INTERVAL_S" >> "$RUN_INFO"
    fi
}

stop_background_monitors() {
    if [ -n "$KERNEL_MONITOR_PID" ] && kill -0 "$KERNEL_MONITOR_PID" 2>/dev/null; then
        kill "$KERNEL_MONITOR_PID" 2>/dev/null || true
        wait "$KERNEL_MONITOR_PID" 2>/dev/null || true
    fi
    if [ -n "$SYSTEM_STATS_MONITOR_PID" ] && kill -0 "$SYSTEM_STATS_MONITOR_PID" 2>/dev/null; then
        kill "$SYSTEM_STATS_MONITOR_PID" 2>/dev/null || true
        wait "$SYSTEM_STATS_MONITOR_PID" 2>/dev/null || true
    fi
}

append_recent_diagnostics_to_client_log() {
    {
        echo ""
        echo "=== Recent deploy diagnostics ==="
        echo "--- kernel.log tail ---"
        tail -120 "$KERNEL_LOG" 2>/dev/null || true
        echo "--- usb_snapshot.log tail ---"
        tail -220 "$USB_SNAPSHOT_LOG" 2>/dev/null || true
        echo "--- system_stats.log tail ---"
        tail -160 "$SYSTEM_STATS_LOG" 2>/dev/null || true
    } >> "$CLIENT_LOG" 2>&1
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

if [ $# -eq 0 ]; then
    TASK="pick up the letter C"
elif [ $# -eq 1 ] && [[ "$1" =~ ^[CUHKcuhk]$ ]]; then
    LETTER="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    TASK="pick up the letter $LETTER"
else
    TASK="$*"
fi

SAFE_TASK="$(printf '%s' "$TASK" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_-' | tr -s '_')"
RUN_ID="$(date +%Y%m%d_%H%M%S)_${SAFE_TASK}"
RUN_DIR="$LOG_ROOT/$RUN_ID"
CLIENT_LOG="$RUN_DIR/robot_client.log"
RUN_INFO="$RUN_DIR/run_info.txt"
KERNEL_LOG="$RUN_DIR/kernel.log"
USB_SNAPSHOT_LOG="$RUN_DIR/usb_snapshot.log"
SYSTEM_STATS_LOG="$RUN_DIR/system_stats.log"
mkdir -p "$RUN_DIR"
CAMERA_CONFIG="{ $(camera_spec front "$FRONT_CAMERA_INDEX" "$FRONT_CAMERA_WIDTH" "$FRONT_CAMERA_HEIGHT" "$FRONT_CAMERA_FPS" "$FRONT_CAMERA_BACKEND" "$FRONT_CAMERA_FOURCC" "$FRONT_CAMERA_WARMUP_S"), $(camera_spec wrist "$WRIST_CAMERA_INDEX" "$WRIST_CAMERA_WIDTH" "$WRIST_CAMERA_HEIGHT" "$WRIST_CAMERA_FPS" "$WRIST_CAMERA_BACKEND" "$WRIST_CAMERA_FOURCC" "$WRIST_CAMERA_WARMUP_S") }"
validate_linux_camera_nodes
validate_camera_indexes

case "$(printf '%s' "$MAX_RELATIVE_TARGET" | tr '[:upper:]' '[:lower:]')" in
    ""|default|none|null|off|false)
        MAX_RELATIVE_TARGET_EFFECTIVE="default(None/no clamp)"
        ;;
    *)
        MAX_RELATIVE_TARGET_EFFECTIVE="$MAX_RELATIVE_TARGET"
        ;;
esac

if [ ! -e "$FOLLOWER_PORT" ]; then
    echo "ERROR: follower port not found: $FOLLOWER_PORT" >&2
    exit 1
fi

if pgrep -f "lerobot.async_inference.robot_client" >/dev/null; then
    echo "ERROR: a local robot client is already running. Stop it with:" >&2
    echo "  bash control_scripts/12_deploy_pick_letter.sh --stop" >&2
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
model_path=$MODEL_PATH
server_address=$SERVER_ADDRESS
lab_host=$LAB_HOST
server_log=$SERVER_LOG
client_log=$CLIENT_LOG
follower_port=$FOLLOWER_PORT
max_relative_target=$MAX_RELATIVE_TARGET_EFFECTIVE
auto_use_calibration=$AUTO_USE_CALIBRATION
follower_calibration_file=$FOLLOWER_CALIBRATION_FILE
client_fps=$CLIENT_FPS
actions_per_chunk=$ACTIONS_PER_CHUNK
chunk_size_threshold=$CHUNK_SIZE_THRESHOLD
action_ema_alpha=$ACTION_EMA_ALPHA
action_max_delta=$ACTION_MAX_DELTA
gripper_action_max_delta=$GRIPPER_ACTION_MAX_DELTA
gripper_max_relative_target=$GRIPPER_MAX_RELATIVE_TARGET
log_actions=$LOG_ACTIONS
aggregate_fn_name=$AGGREGATE_FN_NAME
action_commit_horizon=$ACTION_COMMIT_HORIZON
obs_image_jpeg_quality=$OBS_IMAGE_JPEG_QUALITY
log_observation_transport=$LOG_OBSERVATION_TRANSPORT
async_observation_send=$ASYNC_OBSERVATION_SEND
observation_send_queue_size=$OBSERVATION_SEND_QUEUE_SIZE
observation_send_timeout_ms=$OBSERVATION_SEND_TIMEOUT_MS
max_action_age_ms=$MAX_ACTION_AGE_MS
rebase_action_timestamps_on_receive=$REBASE_ACTION_TIMESTAMPS_ON_RECEIVE
single_action_request_in_flight=$SINGLE_ACTION_REQUEST_IN_FLIGHT
diagnostic_logs=$DIAGNOSTIC_LOGS
diagnostic_every_n=$DIAGNOSTIC_EVERY_N
restart_server_for_diagnostics=$RESTART_SERVER_FOR_DIAGNOSTICS
camera_max_age_ms=$CAMERA_MAX_AGE_MS
camera_max_consecutive_read_failures=$CAMERA_MAX_CONSECUTIVE_READ_FAILURES
camera_restart_on_read_failure=$CAMERA_RESTART_ON_READ_FAILURE
camera_transient_read_failure_max_age_ms=$CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS
camera_read_failure_backoff_ms=$CAMERA_READ_FAILURE_BACKOFF_MS
camera_diag_interval_s=$CAMERA_DIAG_INTERVAL_S
camera_frame_gap_warn_ms=$CAMERA_FRAME_GAP_WARN_MS
stop_on_observation_error=$STOP_ON_OBSERVATION_ERROR
observation_error_limit=$OBSERVATION_ERROR_LIMIT
kernel_log=$KERNEL_LOG
usb_snapshot_log=$USB_SNAPSHOT_LOG
system_stats_log=$SYSTEM_STATS_LOG
deploy_kernel_log=$DEPLOY_KERNEL_LOG
deploy_system_stats_log=$DEPLOY_SYSTEM_STATS_LOG
deploy_system_stats_interval_s=$DEPLOY_SYSTEM_STATS_INTERVAL_S
camera_config=$CAMERA_CONFIG
started_at=$(date)
stop_local_client=bash control_scripts/12_deploy_pick_letter.sh --stop
stop_lab_server=bash control_scripts/12_deploy_pick_letter.sh --stop-server
EOF

echo "=== SO101 Pick Deployment ===" | tee -a "$CLIENT_LOG"
echo "Run dir: $RUN_DIR" | tee -a "$CLIENT_LOG"
echo "Task: $TASK" | tee -a "$CLIENT_LOG"
echo "Model: $MODEL_PATH" | tee -a "$CLIENT_LOG"
echo "Server: $SERVER_ADDRESS" | tee -a "$CLIENT_LOG"
echo "Lab server log: $SERVER_LOG" | tee -a "$CLIENT_LOG"
echo "Local client log: $CLIENT_LOG" | tee -a "$CLIENT_LOG"
echo "Runtime: MAX_RELATIVE_TARGET=$MAX_RELATIVE_TARGET_EFFECTIVE CLIENT_FPS=$CLIENT_FPS ACTIONS_PER_CHUNK=$ACTIONS_PER_CHUNK CHUNK_SIZE_THRESHOLD=$CHUNK_SIZE_THRESHOLD" | tee -a "$CLIENT_LOG"
echo "Action controls: ACTION_EMA_ALPHA=$ACTION_EMA_ALPHA ACTION_MAX_DELTA=$ACTION_MAX_DELTA GRIPPER_ACTION_MAX_DELTA=$GRIPPER_ACTION_MAX_DELTA GRIPPER_MAX_RELATIVE_TARGET=$GRIPPER_MAX_RELATIVE_TARGET LOG_ACTIONS=$LOG_ACTIONS" | tee -a "$CLIENT_LOG"
echo "Chunk aggregation: AGGREGATE_FN_NAME=$AGGREGATE_FN_NAME ACTION_COMMIT_HORIZON=$ACTION_COMMIT_HORIZON" | tee -a "$CLIENT_LOG"
echo "Observation transport: OBS_IMAGE_JPEG_QUALITY=$OBS_IMAGE_JPEG_QUALITY LOG_OBSERVATION_TRANSPORT=$LOG_OBSERVATION_TRANSPORT ASYNC_OBSERVATION_SEND=$ASYNC_OBSERVATION_SEND OBSERVATION_SEND_QUEUE_SIZE=$OBSERVATION_SEND_QUEUE_SIZE OBSERVATION_SEND_TIMEOUT_MS=$OBSERVATION_SEND_TIMEOUT_MS MAX_ACTION_AGE_MS=$MAX_ACTION_AGE_MS REBASE_ACTION_TIMESTAMPS_ON_RECEIVE=$REBASE_ACTION_TIMESTAMPS_ON_RECEIVE SINGLE_ACTION_REQUEST_IN_FLIGHT=$SINGLE_ACTION_REQUEST_IN_FLIGHT" | tee -a "$CLIENT_LOG"
echo "Diagnostics: DIAGNOSTIC_LOGS=$DIAGNOSTIC_LOGS DIAGNOSTIC_EVERY_N=$DIAGNOSTIC_EVERY_N CAMERA_MAX_AGE_MS=$CAMERA_MAX_AGE_MS CAMERA_MAX_CONSECUTIVE_READ_FAILURES=$CAMERA_MAX_CONSECUTIVE_READ_FAILURES CAMERA_RESTART_ON_READ_FAILURE=$CAMERA_RESTART_ON_READ_FAILURE CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS=$CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS CAMERA_READ_FAILURE_BACKOFF_MS=$CAMERA_READ_FAILURE_BACKOFF_MS CAMERA_DIAG_INTERVAL_S=$CAMERA_DIAG_INTERVAL_S CAMERA_FRAME_GAP_WARN_MS=$CAMERA_FRAME_GAP_WARN_MS STOP_ON_OBSERVATION_ERROR=$STOP_ON_OBSERVATION_ERROR OBSERVATION_ERROR_LIMIT=$OBSERVATION_ERROR_LIMIT RESTART_SERVER_FOR_DIAGNOSTICS=$RESTART_SERVER_FOR_DIAGNOSTICS" | tee -a "$CLIENT_LOG"
echo "Deploy logs: kernel=$KERNEL_LOG usb_snapshot=$USB_SNAPSHOT_LOG system_stats=$SYSTEM_STATS_LOG" | tee -a "$CLIENT_LOG"
echo "Cameras: $CAMERA_CONFIG" | tee -a "$CLIENT_LOG"
echo "Calibration: AUTO_USE_CALIBRATION=$AUTO_USE_CALIBRATION FILE=$FOLLOWER_CALIBRATION_FILE" | tee -a "$CLIENT_LOG"
echo "" | tee -a "$CLIENT_LOG"
echo "Press Ctrl-C to stop the robot client. Keep one hand near power/estop." | tee -a "$CLIENT_LOG"
echo "" | tee -a "$CLIENT_LOG"

CLIENT_PID=""
cleanup() {
    echo "" | tee -a "$CLIENT_LOG"
    echo "Stopping robot client..." | tee -a "$CLIENT_LOG"
    log_usb_snapshot "cleanup_begin"
    if [ -n "$CLIENT_PID" ] && kill -0 "$CLIENT_PID" 2>/dev/null; then
        kill -INT "$CLIENT_PID" 2>/dev/null || true
        sleep 2
        if kill -0 "$CLIENT_PID" 2>/dev/null; then
            kill -TERM "$CLIENT_PID" 2>/dev/null || true
        fi
        wait "$CLIENT_PID" 2>/dev/null || true
    fi
    # The robot client is launched behind a shell pipeline/process substitution.
    # Kill by command name as a fallback so Ctrl-C cannot leave the real Python
    # child process still streaming actions after the launcher exits.
    stop_robot_client_processes
    disable_follower_torque | tee -a "$CLIENT_LOG"
    log_usb_snapshot "cleanup_end"
    stop_background_monitors
    append_recent_diagnostics_to_client_log
    echo "Stopped local client. Lab server is still running." | tee -a "$CLIENT_LOG"
    exit 130
}
trap cleanup INT TERM

if [ "$AUTO_USE_CALIBRATION" = "1" ] && [ ! -f "$FOLLOWER_CALIBRATION_FILE" ]; then
    echo "ERROR: AUTO_USE_CALIBRATION=1 but calibration file was not found:" >&2
    echo "  $FOLLOWER_CALIBRATION_FILE" >&2
    echo "Run calibration first, or set AUTO_USE_CALIBRATION=0 and start the client interactively." >&2
    exit 1
fi

log_usb_snapshot "before_client_start"
start_background_monitors

(
    cd "$LOCAL_REPO_DIR"
    feed_robot_client_stdin() {
        if [ "$AUTO_USE_CALIBRATION" = "1" ]; then
            # If the motor EEPROM calibration differs from the local file, SOFollower
            # prompts once. Feed exactly one ENTER to use the existing file, not to run
            # a full interactive recalibration.
            printf '\n'
        else
            cat
        fi
    }

    if [ "$MAX_RELATIVE_TARGET_EFFECTIVE" = "default(None/no clamp)" ]; then
        feed_robot_client_stdin | exec env \
          LEROBOT_ACTION_EMA_ALPHA="$ACTION_EMA_ALPHA" \
          LEROBOT_ACTION_MAX_DELTA="$ACTION_MAX_DELTA" \
          LEROBOT_GRIPPER_ACTION_MAX_DELTA="$GRIPPER_ACTION_MAX_DELTA" \
          LEROBOT_GRIPPER_MAX_RELATIVE_TARGET="$GRIPPER_MAX_RELATIVE_TARGET" \
          LEROBOT_LOG_ACTIONS="$LOG_ACTIONS" \
          LEROBOT_OBS_IMAGE_JPEG_QUALITY="$OBS_IMAGE_JPEG_QUALITY" \
          LEROBOT_LOG_OBSERVATION_TRANSPORT="$LOG_OBSERVATION_TRANSPORT" \
          LEROBOT_ASYNC_OBSERVATION_SEND="$ASYNC_OBSERVATION_SEND" \
          LEROBOT_OBSERVATION_SEND_QUEUE_SIZE="$OBSERVATION_SEND_QUEUE_SIZE" \
          LEROBOT_OBSERVATION_SEND_TIMEOUT_MS="$OBSERVATION_SEND_TIMEOUT_MS" \
          LEROBOT_MAX_ACTION_AGE_MS="$MAX_ACTION_AGE_MS" \
          LEROBOT_REBASE_ACTION_TIMESTAMPS_ON_RECEIVE="$REBASE_ACTION_TIMESTAMPS_ON_RECEIVE" \
          LEROBOT_SINGLE_ACTION_REQUEST_IN_FLIGHT="$SINGLE_ACTION_REQUEST_IN_FLIGHT" \
          LEROBOT_ACTION_COMMIT_HORIZON="$ACTION_COMMIT_HORIZON" \
          LEROBOT_DIAGNOSTIC_LOGS="$DIAGNOSTIC_LOGS" \
          LEROBOT_DIAGNOSTIC_EVERY_N="$DIAGNOSTIC_EVERY_N" \
          LEROBOT_CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
          LEROBOT_CAMERA_MAX_CONSECUTIVE_READ_FAILURES="$CAMERA_MAX_CONSECUTIVE_READ_FAILURES" \
          LEROBOT_CAMERA_RESTART_ON_READ_FAILURE="$CAMERA_RESTART_ON_READ_FAILURE" \
          LEROBOT_CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS="$CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS" \
          LEROBOT_CAMERA_READ_FAILURE_BACKOFF_MS="$CAMERA_READ_FAILURE_BACKOFF_MS" \
          LEROBOT_CAMERA_DIAG_INTERVAL_S="$CAMERA_DIAG_INTERVAL_S" \
          LEROBOT_CAMERA_FRAME_GAP_WARN_MS="$CAMERA_FRAME_GAP_WARN_MS" \
          LEROBOT_STOP_ON_OBSERVATION_ERROR="$STOP_ON_OBSERVATION_ERROR" \
          LEROBOT_OBSERVATION_ERROR_LIMIT="$OBSERVATION_ERROR_LIMIT" \
          PYTHONPATH=src "$PYTHON_BIN" -m lerobot.async_inference.robot_client \
          --robot.type=so101_follower \
          --robot.port="$FOLLOWER_PORT" \
          --robot.id="$FOLLOWER_ID" \
          --robot.cameras="$CAMERA_CONFIG" \
          --task="$TASK" \
          --server_address="$SERVER_ADDRESS" \
          --policy_type="$POLICY_TYPE" \
          --pretrained_name_or_path="$MODEL_PATH" \
          --policy_device=cuda \
          --client_device=cpu \
          --fps="$CLIENT_FPS" \
          --actions_per_chunk="$ACTIONS_PER_CHUNK" \
          --chunk_size_threshold="$CHUNK_SIZE_THRESHOLD" \
          --aggregate_fn_name="$AGGREGATE_FN_NAME"
    else
        feed_robot_client_stdin | exec env \
          LEROBOT_ACTION_EMA_ALPHA="$ACTION_EMA_ALPHA" \
          LEROBOT_ACTION_MAX_DELTA="$ACTION_MAX_DELTA" \
          LEROBOT_GRIPPER_ACTION_MAX_DELTA="$GRIPPER_ACTION_MAX_DELTA" \
          LEROBOT_GRIPPER_MAX_RELATIVE_TARGET="$GRIPPER_MAX_RELATIVE_TARGET" \
          LEROBOT_LOG_ACTIONS="$LOG_ACTIONS" \
          LEROBOT_OBS_IMAGE_JPEG_QUALITY="$OBS_IMAGE_JPEG_QUALITY" \
          LEROBOT_LOG_OBSERVATION_TRANSPORT="$LOG_OBSERVATION_TRANSPORT" \
          LEROBOT_ASYNC_OBSERVATION_SEND="$ASYNC_OBSERVATION_SEND" \
          LEROBOT_OBSERVATION_SEND_QUEUE_SIZE="$OBSERVATION_SEND_QUEUE_SIZE" \
          LEROBOT_OBSERVATION_SEND_TIMEOUT_MS="$OBSERVATION_SEND_TIMEOUT_MS" \
          LEROBOT_MAX_ACTION_AGE_MS="$MAX_ACTION_AGE_MS" \
          LEROBOT_REBASE_ACTION_TIMESTAMPS_ON_RECEIVE="$REBASE_ACTION_TIMESTAMPS_ON_RECEIVE" \
          LEROBOT_SINGLE_ACTION_REQUEST_IN_FLIGHT="$SINGLE_ACTION_REQUEST_IN_FLIGHT" \
          LEROBOT_ACTION_COMMIT_HORIZON="$ACTION_COMMIT_HORIZON" \
          LEROBOT_DIAGNOSTIC_LOGS="$DIAGNOSTIC_LOGS" \
          LEROBOT_DIAGNOSTIC_EVERY_N="$DIAGNOSTIC_EVERY_N" \
          LEROBOT_CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
          LEROBOT_CAMERA_MAX_CONSECUTIVE_READ_FAILURES="$CAMERA_MAX_CONSECUTIVE_READ_FAILURES" \
          LEROBOT_CAMERA_RESTART_ON_READ_FAILURE="$CAMERA_RESTART_ON_READ_FAILURE" \
          LEROBOT_CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS="$CAMERA_TRANSIENT_READ_FAILURE_MAX_AGE_MS" \
          LEROBOT_CAMERA_READ_FAILURE_BACKOFF_MS="$CAMERA_READ_FAILURE_BACKOFF_MS" \
          LEROBOT_CAMERA_DIAG_INTERVAL_S="$CAMERA_DIAG_INTERVAL_S" \
          LEROBOT_CAMERA_FRAME_GAP_WARN_MS="$CAMERA_FRAME_GAP_WARN_MS" \
          LEROBOT_STOP_ON_OBSERVATION_ERROR="$STOP_ON_OBSERVATION_ERROR" \
          LEROBOT_OBSERVATION_ERROR_LIMIT="$OBSERVATION_ERROR_LIMIT" \
          PYTHONPATH=src "$PYTHON_BIN" -m lerobot.async_inference.robot_client \
          --robot.type=so101_follower \
          --robot.port="$FOLLOWER_PORT" \
          --robot.id="$FOLLOWER_ID" \
          --robot.max_relative_target="$MAX_RELATIVE_TARGET" \
          --robot.cameras="$CAMERA_CONFIG" \
          --task="$TASK" \
          --server_address="$SERVER_ADDRESS" \
          --policy_type="$POLICY_TYPE" \
          --pretrained_name_or_path="$MODEL_PATH" \
          --policy_device=cuda \
          --client_device=cpu \
          --fps="$CLIENT_FPS" \
          --actions_per_chunk="$ACTIONS_PER_CHUNK" \
          --chunk_size_threshold="$CHUNK_SIZE_THRESHOLD" \
          --aggregate_fn_name="$AGGREGATE_FN_NAME"
    fi
) > >(tee -a "$CLIENT_LOG") 2>&1 &

CLIENT_PID=$!
echo "$CLIENT_PID" > "$RUN_DIR/client.pid"

set +e
wait "$CLIENT_PID"
STATUS=$?
set -e
trap - INT TERM

echo "" | tee -a "$CLIENT_LOG"
echo "Robot client exited with status $STATUS" | tee -a "$CLIENT_LOG"
log_usb_snapshot "after_client_exit_status_$STATUS"
if [ "$STATUS" -ne 0 ]; then
    echo "Robot client failed; running follower torque-off cleanup..." | tee -a "$CLIENT_LOG"
    stop_robot_client_processes
    disable_follower_torque | tee -a "$CLIENT_LOG"
    log_usb_snapshot "after_failure_torque_cleanup"
fi
stop_background_monitors
if [ "$STATUS" -ne 0 ]; then
    append_recent_diagnostics_to_client_log
fi
echo "finished_at=$(date)" >> "$RUN_INFO"
echo "exit_status=$STATUS" >> "$RUN_INFO"

exit "$STATUS"
