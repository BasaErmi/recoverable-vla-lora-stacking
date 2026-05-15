#!/usr/bin/env bash
# ============================================================
# Record CUHK Stage 4 near-slot alignment recovery datasets.
#
# Scenario:
#   - One or two selected letters are near their correct target slots but
#     not acceptably placed: skewed, offset, partly outside the box, or
#     rotated badly.
#   - The demonstration should pick, lift, align, place, release, and
#     withdraw instead of primarily dragging or pushing.
#
# Usage:
#   bash scripts/record_near_slot_alignment.sh C
#   bash scripts/record_near_slot_alignment.sh CU
#   bash scripts/record_near_slot_alignment.sh all
#   RESUME=true bash scripts/record_near_slot_alignment.sh C
#
# Hotkeys are inherited from scripts/record_data.sh:
#   Right Arrow  - finish current episode, start next
#   Left Arrow   - rerecord current episode
#   Esc          - stop recording
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ARG="$(printf '%s' "${1:-C}" | tr '[:lower:]' '[:upper:]' | sed 's/[-_[:space:]]//g')"

if [ "$TARGET_ARG" = "ALL" ]; then
    if [ -n "${DATASET_NAME:-}" ]; then
        echo "ERROR: DATASET_NAME is not supported with all-mode; record one target at a time if overriding names." >&2
        exit 1
    fi
    if [ "${RESUME:-false}" = "true" ]; then
        echo "ERROR: RESUME=true is intentionally blocked in all-mode." >&2
        echo "Resume one target at a time, for example: RESUME=true bash $0 C" >&2
        exit 1
    fi
    for target in C U H K; do
        echo ""
        echo "============================================================"
        echo "Starting Stage 4 near-slot alignment target: $target"
        echo "============================================================"
        bash "$0" "$target"
    done
    exit 0
fi

letters_valid() {
    local value="$1"
    local i ch
    [ -n "$value" ] || return 1
    [ "${#value}" -le 2 ] || return 1
    for ((i = 0; i < ${#value}; i++)); do
        ch="${value:$i:1}"
        case "$ch" in
            C|U|H|K) ;;
            *) return 1 ;;
        esac
    done
    if [ "${#value}" -eq 2 ] && [ "${value:0:1}" = "${value:1:1}" ]; then
        return 1
    fi
}

slot_name() {
    case "$1" in
        C) printf 'C target slot, the first slot from the left' ;;
        U) printf 'U target slot, the second slot from the left' ;;
        H) printf 'H target slot, the third slot from the left' ;;
        K) printf 'K target slot, the fourth slot from the left' ;;
        *) printf 'unknown slot' ;;
    esac
}

target_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

targets_with_separator() {
    local value="$1"
    if [ "${#value}" -eq 1 ]; then
        printf '%s' "$value"
    else
        printf '%s/%s' "${value:0:1}" "${value:1:1}"
    fi
}

