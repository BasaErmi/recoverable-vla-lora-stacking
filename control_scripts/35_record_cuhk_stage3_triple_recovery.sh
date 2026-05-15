#!/usr/bin/env bash
# ============================================================
# Record CUHK Stage 3 triple-disorder recovery datasets.
#
# Scenario:
#   - All four CUHK blocks are visible in the lower target area.
#   - Three blocks start in wrong lower slots and one block remains correct.
#   - The target layout remains fixed: C, U, H, K from left to right.
#   - Demonstrate recovering the scene so all four blocks end in the
#     correct lower slots.
#
# Usage:
#   bash control_scripts/35_record_cuhk_stage3_triple_recovery.sh C_HKU
#   bash control_scripts/35_record_cuhk_stage3_triple_recovery.sh H_U_KC
#   bash control_scripts/35_record_cuhk_stage3_triple_recovery.sh UK_H_C
#   bash control_scripts/35_record_cuhk_stage3_triple_recovery.sh UHC_K
#   bash control_scripts/35_record_cuhk_stage3_triple_recovery.sh KCHU
#   bash control_scripts/35_record_cuhk_stage3_triple_recovery.sh all
#   RESUME=true bash control_scripts/35_record_cuhk_stage3_triple_recovery.sh C_HKU
#
# Layout notation is left-to-right initial lower-slot occupancy.
# Example: C_HKU means the four lower slots initially contain C, H, K, U.
#
# Hotkeys are inherited from control_scripts/09_record_data.sh:
#   Right Arrow  - finish current episode, start next
#   Left Arrow   - rerecord current episode
#   Esc          - stop recording
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LAYOUT_ARG="$(printf '%s' "${1:-C_HKU}" | tr '[:lower:]' '[:upper:]' | sed 's/[-_[:space:]]//g')"

if [ "$LAYOUT_ARG" = "ALL" ]; then
    if [ -n "${DATASET_NAME:-}" ]; then
        echo "ERROR: DATASET_NAME is not supported with all-mode; record one layout at a time if overriding names." >&2
        exit 1
    fi
    if [ "${RESUME:-false}" = "true" ]; then
        echo "ERROR: RESUME=true is intentionally blocked in all-mode." >&2
        echo "Resume one layout at a time, for example: RESUME=true bash $0 C_HKU" >&2
        exit 1
    fi
    for layout in C_HKU H_U_KC UK_H_C UHC_K; do
        echo ""
        echo "============================================================"
        echo "Starting Stage 3 triple-disorder recovery layout: $layout"
        echo "============================================================"
        bash "$0" "$layout"
    done
    exit 0
fi

case "$LAYOUT_ARG" in
    CHKU)
        LAYOUT_LABEL="C_HKU"
        DATASET_SLUG="c_hku"
        OCCUPANCY="C, H, K, U"
        CORRECT_LETTER="C"
        WRONG_LETTERS="H/K/U"
        ;;
    HUKC)
        LAYOUT_LABEL="H_U_KC"
        DATASET_SLUG="h_u_kc"
        OCCUPANCY="H, U, K, C"
        CORRECT_LETTER="U"
        WRONG_LETTERS="H/K/C"
        ;;
    UKHC)
        LAYOUT_LABEL="UK_H_C"
        DATASET_SLUG="uk_h_c"
        OCCUPANCY="U, K, H, C"
        CORRECT_LETTER="H"
        WRONG_LETTERS="U/K/C"
        ;;
    UHCK)
        LAYOUT_LABEL="UHC_K"
        DATASET_SLUG="uhc_k"
        OCCUPANCY="U, H, C, K"
        CORRECT_LETTER="K"
        WRONG_LETTERS="U/H/C"
        ;;
    KCHU)
        LAYOUT_LABEL="KC_H_U"
        DATASET_SLUG="kc_h_u"
        OCCUPANCY="K, C, H, U"
        CORRECT_LETTER="H"
        WRONG_LETTERS="K/C/U"
        ;;
    *)
        echo "ERROR: unsupported triple-disorder layout '$LAYOUT_ARG'." >&2
        echo "Use one of: C_HKU, H_U_KC, UK_H_C, UHC_K, KCHU, all" >&2
        echo "Layout notation is left-to-right initial lower-slot occupancy." >&2
        exit 1
        ;;
esac

