#!/bin/bash
# ============================================================
# Preview the exact SO101 front/wrist camera indexes used by deployment.
#
# This opens cameras only. It does not connect to robot motors or start policy
# inference. Press q or ESC in the preview window to exit.
#
# Usage:
#   bash control_scripts/18_preview_so101_cameras.sh
#   FRONT_CAMERA_INDEX=2 WRIST_CAMERA_INDEX=3 bash control_scripts/18_preview_so101_cameras.sh
#   ALLOW_BUILTIN_CAMERA=1 bash control_scripts/18_preview_so101_cameras.sh
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

DURATION_S="${DURATION_S:-0}"
PREVIEW_HEIGHT="${PREVIEW_HEIGHT:-360}"
# Preview is explicitly for visualizing the selected indexes, so allow built-in
# cameras by default and warn loudly. Deployment/soak scripts still reject them.
ALLOW_BUILTIN_CAMERA="${ALLOW_BUILTIN_CAMERA:-1}"

FRONT_CAMERA_INDEX="${FRONT_CAMERA_INDEX:-0}"
FRONT_CAMERA_WIDTH="${FRONT_CAMERA_WIDTH:-640}"
FRONT_CAMERA_HEIGHT="${FRONT_CAMERA_HEIGHT:-480}"
FRONT_CAMERA_FPS="${FRONT_CAMERA_FPS:-30}"
FRONT_CAMERA_BACKEND="${FRONT_CAMERA_BACKEND:-}"
FRONT_CAMERA_FOURCC="${FRONT_CAMERA_FOURCC-MJPG}"
WRIST_CAMERA_INDEX="${WRIST_CAMERA_INDEX:-2}"
WRIST_CAMERA_WIDTH="${WRIST_CAMERA_WIDTH:-1280}"
WRIST_CAMERA_HEIGHT="${WRIST_CAMERA_HEIGHT:-720}"
WRIST_CAMERA_FPS="${WRIST_CAMERA_FPS:-30}"
WRIST_CAMERA_BACKEND="${WRIST_CAMERA_BACKEND:-}"
WRIST_CAMERA_FOURCC="${WRIST_CAMERA_FOURCC:-MJPG}"

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

FRONT_CAMERA_NAME=""
WRIST_CAMERA_NAME=""

validate_camera_indexes() {
    if [ "$(uname -s)" != "Darwin" ]; then
        return 0
    fi
    if ! command -v ffmpeg >/dev/null 2>&1; then
        echo "WARNING: ffmpeg not found; cannot verify macOS AVFoundation camera indexes." >&2
        return 0
    fi

    FRONT_CAMERA_NAME="$(macos_camera_name_for_index "$FRONT_CAMERA_INDEX")"
    WRIST_CAMERA_NAME="$(macos_camera_name_for_index "$WRIST_CAMERA_INDEX")"

    echo "macOS camera map:"
    macos_camera_devices
    echo "Selected front OpenCV index=$FRONT_CAMERA_INDEX AVFoundation_name_hint=${FRONT_CAMERA_NAME:-UNKNOWN}"
    echo "Selected wrist OpenCV index=$WRIST_CAMERA_INDEX AVFoundation_name_hint=${WRIST_CAMERA_NAME:-UNKNOWN}"
    echo ""

    if [ -z "$FRONT_CAMERA_NAME" ] || [ -z "$WRIST_CAMERA_NAME" ]; then
        echo "ERROR: selected camera index was not found. Override FRONT_CAMERA_INDEX/WRIST_CAMERA_INDEX after checking the map above." >&2
        exit 1
    fi
    if [ "$FRONT_CAMERA_INDEX" = "$WRIST_CAMERA_INDEX" ]; then
        echo "ERROR: front and wrist camera indexes are the same." >&2
        exit 1
    fi
    if [ "$ALLOW_BUILTIN_CAMERA" != "1" ]; then
        case "$FRONT_CAMERA_NAME $WRIST_CAMERA_NAME" in
            *FaceTime*|*"Capture screen"*|*Continuity*)
                echo "ERROR: selected cameras include a built-in/virtual camera. Set FRONT_CAMERA_INDEX/WRIST_CAMERA_INDEX to the two robot cameras, or use ALLOW_BUILTIN_CAMERA=1 only for deliberate visual debugging." >&2
                exit 1
                ;;
        esac
    else
        case "$FRONT_CAMERA_NAME $WRIST_CAMERA_NAME" in
            *FaceTime*|*"Capture screen"*|*Continuity*)
                echo "WARNING: AVFoundation name hint includes a built-in/virtual camera. This is OK for visual debugging only; trust the preview image, not the AVFoundation hint, for OpenCV mapping." >&2
                echo ""
                ;;
        esac
    fi
}

validate_camera_indexes

