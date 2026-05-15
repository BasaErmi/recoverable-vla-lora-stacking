#!/bin/bash
# ============================================================
# SO101 camera soak test.
#
# This opens the deployment front/wrist cameras only. It does not connect to
# robot motors or start policy inference.
#
# Usage:
#   bash control_scripts/17_so101_camera_soak_test.sh
#   DURATION_S=120 bash control_scripts/17_so101_camera_soak_test.sh
#   WRIST_CAMERA_BACKEND=1200 bash control_scripts/17_so101_camera_soak_test.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_REPO_DIR="${LOCAL_REPO_DIR:-/home/ubuntu/Evo-RL}"
if [ ! -d "$LOCAL_REPO_DIR/src" ] && [ -d "$ROOT_DIR/Evo-RL/src" ]; then
    LOCAL_REPO_DIR="$ROOT_DIR/Evo-RL"
fi

if [ -x "$HOME/anaconda3/envs/evo-rl/bin/python" ]; then
    PYTHON_BIN="${PYTHON_BIN:-$HOME/anaconda3/envs/evo-rl/bin/python}"
else
    PYTHON_BIN="${PYTHON_BIN:-python}"
fi

DURATION_S="${DURATION_S:-60}"
POLL_S="${POLL_S:-0.1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-1000}"
CAMERA_MAX_CONSECUTIVE_READ_FAILURES="${CAMERA_MAX_CONSECUTIVE_READ_FAILURES:-10}"
CAMERA_RESTART_ON_READ_FAILURE="${CAMERA_RESTART_ON_READ_FAILURE:-1}"

FRONT_CAMERA_INDEX="${FRONT_CAMERA_INDEX:-0}"
FRONT_CAMERA_WIDTH="${FRONT_CAMERA_WIDTH:-640}"
FRONT_CAMERA_HEIGHT="${FRONT_CAMERA_HEIGHT:-480}"
FRONT_CAMERA_FPS="${FRONT_CAMERA_FPS:-30}"
FRONT_CAMERA_BACKEND="${FRONT_CAMERA_BACKEND:-}"
FRONT_CAMERA_FOURCC="${FRONT_CAMERA_FOURCC-MJPG}"
FRONT_CAMERA_WARMUP_S="${FRONT_CAMERA_WARMUP_S:-1}"
WRIST_CAMERA_INDEX="${WRIST_CAMERA_INDEX:-2}"
WRIST_CAMERA_WIDTH="${WRIST_CAMERA_WIDTH:-1280}"
WRIST_CAMERA_HEIGHT="${WRIST_CAMERA_HEIGHT:-720}"
WRIST_CAMERA_FPS="${WRIST_CAMERA_FPS:-30}"
WRIST_CAMERA_BACKEND="${WRIST_CAMERA_BACKEND:-}"
WRIST_CAMERA_FOURCC="${WRIST_CAMERA_FOURCC:-MJPG}"
WRIST_CAMERA_WARMUP_S="${WRIST_CAMERA_WARMUP_S:-3}"
ALLOW_BUILTIN_CAMERA="${ALLOW_BUILTIN_CAMERA:-0}"
STRICT_CAMERA_NAME_GUARD="${STRICT_CAMERA_NAME_GUARD:-0}"
LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/outputs/camera_soak_logs}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)_camera_soak}"
LOG_DIR="$LOG_ROOT/$RUN_ID"
LOG_FILE="$LOG_DIR/soak.log"
RUN_INFO="$LOG_DIR/run_info.txt"

mkdir -p "$LOG_DIR"
if [ -L "$LOG_ROOT/latest" ] || [ ! -e "$LOG_ROOT/latest" ]; then
    ln -sfn "$LOG_DIR" "$LOG_ROOT/latest"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

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

    echo "macOS camera map:"
    macos_camera_devices
    echo "Selected front OpenCV index=$FRONT_CAMERA_INDEX AVFoundation_name_hint=${front_name:-UNKNOWN}"
    echo "Selected wrist OpenCV index=$WRIST_CAMERA_INDEX AVFoundation_name_hint=${wrist_name:-UNKNOWN}"
    echo ""

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
                echo "WARNING: AVFoundation name hint includes a built-in/virtual camera. On this Mac, AVFoundation names may not match OpenCV indexes; verify the actual images with control_scripts/19_preview_camera_indices.sh before soak/deployment." >&2
                if [ "$STRICT_CAMERA_NAME_GUARD" = "1" ]; then
                    echo "ERROR: STRICT_CAMERA_NAME_GUARD=1 rejected this camera selection." >&2
                    exit 1
                fi
                ;;
        esac
    fi
}

