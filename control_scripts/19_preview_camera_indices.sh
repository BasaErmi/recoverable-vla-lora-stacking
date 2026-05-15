#!/bin/bash
# ============================================================
# Preview raw macOS/OpenCV camera indexes.
#
# This opens the requested OpenCV indexes directly and overlays each panel with
# the exact OpenCV index, an optional user label, backend, and frame shape.
# macOS AVFoundation device names are printed as a separate list only because
# their order can differ from OpenCV's index order.
#
# Usage:
#   bash control_scripts/19_preview_camera_indices.sh
#   CAMERA_INDICES="0 1 2 3" bash control_scripts/19_preview_camera_indices.sh
#   CAMERA_LABEL_0=front CAMERA_LABEL_2=wrist bash control_scripts/19_preview_camera_indices.sh
#   DURATION_S=10 bash control_scripts/19_preview_camera_indices.sh
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

CAMERA_INDICES="${CAMERA_INDICES:-0 1 2 3}"
DURATION_S="${DURATION_S:-0}"
PANEL_WIDTH="${PANEL_WIDTH:-420}"
PANEL_HEIGHT="${PANEL_HEIGHT:-260}"
GRID_COLUMNS="${GRID_COLUMNS:-2}"
CAMERA_BACKEND="${CAMERA_BACKEND:-0}"

macos_camera_devices() {
    if ! command -v ffmpeg >/dev/null 2>&1; then
        return 1
    fi
    { ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true; } \
        | sed -n '/AVFoundation video devices:/,/AVFoundation audio devices:/p'
}

echo "macOS AVFoundation device list (NOT authoritative for OpenCV ID mapping):"
if command -v ffmpeg >/dev/null 2>&1; then
    macos_camera_devices
else
    echo "ffmpeg not found; names may be UNKNOWN"
fi
echo "Preview indexes: $CAMERA_INDICES"
echo "Grid: ${GRID_COLUMNS} columns, panel=${PANEL_WIDTH}x${PANEL_HEIGHT}"
echo "Press q or ESC in the preview window to exit."
echo ""

PYTHONPATH="$LOCAL_REPO_DIR/src" \
CAMERA_INDICES="$CAMERA_INDICES" \
DURATION_S="$DURATION_S" \
PANEL_WIDTH="$PANEL_WIDTH" \
PANEL_HEIGHT="$PANEL_HEIGHT" \
GRID_COLUMNS="$GRID_COLUMNS" \
CAMERA_BACKEND="$CAMERA_BACKEND" \
"$PYTHON_BIN" - <<'PY'
import os
import time

import cv2
import numpy as np


def _label_for_index(index: int) -> str:
    return os.environ.get(f"CAMERA_LABEL_{index}", "unassigned")