PYTHONPATH="$LOCAL_REPO_DIR/src" \
FRONT_CAMERA_INDEX="$FRONT_CAMERA_INDEX" \
FRONT_CAMERA_WIDTH="$FRONT_CAMERA_WIDTH" \
FRONT_CAMERA_HEIGHT="$FRONT_CAMERA_HEIGHT" \
FRONT_CAMERA_FPS="$FRONT_CAMERA_FPS" \
FRONT_CAMERA_BACKEND="$FRONT_CAMERA_BACKEND" \
FRONT_CAMERA_FOURCC="$FRONT_CAMERA_FOURCC" \
FRONT_CAMERA_NAME="$FRONT_CAMERA_NAME" \
WRIST_CAMERA_INDEX="$WRIST_CAMERA_INDEX" \
WRIST_CAMERA_WIDTH="$WRIST_CAMERA_WIDTH" \
WRIST_CAMERA_HEIGHT="$WRIST_CAMERA_HEIGHT" \
WRIST_CAMERA_FPS="$WRIST_CAMERA_FPS" \
WRIST_CAMERA_BACKEND="$WRIST_CAMERA_BACKEND" \
WRIST_CAMERA_FOURCC="$WRIST_CAMERA_FOURCC" \
WRIST_CAMERA_NAME="$WRIST_CAMERA_NAME" \
DURATION_S="$DURATION_S" \
PREVIEW_HEIGHT="$PREVIEW_HEIGHT" \
"$PYTHON_BIN" - <<'PY'
import os
import time

import cv2
import numpy as np


def _optional_int(name: str) -> int | None:
    value = os.environ.get(name, "")
    return None if value == "" else int(value)


def _optional_str(name: str) -> str | None:
    value = os.environ.get(name, "")
    return None if value == "" else value


def _camera(prefix: str) -> dict:
    return {
        "label": prefix.lower(),
        "index": int(os.environ[f"{prefix}_CAMERA_INDEX"]),
        "width": int(os.environ[f"{prefix}_CAMERA_WIDTH"]),
        "height": int(os.environ[f"{prefix}_CAMERA_HEIGHT"]),
        "fps": int(os.environ[f"{prefix}_CAMERA_FPS"]),
        "backend": _optional_int(f"{prefix}_CAMERA_BACKEND") or 0,
        "fourcc": _optional_str(f"{prefix}_CAMERA_FOURCC"),
    }


def _open_camera(cfg: dict) -> cv2.VideoCapture:
    cap = cv2.VideoCapture(cfg["index"], cfg["backend"])
    if not cap.isOpened():
        raise RuntimeError(f"failed to open {cfg['label']} camera index={cfg['index']}")
    if cfg["fourcc"]:
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*cfg["fourcc"]))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, float(cfg["width"]))
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, float(cfg["height"]))
    cap.set(cv2.CAP_PROP_FPS, float(cfg["fps"]))
    actual = {
        "backend": cap.getBackendName(),
        "width": int(round(cap.get(cv2.CAP_PROP_FRAME_WIDTH))),
        "height": int(round(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))),
        "fps": cap.get(cv2.CAP_PROP_FPS),
    }
    print(f"opened {cfg['label']}: requested={cfg} actual={actual}", flush=True)
    return cap


def _resize_to_height(frame: np.ndarray, height: int) -> np.ndarray:
    h, w = frame.shape[:2]
    width = max(1, int(round(w * height / h)))
    return cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)


def _draw_label(frame: np.ndarray, text: str) -> np.ndarray:
    frame = frame.copy()
    cv2.rectangle(frame, (0, 0), (frame.shape[1], 34), (0, 0, 0), thickness=-1)
    cv2.putText(
        frame,
        text,
        (10, 24),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.65,
        (0, 255, 255),
        2,
        cv2.LINE_AA,
    )
    return frame


front_cfg = _camera("FRONT")
wrist_cfg = _camera("WRIST")
duration_s = float(os.environ["DURATION_S"])
preview_height = int(os.environ["PREVIEW_HEIGHT"])

front_cap = _open_camera(front_cfg)
wrist_cap = _open_camera(wrist_cfg)
start = time.perf_counter()
frame_count = 0

try:
    while True:
        ok_front, front = front_cap.read()
        ok_wrist, wrist = wrist_cap.read()
        if not ok_front or front is None:
            raise RuntimeError("front read failed")
        if not ok_wrist or wrist is None:
            raise RuntimeError("wrist read failed")

        frame_count += 1
        elapsed = time.perf_counter() - start
        fps = frame_count / max(elapsed, 1e-6)

        front_view = _draw_label(
            _resize_to_height(front, preview_height),
            f"front OPENCV ID={front_cfg['index']} frame={front.shape}",
        )
        wrist_view = _draw_label(
            _resize_to_height(wrist, preview_height),
            f"wrist OPENCV ID={wrist_cfg['index']} frame={wrist.shape}",
        )

        gap = np.zeros((preview_height, 8, 3), dtype=np.uint8)
        canvas = np.hstack([front_view, gap, wrist_view])
        cv2.putText(
            canvas,
            f"preview_fps={fps:.1f}  press q/ESC to quit",
            (10, canvas.shape[0] - 12),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (0, 255, 0),
            2,
            cv2.LINE_AA,
        )
        cv2.imshow("SO101 selected cameras", canvas)

        key = cv2.waitKey(1) & 0xFF
        if key in (27, ord("q")):
            break
        if duration_s > 0 and elapsed >= duration_s:
            break
finally:
    front_cap.release()
    wrist_cap.release()
    cv2.destroyAllWindows()
PY