validate_camera_indexes

cat > "$RUN_INFO" <<EOF
run_id=$RUN_ID
log_file=$LOG_FILE
started_at=$(date --iso-8601=seconds 2>/dev/null || date)
duration_s=$DURATION_S
poll_s=$POLL_S
camera_max_age_ms=$CAMERA_MAX_AGE_MS
camera_max_consecutive_read_failures=$CAMERA_MAX_CONSECUTIVE_READ_FAILURES
camera_restart_on_read_failure=$CAMERA_RESTART_ON_READ_FAILURE
front_camera_index=$FRONT_CAMERA_INDEX
front_camera_width=$FRONT_CAMERA_WIDTH
front_camera_height=$FRONT_CAMERA_HEIGHT
front_camera_fps=$FRONT_CAMERA_FPS
front_camera_backend=$FRONT_CAMERA_BACKEND
front_camera_fourcc=$FRONT_CAMERA_FOURCC
front_camera_warmup_s=$FRONT_CAMERA_WARMUP_S
wrist_camera_index=$WRIST_CAMERA_INDEX
wrist_camera_width=$WRIST_CAMERA_WIDTH
wrist_camera_height=$WRIST_CAMERA_HEIGHT
wrist_camera_fps=$WRIST_CAMERA_FPS
wrist_camera_backend=$WRIST_CAMERA_BACKEND
wrist_camera_fourcc=$WRIST_CAMERA_FOURCC
wrist_camera_warmup_s=$WRIST_CAMERA_WARMUP_S
EOF

echo "=== SO101 Camera Soak Test ==="
echo "Log: $LOG_FILE"
echo "Duration: ${DURATION_S}s  Poll: ${POLL_S}s  Max age: ${CAMERA_MAX_AGE_MS}ms"
echo "front: index=$FRONT_CAMERA_INDEX ${FRONT_CAMERA_WIDTH}x${FRONT_CAMERA_HEIGHT}@${FRONT_CAMERA_FPS} warmup=${FRONT_CAMERA_WARMUP_S}s backend=${FRONT_CAMERA_BACKEND:-default} fourcc=${FRONT_CAMERA_FOURCC:-default}"
echo "wrist: index=$WRIST_CAMERA_INDEX ${WRIST_CAMERA_WIDTH}x${WRIST_CAMERA_HEIGHT}@${WRIST_CAMERA_FPS} warmup=${WRIST_CAMERA_WARMUP_S}s backend=${WRIST_CAMERA_BACKEND:-default} fourcc=${WRIST_CAMERA_FOURCC:-default}"
echo ""

set +e
PYTHONPATH="$LOCAL_REPO_DIR/src" \
LEROBOT_CAMERA_MAX_CONSECUTIVE_READ_FAILURES="$CAMERA_MAX_CONSECUTIVE_READ_FAILURES" \
LEROBOT_CAMERA_RESTART_ON_READ_FAILURE="$CAMERA_RESTART_ON_READ_FAILURE" \
FRONT_CAMERA_INDEX="$FRONT_CAMERA_INDEX" \
FRONT_CAMERA_WIDTH="$FRONT_CAMERA_WIDTH" \
FRONT_CAMERA_HEIGHT="$FRONT_CAMERA_HEIGHT" \
FRONT_CAMERA_FPS="$FRONT_CAMERA_FPS" \
FRONT_CAMERA_BACKEND="$FRONT_CAMERA_BACKEND" \
FRONT_CAMERA_FOURCC="$FRONT_CAMERA_FOURCC" \
FRONT_CAMERA_WARMUP_S="$FRONT_CAMERA_WARMUP_S" \
WRIST_CAMERA_INDEX="$WRIST_CAMERA_INDEX" \
WRIST_CAMERA_WIDTH="$WRIST_CAMERA_WIDTH" \
WRIST_CAMERA_HEIGHT="$WRIST_CAMERA_HEIGHT" \
WRIST_CAMERA_FPS="$WRIST_CAMERA_FPS" \
WRIST_CAMERA_BACKEND="$WRIST_CAMERA_BACKEND" \
WRIST_CAMERA_FOURCC="$WRIST_CAMERA_FOURCC" \
WRIST_CAMERA_WARMUP_S="$WRIST_CAMERA_WARMUP_S" \
DURATION_S="$DURATION_S" \
POLL_S="$POLL_S" \
CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
"$PYTHON_BIN" - <<'PY'
import os
import time