DATE_SUFFIX="${DATE_SUFFIX:-$(date +%Y%m%d)}"
DEFAULT_NUM_EPISODES="5"
NUM_EPISODES_ENV_PROVIDED=0
if [ -n "${NUM_EPISODES+x}" ]; then
    NUM_EPISODES_ENV_PROVIDED=1
fi
NUM_EPISODES="${NUM_EPISODES:-$DEFAULT_NUM_EPISODES}"
EPISODE_TIME_S="${EPISODE_TIME_S:-75}"
RESET_TIME_S="${RESET_TIME_S:-8}"
RESUME="${RESUME:-false}"
COPY_TO_DATA_ROOT="${COPY_TO_DATA_ROOT:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-2000}"
DATASET_FPS="${DATASET_FPS:-30}"
VIDEO_CODEC="${VIDEO_CODEC:-libsvtav1}"
TASK_DESC="${TASK_DESC:-Sort the visible CUHK letter blocks into the lower target slots in left-to-right order C, U, H, K.}"
DATASET_NAME="${DATASET_NAME:-guanlin8/cuhksz_recovery_triple_${DATASET_SLUG}_${DATE_SUFFIX}}"
PYTHON_BIN="${PYTHON_BIN:-/home/ubuntu/anaconda3/envs/evo-rl/bin/python}"
DRY_RUN="${DRY_RUN:-0}"
DATASET_ROOT="${HF_HOME:-$HOME/.cache/huggingface}/lerobot/${DATASET_NAME}"
EPISODES_ROOT="$DATASET_ROOT/meta/episodes"

if [ "$RESUME" = "true" ]; then
    if [ ! -f "$DATASET_ROOT/meta/info.json" ]; then
        if [ -d "$DATASET_ROOT" ]; then
            EPISODE_FILE_COUNT="$(find "$EPISODES_ROOT" -name 'file-*.parquet' -type f 2>/dev/null | wc -l)"
            if [ "$EPISODE_FILE_COUNT" -ne 0 ]; then
                echo "ERROR: RESUME=true found episode metadata but missing meta/info.json: $DATASET_ROOT" >&2
                echo "Inspect or repair this dataset before continuing." >&2
                exit 1
            fi
            INVALID_ROOT="${DATASET_ROOT}.invalid_resume_$(date +%Y%m%d_%H%M%S)"
            mv "$DATASET_ROOT" "$INVALID_ROOT"
            RESUME_NOTE="requested resume but local dataset was invalid/empty; moved to $INVALID_ROOT and starting fresh"
        else
            RESUME_NOTE="requested resume but local dataset does not exist; starting fresh"
        fi
        RESUME="false"
    elif [ "$NUM_EPISODES_ENV_PROVIDED" -eq 0 ]; then
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

echo "=== CUHK Stage 3 triple-disorder recovery recording ==="
echo "Layout: $LAYOUT_LABEL"
echo "Initial lower-slot occupancy: $OCCUPANCY"
echo "Correct letter left in place: $CORRECT_LETTER"
echo "Wrong letters to recover: $WRONG_LETTERS"
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
echo "  3. Start with lower-slot occupancy from left to right: $OCCUPANCY."
echo "  4. Keep $CORRECT_LETTER in its correct target slot; deliberately disorder $WRONG_LETTERS."
echo "  5. Demonstrate recovery until all four blocks are correct: C, U, H, K."
echo "  6. Use the top/source area as a temporary buffer when an occupied slot blocks a clean move."
echo "  7. Vary block orientation and small offsets across episodes; keep the target boxes fixed."
echo "  8. Use Left Arrow to rerecord wrong-slot, failed-release, hesitant, blocked, or unstable episodes."
echo ""

if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN=1; not starting lerobot-record."
    echo "Command that would run:"
    echo "  COPY_TO_DATA_ROOT=$COPY_TO_DATA_ROOT CAMERA_MAX_AGE_MS=$CAMERA_MAX_AGE_MS DATASET_FPS=$DATASET_FPS VIDEO_CODEC=$VIDEO_CODEC \\"
    echo "    bash $SCRIPT_DIR/09_record_data.sh \"$DATASET_NAME\" \"$TASK_DESC\" \"$NUM_EPISODES\" \"$EPISODE_TIME_S\" \"$RESET_TIME_S\" \"$RESUME\""
    exit 0
fi

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
