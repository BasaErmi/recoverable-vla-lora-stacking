#!/bin/bash
# ============================================================
# Record CUHK letter pick-and-place datasets for the boxed layout.
#
# Scene:
#   - One source/top box contains the letter block for the current episode.
#   - Four target boxes below are labeled/assigned C, U, H, K.
#   - Record in C -> U -> H -> K order by default.
#
# Usage:
#   bash control_scripts/24_record_cuhk_pick_place_slots.sh
#   bash control_scripts/24_record_cuhk_pick_place_slots.sh C
#   EPISODES_PER_LETTER=40 EPISODE_TIME_S=15 RESET_TIME_S=4 bash control_scripts/24_record_cuhk_pick_place_slots.sh all
#
# Hotkeys are inherited from control_scripts/09_record_data.sh:
#   Right Arrow  - finish current episode, start next
#   Left Arrow   - rerecord current episode
#   Esc          - stop recording
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LETTERS_ARG="${1:-all}"
case "$(printf '%s' "$LETTERS_ARG" | tr '[:lower:]' '[:upper:]')" in
    ALL)
        LETTERS=(C U H K)
        ;;
    C|U|H|K)
        LETTERS=("$(printf '%s' "$LETTERS_ARG" | tr '[:lower:]' '[:upper:]')")
        ;;
    *)
        echo "ERROR: first argument must be one of: all, C, U, H, K" >&2
        exit 1
        ;;
esac

DATASET_PREFIX="${DATASET_PREFIX:-guanlin8/cuhksz_pick_place_slots_20260430}"
EPISODES_PER_LETTER="${EPISODES_PER_LETTER:-40}"
EPISODE_TIME_S="${EPISODE_TIME_S:-15}"
RESET_TIME_S="${RESET_TIME_S:-4}"
RESUME="${RESUME:-false}"
COPY_TO_DATA_ROOT="${COPY_TO_DATA_ROOT:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-2000}"
DATASET_FPS="${DATASET_FPS:-30}"
VIDEO_CODEC="${VIDEO_CODEC:-libsvtav1}"

task_for_letter() {
    local letter="$1"
    printf 'pick up the letter %s from the top box and place it in the %s box' "$letter" "$letter"
}

echo "=== CUHK boxed pick-and-place recording ==="
echo "Letters: ${LETTERS[*]}"
echo "Dataset prefix: $DATASET_PREFIX"
echo "Episodes per letter: $EPISODES_PER_LETTER"
echo "Episode/reset seconds: $EPISODE_TIME_S / $RESET_TIME_S"
echo "Resume: $RESUME"
echo "Copy to /home/ubuntu/data: $COPY_TO_DATA_ROOT"
echo ""
echo "Before each letter, put only that letter block in the top/source box."
echo "Use Left Arrow to rerecord failed episodes. Keep only successful demonstrations."
echo ""

for letter in "${LETTERS[@]}"; do
    dataset_name="${DATASET_PREFIX}_${letter}"
    task_desc="$(task_for_letter "$letter")"

    echo "============================================================"
    echo "Next letter: $letter"
    echo "Dataset: $dataset_name"
    echo "Task: $task_desc"
    echo "Put letter $letter in the top/source box, then use the prompt below to start."
    echo "============================================================"

    COPY_TO_DATA_ROOT="$COPY_TO_DATA_ROOT" \
    CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
    DATASET_FPS="$DATASET_FPS" \
    VIDEO_CODEC="$VIDEO_CODEC" \
    bash "$SCRIPT_DIR/09_record_data.sh" \
        "$dataset_name" \
        "$task_desc" \
        "$EPISODES_PER_LETTER" \
        "$EPISODE_TIME_S" \
        "$RESET_TIME_S" \
        "$RESUME"
done

echo ""
echo "=== CUHK boxed pick-and-place recording sequence complete ==="
