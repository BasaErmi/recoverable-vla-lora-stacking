#!/bin/bash
# Monitor SO101 teleoperation loop frequency from the metrics emitted by
# control_scripts/08_teleoperate_so101.sh.
#
# Usage:
#   bash control_scripts/20_monitor_teleop_fps.sh
#   bash control_scripts/20_monitor_teleop_fps.sh outputs/teleop_logs/latest
#   WINDOW_N=180 WARN_BELOW_HZ=45 BAD_BELOW_HZ=35 bash control_scripts/20_monitor_teleop_fps.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/outputs/teleop_logs}"
TARGET="${1:-}"

if [ -x "$HOME/anaconda3/envs/evo-rl/bin/python" ]; then
    PYTHON_BIN="${PYTHON_BIN:-$HOME/anaconda3/envs/evo-rl/bin/python}"
else
    PYTHON_BIN="${PYTHON_BIN:-python}"
fi

if [ -z "$TARGET" ]; then
    if [ -e "$LOG_ROOT/latest" ]; then
        TARGET="$(readlink -f "$LOG_ROOT/latest")"
    else
        TARGET="$(ls -td "$LOG_ROOT"/* 2>/dev/null | head -1 || true)"
    fi
fi

if [ -z "$TARGET" ]; then
    echo "ERROR: no teleop log found. Start teleop first:" >&2
    echo "  bash control_scripts/08_teleoperate_so101.sh" >&2
    exit 1
fi

if [ -f "$TARGET" ]; then
    METRICS_LOG="$TARGET"
else
    METRICS_LOG="$TARGET/teleop_metrics.csv"
fi

echo "Metrics log: $METRICS_LOG"
echo "Window: ${WINDOW_N:-120} samples  Warn: <${WARN_BELOW_HZ:-45}Hz  Bad: <${BAD_BELOW_HZ:-35}Hz"
echo ""

METRICS_LOG="$METRICS_LOG" \
WINDOW_N="${WINDOW_N:-120}" \
PRINT_EVERY_S="${PRINT_EVERY_S:-1.0}" \
WARN_BELOW_HZ="${WARN_BELOW_HZ:-45}" \
BAD_BELOW_HZ="${BAD_BELOW_HZ:-35}" \
START_AT_END="${START_AT_END:-0}" \
"$PYTHON_BIN" - <<'PY'
import csv
import os
import sys
import time
from collections import deque
from pathlib import Path


metrics_log = Path(os.environ["METRICS_LOG"])
window_n = int(os.environ["WINDOW_N"])
print_every_s = float(os.environ["PRINT_EVERY_S"])
warn_below_hz = float(os.environ["WARN_BELOW_HZ"])
bad_below_hz = float(os.environ["BAD_BELOW_HZ"])
start_at_end = os.environ.get("START_AT_END", "0").lower() in {"1", "true", "yes", "on"}


def percentile(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * q)))
    return ordered[idx]


def fmt(value: float, suffix: str = "") -> str:
    if value != value:
        return "nan"
    return f"{value:.1f}{suffix}"


def row_float(row: dict[str, str], key: str) -> float:
    try:
        return float(row.get(key, "nan"))
    except ValueError:
        return float("nan")


def print_stats(samples: list[dict[str, str]], total: int) -> None:
    hzs = [row_float(row, "hz") for row in samples]
    loops = [row_float(row, "loop_ms") for row in samples]
    obs = [row_float(row, "obs_ms") for row in samples]
    sends = [row_float(row, "send_action_ms") for row in samples]
    displays = [row_float(row, "display_ms") for row in samples]
    teleops = [row_float(row, "teleop_ms") for row in samples]
    latest = samples[-1]
    elapsed = row_float(latest, "elapsed_s")
    low_warn = sum(1 for hz in hzs if hz < warn_below_hz)
    low_bad = sum(1 for hz in hzs if hz < bad_below_hz)
    line = (
        f"t={fmt(elapsed, 's')} total={total} win={len(samples)} "
        f"hz mean={fmt(sum(hzs) / len(hzs))} p10={fmt(percentile(hzs, 0.10))} "
        f"p50={fmt(percentile(hzs, 0.50))} min={fmt(min(hzs))} "
        f"low<{warn_below_hz:.0f}={low_warn} low<{bad_below_hz:.0f}={low_bad} | "
        f"loop_ms p50={fmt(percentile(loops, 0.50))} p90={fmt(percentile(loops, 0.90))} "
        f"max={fmt(max(loops))} | "
        f"obs_ms p50={fmt(percentile(obs, 0.50))} p90={fmt(percentile(obs, 0.90))} | "
        f"teleop_ms p90={fmt(percentile(teleops, 0.90))} "
        f"send_ms p90={fmt(percentile(sends, 0.90))} "
        f"display_ms p90={fmt(percentile(displays, 0.90))} | "
        f"camera=[{latest.get('camera_summary', '')}]"
    )
    print(line, flush=True)


print(f"Waiting for metrics: {metrics_log}", flush=True)
while not metrics_log.exists():
    time.sleep(0.2)

header: list[str] | None = None
window: deque[dict[str, str]] = deque(maxlen=window_n)
total = 0
last_print = time.monotonic()
last_data = time.monotonic()

with metrics_log.open("r", newline="") as handle:
    if start_at_end:
        handle.seek(0, os.SEEK_END)

    while True:
        line = handle.readline()
        if not line:
            if time.monotonic() - last_data > 2.0:
                print("waiting for new teleop samples...", flush=True)
                last_data = time.monotonic()
            time.sleep(0.1)
            continue

        last_data = time.monotonic()
        parsed = next(csv.reader([line]))
        if not parsed:
            continue
        if header is None:
            header = parsed
            continue
        if len(parsed) != len(header):
            print(f"skipping malformed metrics row with {len(parsed)} fields", file=sys.stderr, flush=True)
            continue

        row = dict(zip(header, parsed))
        if row.get("loop_idx") == "loop_idx":
            continue
        window.append(row)
        total += 1

        now = time.monotonic()
        if window and now - last_print >= print_every_s:
            print_stats(list(window), total)
            last_print = now
PY