from lerobot.cameras.opencv.camera_opencv import OpenCVCamera
from lerobot.cameras.opencv.configuration_opencv import OpenCVCameraConfig


def _optional_int(name: str) -> int | None:
    value = os.environ.get(name, "")
    return None if value == "" else int(value)


def _optional_str(name: str) -> str | None:
    value = os.environ.get(name, "")
    return None if value == "" else value


def _camera_config(prefix: str) -> OpenCVCameraConfig:
    return OpenCVCameraConfig(
        index_or_path=int(os.environ[f"{prefix}_CAMERA_INDEX"]),
        width=int(os.environ[f"{prefix}_CAMERA_WIDTH"]),
        height=int(os.environ[f"{prefix}_CAMERA_HEIGHT"]),
        fps=int(os.environ[f"{prefix}_CAMERA_FPS"]),
        warmup_s=int(os.environ[f"{prefix}_CAMERA_WARMUP_S"]),
        backend=_optional_int(f"{prefix}_CAMERA_BACKEND") or 0,
        fourcc=_optional_str(f"{prefix}_CAMERA_FOURCC"),
    )


duration_s = float(os.environ["DURATION_S"])
poll_s = float(os.environ["POLL_S"])
max_age_ms = int(os.environ["CAMERA_MAX_AGE_MS"])
cameras = {
    "front": OpenCVCamera(_camera_config("FRONT")),
    "wrist": OpenCVCamera(_camera_config("WRIST")),
}
counts = {name: 0 for name in cameras}
errors = {name: 0 for name in cameras}

try:
    for name, camera in cameras.items():
        camera.connect()
        print(f"connected {name}: {camera}", flush=True)

    start = time.perf_counter()
    last_print = start
    while time.perf_counter() - start < duration_s:
        for name, camera in cameras.items():
            try:
                _ = camera.read_latest(max_age_ms=max_age_ms)
                counts[name] += 1
            except Exception as exc:
                errors[name] += 1
                print(
                    f"ERROR t={time.perf_counter() - start:.2f}s camera={name} "
                    f"{type(exc).__name__}: {exc}",
                    flush=True,
                )

        now = time.perf_counter()
        if now - last_print >= 1.0:
            parts = []
            for name, camera in cameras.items():
                with camera.frame_lock:
                    timestamp = camera.latest_timestamp
                    shape = None if camera.latest_frame is None else tuple(camera.latest_frame.shape)
                age_ms = None if timestamp is None else (now - timestamp) * 1000
                alive = camera.thread.is_alive() if camera.thread is not None else False
                age_text = "None" if age_ms is None else f"{age_ms:.1f}ms"
                parts.append(f"{name}:age={age_text},shape={shape},alive={alive}")
            print(f"t={now - start:.1f}s " + " ".join(parts), flush=True)
            last_print = now

        time.sleep(poll_s)

    print(f"summary counts={counts} errors={errors}", flush=True)
finally:
    for camera in cameras.values():
        if camera.is_connected or camera.thread is not None:
            camera.disconnect()

if any(errors.values()):
    raise SystemExit(1)
PY
status=$?
set -e
{
    echo "finished_at=$(date --iso-8601=seconds 2>/dev/null || date)"
    echo "exit_status=$status"
} >> "$RUN_INFO"
exit "$status"