slot_list() {
    local value="$1"
    local i ch first=1
    for ((i = 0; i < ${#value}; i++)); do
        ch="${value:$i:1}"
        if [ "$first" -eq 1 ]; then
            printf '%s' "$(slot_name "$ch")"
            first=0
        else
            printf '; %s' "$(slot_name "$ch")"
        fi
    done
}

if ! letters_valid "$TARGET_ARG"; then
    echo "ERROR: unsupported target '$TARGET_ARG'." >&2
    echo "Use one letter C/U/H/K, one pair such as CU/CH/UK, or all." >&2
    exit 1
fi

DATE_SUFFIX="${DATE_SUFFIX:-$(date +%Y%m%d)}"
DEFAULT_NUM_EPISODES="15"
NUM_EPISODES_ENV_PROVIDED=0
if [ -n "${NUM_EPISODES+x}" ]; then
    NUM_EPISODES_ENV_PROVIDED=1
fi
NUM_EPISODES="${NUM_EPISODES:-$DEFAULT_NUM_EPISODES}"
EPISODE_TIME_S="${EPISODE_TIME_S:-30}"
RESET_TIME_S="${RESET_TIME_S:-6}"
RESUME="${RESUME:-false}"
COPY_TO_DATA_ROOT="${COPY_TO_DATA_ROOT:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-2000}"
DATASET_FPS="${DATASET_FPS:-30}"
VIDEO_CODEC="${VIDEO_CODEC:-libsvtav1}"
TASK_DESC="${TASK_DESC:-Sort the visible CUHK letter blocks into the lower target slots in left-to-right order C, U, H, K.}"
SLUG="$(target_slug "$TARGET_ARG")"
DATASET_NAME="${DATASET_NAME:-guanlin8/cuhksz_stage4_near_slot_align_${SLUG}_${DATE_SUFFIX}}"
PYTHON_BIN="${PYTHON_BIN:-/home/ubuntu/anaconda3/envs/evo-rl/bin/python}"

if [ "$RESUME" = "true" ] && [ "$NUM_EPISODES_ENV_PROVIDED" -eq 0 ]; then
    DATASET_ROOT="${HF_HOME:-$HOME/.cache/huggingface}/lerobot/${DATASET_NAME}"
    EPISODES_ROOT="$DATASET_ROOT/meta/episodes"
    if [ -d "$EPISODES_ROOT" ]; then
        EXISTING_EPISODES="$("$PYTHON_BIN" - "$EPISODES_ROOT" <<'PY'
from pathlib import Path
import sys
import pandas as pd

root = Path(sys.argv[1])
episode_files = sorted(root.glob("chunk-*/file-*.parquet"))
if not episode_files:
    print(0)
else:
    print(sum(len(pd.read_parquet(path)) for path in episode_files))
PY
)"
        REMAINING_EPISODES=$((DEFAULT_NUM_EPISODES - EXISTING_EPISODES))
        if [ "$REMAINING_EPISODES" -le 0 ]; then
            echo "Dataset already has $EXISTING_EPISODES/$DEFAULT_NUM_EPISODES episodes: $DATASET_NAME"
            echo "Nothing to resume. Set NUM_EPISODES explicitly if you intentionally want to append more."
            exit 0
        fi
        NUM_EPISODES="$REMAINING_EPISODES"
        RESUME_NOTE="auto remaining: existing=$EXISTING_EPISODES target=$DEFAULT_NUM_EPISODES remaining=$NUM_EPISODES"
    fi
fi

TARGETS_DISPLAY="$(targets_with_separator "$TARGET_ARG")"
SLOTS_DISPLAY="$(slot_list "$TARGET_ARG")"

echo "=== CUHK Stage 4 near-slot alignment recording ==="
echo "Alignment target(s): $TARGETS_DISPLAY"
echo "Dataset: $DATASET_NAME"
echo "Episodes: $NUM_EPISODES"
if [ -n "${RESUME_NOTE:-}" ]; then
    echo "Resume episodes: $RESUME_NOTE"
fi
echo "Episode/reset seconds: $EPISODE_TIME_S / $RESET_TIME_S"
echo "Resume: $RESUME"
echo "Copy to /home/ubuntu/data: $COPY_TO_DATA_ROOT"
echo ""
echo "Protocol:"
echo "  1. Keep the lower target slot layout fixed: C, U, H, K from left to right."
echo "  2. Put target letter(s) $TARGETS_DISPLAY near their own correct slot(s), but visibly not well placed."
echo "  3. Misalignment examples: skewed, rotated, partly outside the box, touching an edge, or offset inside the box."
echo "  4. Keep non-target letters correct if present, and avoid moving them."
echo "  5. Demonstrate pick, lift, align, place, release, and withdraw for: $SLOTS_DISPLAY."
echo "  6. Avoid making dragging/pushing the main correction strategy."
echo "  7. Vary offset direction, rotation angle, and near-slot distance across episodes."
echo "  8. Use Left Arrow to rerecord wrong-slot, failed-release, hesitant, blocked, or unstable episodes."
echo ""

COPY_TO_DATA_ROOT="$COPY_TO_DATA_ROOT" \
CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
DATASET_FPS="$DATASET_FPS" \
VIDEO_CODEC="$VIDEO_CODEC" \
bash "$SCRIPT_DIR/record_data.sh" \
    "$DATASET_NAME" \
    "$TASK_DESC" \
    "$NUM_EPISODES" \
    "$EPISODE_TIME_S" \
    "$RESET_TIME_S" \
    "$RESUME"