def _draw_panel(
    index: int | str,
    label: str,
    detail_lines: list[str],
    panel_width: int,
    panel_height: int,
    color=(0, 255, 255),
) -> np.ndarray:
    panel = np.zeros((panel_height, panel_width, 3), dtype=np.uint8)
    cv2.rectangle(panel, (0, 0), (panel_width - 1, panel_height - 1), color, 3)
    cv2.rectangle(panel, (0, 0), (panel_width, 118), (0, 0, 0), thickness=-1)
    text_lines = [
        f"OPENCV ID: {index}",
        f"USER LABEL: {label}",
        *detail_lines,
    ]
    y = 30
    for line in text_lines:
        cv2.putText(
            panel,
            line[:92],
            (12, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.54,
            color,
            2,
            cv2.LINE_AA,
        )
        y += 26
    return panel


def _resize_letterbox(frame: np.ndarray, panel_width: int, panel_height: int) -> np.ndarray:
    h, w = frame.shape[:2]
    scale = min(panel_width / w, panel_height / h)
    resized_w = max(1, int(round(w * scale)))
    resized_h = max(1, int(round(h * scale)))
    resized = cv2.resize(frame, (resized_w, resized_h), interpolation=cv2.INTER_AREA)
    canvas = np.zeros((panel_height, panel_width, 3), dtype=np.uint8)
    x0 = (panel_width - resized_w) // 2
    y0 = (panel_height - resized_h) // 2
    canvas[y0 : y0 + resized_h, x0 : x0 + resized_w] = resized
    return canvas


def _overlay(frame: np.ndarray, index: int, label: str, detail_lines: list[str]) -> np.ndarray:
    frame = frame.copy()
    cv2.rectangle(frame, (0, 0), (frame.shape[1] - 1, frame.shape[0] - 1), (0, 255, 255), 3)
    cv2.rectangle(frame, (0, 0), (frame.shape[1], min(frame.shape[0], 118)), (0, 0, 0), -1)
    lines = [
        f"OPENCV ID: {index}",
        f"USER LABEL: {label}",
        *detail_lines,
    ]
    y = 24
    for line in lines:
        cv2.putText(
            frame,
            line[:90],
            (10, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.54,
            (0, 255, 255),
            2,
            cv2.LINE_AA,
        )
        y += 26
    return frame


indices = [int(value) for value in os.environ["CAMERA_INDICES"].split()]
duration_s = float(os.environ["DURATION_S"])
panel_width = int(os.environ["PANEL_WIDTH"])
panel_height = int(os.environ["PANEL_HEIGHT"])
grid_columns = max(1, int(os.environ["GRID_COLUMNS"]))
backend = int(os.environ["CAMERA_BACKEND"])

captures = {}
errors = {}
for index in indices:
    cap = cv2.VideoCapture(index, backend)
    if not cap.isOpened():
        errors[index] = "open failed"
        cap.release()
        continue
    captures[index] = cap
    print(
        f"opened opencv_index={index} label={_label_for_index(index)} backend={cap.getBackendName()} "
        f"default_shape={int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))}x{int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))} "
        f"fps={cap.get(cv2.CAP_PROP_FPS):.2f}",
        flush=True,
    )

if not captures:
    raise SystemExit("no camera indexes opened")

start = time.perf_counter()
frame_count = 0
try:
    while True:
        panels = []
        frame_count += 1
        elapsed = time.perf_counter() - start
        for index in indices:
            label = _label_for_index(index)
            cap = captures.get(index)
            if cap is None:
                panels.append(
                    _draw_panel(
                        index,
                        label,
                        [f"ERROR: {errors.get(index, 'not opened')}"],
                        panel_width,
                        panel_height,
                        color=(0, 0, 255),
                    )
                )
                continue

            ok, frame = cap.read()
            if not ok or frame is None:
                panels.append(
                    _draw_panel(
                        index,
                        label,
                        ["ERROR: read failed"],
                        panel_width,
                        panel_height,
                        color=(0, 0, 255),
                    )
                )
                continue

            view = _resize_letterbox(frame, panel_width, panel_height)
            panels.append(
                _overlay(
                    view,
                    index,
                    label,
                    [f"FRAME: {tuple(frame.shape)}", f"BACKEND: {cap.getBackendName()}"],
                )
            )

        while len(panels) % grid_columns:
            panels.append(
                _draw_panel(
                    "",
                    "",
                    ["unused grid cell"],
                    panel_width,
                    panel_height,
                    color=(80, 80, 80),
                )
            )

        rows = []
        for row_start in range(0, len(panels), grid_columns):
            rows.append(np.hstack(panels[row_start : row_start + grid_columns]))
        canvas = np.vstack(rows)
        cv2.putText(
            canvas,
            f"raw camera index preview  fps={frame_count / max(elapsed, 1e-6):.1f}  press q/ESC to quit",
            (12, canvas.shape[0] - 12),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (0, 255, 0),
            2,
            cv2.LINE_AA,
        )
        cv2.namedWindow("Camera index preview", cv2.WINDOW_NORMAL)
        cv2.resizeWindow("Camera index preview", canvas.shape[1], canvas.shape[0])
        cv2.imshow("Camera index preview", canvas)

        key = cv2.waitKey(1) & 0xFF
        if key in (27, ord("q")):
            break
        if duration_s > 0 and elapsed >= duration_s:
            break
finally:
    for cap in captures.values():
        cap.release()
    cv2.destroyAllWindows()
PY
