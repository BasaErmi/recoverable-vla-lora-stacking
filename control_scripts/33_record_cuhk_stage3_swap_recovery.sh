#!/usr/bin/env bash
# ============================================================
# Record CUHK Stage 3 swap-recovery datasets.
#
# Scenario:
#   - All four CUHK blocks are visible in the lower target area.
#   - Exactly two blocks start swapped into each other's target slots.
#   - The target layout remains fixed: C, U, H, K from left to right.
#   - Demonstrate recovering the scene so all four blocks end in the
#     correct lower slots.
#
# Usage:
#   bash control_scripts/33_record_cuhk_stage3_swap_recovery.sh CU
#   bash control_scripts/33_record_cuhk_stage3_swap_recovery.sh UH
#   bash control_scripts/33_record_cuhk_stage3_swap_recovery.sh all
#   RESUME=true bash control_scripts/33_record_cuhk_stage3_swap_recovery.sh CU
#
# Hotkeys are inherited from control_scripts/09_record_data.sh:
#   Right Arrow  - finish current episode, start next
#   Left Arrow   - rerecord current episode
#   Esc          - stop recording
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAIR_ARG="$(printf '%s' "${1:-CU}" | tr '[:lower:]' '[:upper:]' | sed 's/[-_[:space:]]//g')"

if [ "$PAIR_ARG" = "ALL" ]; then
    if [ -n "${DATASET_NAME:-}" ]; then
        echo "ERROR: DATASET_NAME is not supported with all-mode; record one pair at a time if overriding names." >&2
        exit 1
    fi
    if [ "${RESUME:-false}" = "true" ]; then
        echo "ERROR: RESUME=true is intentionally blocked in all-mode." >&2
        echo "Resume one pair at a time, for example: RESUME=true bash $0 CU" >&2
        exit 1
    fi
    for pair in CU UH HK CH UK CK; do
        echo ""
        echo "============================================================"
        echo "Starting Stage 3 swap recovery pair: $pair"
        echo "============================================================"
        bash "$0" "$pair"
    done
    exit 0
fi

slot_name() {
    case "$1" in
        C) printf 'C target slot, the first slot from the left' ;;
        U) printf 'U target slot, the second slot from the left' ;;
        H) printf 'H target slot, the third slot from the left' ;;
        K) printf 'K target slot, the fourth slot from the left' ;;
        *) printf 'unknown slot' ;;
    esac
}

correct_others_line() {
    local a="$1"
    local b="$2"
    local first=1
    for letter in C U H K; do
        if [ "$letter" != "$a" ] && [ "$letter" != "$b" ]; then
            if [ "$first" -eq 1 ]; then
                printf '%s' "$letter"
                first=0
            else
                printf '/%s' "$letter"
            fi
        fi
    done
}

case "$PAIR_ARG" in
    CU|UC)
        PAIR="cu"
        A="C"
        B="U"
        DEFAULT_NUM_EPISODES="8"
        ;;
    UH|HU)
        PAIR="uh"
        A="U"
        B="H"
        DEFAULT_NUM_EPISODES="8"
        ;;
    HK|KH)
        PAIR="hk"
        A="H"
        B="K"
        DEFAULT_NUM_EPISODES="8"
        ;;
    CH|HC)
        PAIR="ch"
        A="C"
        B="H"
        DEFAULT_NUM_EPISODES="8"
        ;;
    UK|KU)
        PAIR="uk"
        A="U"
        B="K"
        DEFAULT_NUM_EPISODES="8"
        ;;
    CK|KC)
        PAIR="ck"
        A="C"
        B="K"
        DEFAULT_NUM_EPISODES="8"
        ;;
    *)
        echo "ERROR: unsupported swap pair '$PAIR_ARG'." >&2
        echo "Use one of: CU, UH, HK, CH, UK, CK, all" >&2
        exit 1
        ;;
esac

DATE_SUFFIX="${DATE_SUFFIX:-$(date +%Y%m%d)}"
NUM_EPISODES_ENV_PROVIDED=0
if [ -n "${NUM_EPISODES+x}" ]; then
    NUM_EPISODES_ENV_PROVIDED=1
fi
NUM_EPISODES="${NUM_EPISODES:-$DEFAULT_NUM_EPISODES}"
EPISODE_TIME_S="${EPISODE_TIME_S:-60}"
RESET_TIME_S="${RESET_TIME_S:-8}"
RESUME="${RESUME:-false}"
COPY_TO_DATA_ROOT="${COPY_TO_DATA_ROOT:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-2000}"
DATASET_FPS="${DATASET_FPS:-30}"
VIDEO_CODEC="${VIDEO_CODEC:-libsvtav1}"
TASK_DESC="${TASK_DESC:-Sort the visible CUHK letter blocks into the lower target slots in left-to-right order C, U, H, K.}"
DATASET_NAME="${DATASET_NAME:-guanlin8/cuhksz_recovery_swap_${PAIR}_${DATE_SUFFIX}}"
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

OTHER_LETTERS="$(correct_others_line "$A" "$B")"
A_SLOT="$(slot_name "$A")"
B_SLOT="$(slot_name "$B")"

echo "=== CUHK Stage 3 swap-recovery recording ==="
echo "Swap pair: $A <-> $B"
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
echo "  2. Place all four blocks in the lower target area before each episode."
echo "  3. Start with $A in the $B_SLOT, and $B in the $A_SLOT."
echo "  4. Keep $OTHER_LETTERS in their correct target slots."
echo "  5. Demonstrate recovery until all four blocks are correct: C, U, H, K."
echo "  6. Use the top/source area as a temporary buffer if the occupied target slot blocks a clean swap."
echo "  7. Vary block orientation and small offsets across episodes; keep the target boxes fixed."
echo "  8. Use Left Arrow to rerecord wrong-slot, failed-release, hesitant, blocked, or unstable episodes."
echo ""

COPY_TO_DATA_ROOT="$COPY_TO_DATA_ROOT" \
CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
DATASET_FPS="$DATASET_FPS" \
VIDEO_CODEC="$VIDEO_CODEC" \
bash "$SCRIPT_DIR/09_record_data.sh" \
    "$DATASET_NAME" \
    "$TASK_DESC" \
    "$NUM_EPISODES" \
    "$EPISODE_TIME_S" \
    "$RESET_TIME_S" \
    "$RESUME"
