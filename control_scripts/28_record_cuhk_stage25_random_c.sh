#!/usr/bin/env bash
# ============================================================
# Record CUHK Stage 2.5 random-C recovery datasets.
#
# Scenario:
#   - C starts from a visibly displaced/random source pose.
#   - with_uhk: U/H/K are already placed correctly.
#   - no_uhk: U/H/K are absent; only C is present.
#   - The target layout remains fixed: C, U, H, K from left to right.
#   - Demonstrate picking C and placing it into the C target slot.
#
# Usage:
#   bash control_scripts/28_record_cuhk_stage25_random_c.sh
#   bash control_scripts/28_record_cuhk_stage25_random_c.sh with_uhk
#   bash control_scripts/28_record_cuhk_stage25_random_c.sh no_uhk
#   NUM_EPISODES=20 bash control_scripts/28_record_cuhk_stage25_random_c.sh with_uhk
#   EPISODE_TIME_S=25 bash control_scripts/28_record_cuhk_stage25_random_c.sh no_uhk
#
# Hotkeys are inherited from control_scripts/09_record_data.sh:
#   Right Arrow  - finish current episode, start next
#   Left Arrow   - rerecord current episode
#   Esc          - stop recording
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONDITION_ARG="${1:-with_uhk}"
case "$(printf '%s' "$CONDITION_ARG" | tr '[:upper:]' '[:lower:]' | tr '-' '_')" in
    with_uhk)
        CONDITION="with_uhk"
        DATASET_DEFAULT="guanlin8/cuhksz_recovery_random_c_with_uhk_20260503"
        CONDITION_DESC="U/H/K are already placed correctly; only C starts from a random source pose."
        SETUP_LINE="Place U, H, and K in their correct lower slots. Put C in a random reachable source pose."
        ;;
    no_uhk|without_uhk)
        CONDITION="no_uhk"
        DATASET_DEFAULT="guanlin8/cuhksz_recovery_random_c_with_no_uhk_20260503"
        CONDITION_DESC="U/H/K are absent; only C starts from a random source pose."
        SETUP_LINE="Remove U, H, and K. Put only C in a random reachable source pose."
        ;;
    *)
        echo "ERROR: first argument must be one of: with_uhk, no_uhk" >&2
        exit 1
        ;;
esac

DATASET_NAME="${DATASET_NAME:-$DATASET_DEFAULT}"
NUM_EPISODES="${NUM_EPISODES:-15}"
EPISODE_TIME_S="${EPISODE_TIME_S:-20}"
RESET_TIME_S="${RESET_TIME_S:-10}"
RESUME="${RESUME:-false}"
COPY_TO_DATA_ROOT="${COPY_TO_DATA_ROOT:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-2000}"
DATASET_FPS="${DATASET_FPS:-30}"
VIDEO_CODEC="${VIDEO_CODEC:-libsvtav1}"
TASK_DESC="${TASK_DESC:-The target slots from left to right are C, U, H, K. Pick up the visible C block and place it in the C target slot, the first slot from the left.}"

echo "=== CUHK Stage 2.5 random-C recovery recording ==="
echo "Condition: $CONDITION"
echo "Dataset: $DATASET_NAME"
echo "Episodes: $NUM_EPISODES"
echo "Episode/reset seconds: $EPISODE_TIME_S / $RESET_TIME_S"
echo "Resume: $RESUME"
echo "Copy to /home/ubuntu/data: $COPY_TO_DATA_ROOT"
echo ""
echo "Protocol:"
echo "  1. Keep the lower target slot layout fixed: C, U, H, K from left to right."
echo "  2. $CONDITION_DESC"
echo "  3. $SETUP_LINE"
echo "  4. Vary C source position and block orientation across episodes."
echo "  5. Keep the C target slot fixed; do not move target boxes during this dataset."
echo "  6. Demonstrate a clean pick, lift, transfer, place, release, and withdraw."
echo "  7. Use Left Arrow to rerecord wrong-slot, failed-release, hesitant, blocked, or unstable episodes."
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
