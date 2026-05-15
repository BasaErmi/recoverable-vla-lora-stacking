#!/usr/bin/env bash
# ============================================================
# Record CUHK Stage 2.5 random-letter recovery datasets.
#
# Scenario:
#   - One visible letter starts from a displaced/random source pose.
#   - Conditions are named by future letters in the CUHK sequence:
#       C: with/no UHK
#       U: with/no HK, with C already placed as prior context
#       H: with/no K, with C/U already placed as prior context
#       K: with CUH as prior context
#   - The target layout remains fixed: C, U, H, K from left to right.
#   - Demonstrate picking the visible letter and placing it into its target slot.
#
# Usage:
#   bash control_scripts/29_record_cuhk_stage25_random_letter.sh U with_hk
#   bash control_scripts/29_record_cuhk_stage25_random_letter.sh U no_hk
#   bash control_scripts/29_record_cuhk_stage25_random_letter.sh K
#   bash control_scripts/29_record_cuhk_stage25_random_letter.sh U all
#   NUM_EPISODES=20 bash control_scripts/29_record_cuhk_stage25_random_letter.sh U no_hk
#
# Hotkeys are inherited from control_scripts/09_record_data.sh:
#   Right Arrow  - finish current episode, start next
#   Left Arrow   - rerecord current episode
#   Esc          - stop recording
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LETTER="$(printf '%s' "${1:-U}" | tr '[:lower:]' '[:upper:]')"
RAW_CONDITION_ARG="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
LEGACY_WITH_OTHERS=""
LEGACY_NO_OTHERS=""

case "$LETTER" in
    C)
        ORDINAL="first"
        TARGET_SLOT="C"
        DEFAULT_WITH_OTHERS="with_uhk"
        DEFAULT_NO_OTHERS="no_uhk"
        DEFAULT_CONDITION="no_uhk"
        DEFAULT_OTHERS="U/H/K"
        WITH_CONTEXT="no prior letters"
        NO_CONTEXT="no prior letters"
        PRESENT_LINE="Place U, H, and K in their correct lower slots. Put C in a random reachable source pose."
        ABSENT_LINE="Remove U, H, and K. Put only C in a random reachable source pose."
        ;;
    U)
        ORDINAL="second"
        TARGET_SLOT="U"
        DEFAULT_WITH_OTHERS="with_hk"
        DEFAULT_NO_OTHERS="no_hk"
        DEFAULT_CONDITION="no_hk"
        DEFAULT_OTHERS="H/K"
        LEGACY_WITH_OTHERS="with_chk"
        LEGACY_NO_OTHERS="no_chk"
        WITH_CONTEXT="C already placed correctly"
        NO_CONTEXT="C already placed correctly"
        PRESENT_LINE="Place C, H, and K in their correct lower slots. Put U in a random reachable source pose."
        ABSENT_LINE="Place C in the correct lower slot. Remove H and K. Put only U in a random reachable source pose."
        ;;
    H)
        ORDINAL="third"
        TARGET_SLOT="H"
        DEFAULT_WITH_OTHERS="with_k"
        DEFAULT_NO_OTHERS="no_k"
        DEFAULT_CONDITION="no_k"
        DEFAULT_OTHERS="K"
        LEGACY_WITH_OTHERS="with_cuk"
        LEGACY_NO_OTHERS="no_cuk"
        WITH_CONTEXT="C and U already placed correctly"
        NO_CONTEXT="C and U already placed correctly"
        PRESENT_LINE="Place C, U, and K in their correct lower slots. Put H in a random reachable source pose."
        ABSENT_LINE="Place C and U in their correct lower slots. Remove K. Put only H in a random reachable source pose."
        ;;
    K)
        ORDINAL="fourth"
        TARGET_SLOT="K"
        DEFAULT_WITH_OTHERS="with_cuh"
        DEFAULT_NO_OTHERS="no_cuh"
        DEFAULT_CONDITION="with_cuh"
        DEFAULT_OTHERS="C/U/H"
        WITH_CONTEXT="K is the final letter in the CUHK sequence"
        NO_CONTEXT="no prior letters"
        PRESENT_LINE="Place C, U, and H in their correct lower slots. Put K in a random reachable source pose."
        ABSENT_LINE="Remove C, U, and H. Put only K in a random reachable source pose."
        ;;
    *)
        echo "ERROR: first argument must be one of: C, U, H, K" >&2
        exit 1
        ;;
esac
LETTER_LOWER="$(printf '%s' "$LETTER" | tr '[:upper:]' '[:lower:]')"
CONDITION_ARG="${RAW_CONDITION_ARG:-$DEFAULT_CONDITION}"
if [ "$LETTER" = "K" ]; then
    DEFAULT_RESET_TIME_S="5"
else
    DEFAULT_RESET_TIME_S="10"
fi

if [ -n "$LEGACY_WITH_OTHERS" ] && [ "$CONDITION_ARG" = "$LEGACY_WITH_OTHERS" ]; then
    echo "WARNING: condition '$CONDITION_ARG' is a legacy name; using '$DEFAULT_WITH_OTHERS' for progressive CUHK context." >&2
    CONDITION_ARG="$DEFAULT_WITH_OTHERS"
elif [ -n "$LEGACY_NO_OTHERS" ] && [ "$CONDITION_ARG" = "$LEGACY_NO_OTHERS" ]; then
    echo "WARNING: condition '$CONDITION_ARG' is a legacy name; using '$DEFAULT_NO_OTHERS' for progressive CUHK context." >&2
    CONDITION_ARG="$DEFAULT_NO_OTHERS"
fi

conditions_for_arg() {
    case "$CONDITION_ARG" in
        all|both)
            printf '%s\n%s\n' "$DEFAULT_WITH_OTHERS" "$DEFAULT_NO_OTHERS"
            ;;
        "$DEFAULT_WITH_OTHERS"|with_others)
            printf '%s\n' "$DEFAULT_WITH_OTHERS"
            ;;
        "$DEFAULT_NO_OTHERS"|no_others|without_others)
            printf '%s\n' "$DEFAULT_NO_OTHERS"
            ;;
        *)
            echo "ERROR: unsupported condition '$CONDITION_ARG' for letter $LETTER." >&2
            echo "Use one of: $DEFAULT_WITH_OTHERS, $DEFAULT_NO_OTHERS, with_others, no_others, all" >&2
            exit 1
            ;;
    esac
}

NUM_EPISODES="${NUM_EPISODES:-15}"
EPISODE_TIME_S="${EPISODE_TIME_S:-20}"
RESET_TIME_S="${RESET_TIME_S:-$DEFAULT_RESET_TIME_S}"
RESUME="${RESUME:-false}"
COPY_TO_DATA_ROOT="${COPY_TO_DATA_ROOT:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-2000}"
DATASET_FPS="${DATASET_FPS:-30}"
VIDEO_CODEC="${VIDEO_CODEC:-libsvtav1}"
TASK_DESC="${TASK_DESC:-The target slots from left to right are C, U, H, K. Pick up the visible ${LETTER} block and place it in the ${TARGET_SLOT} target slot, the ${ORDINAL} slot from the left.}"

mapfile -t CONDITIONS < <(conditions_for_arg)

for CONDITION in "${CONDITIONS[@]}"; do
    if [ "$CONDITION" = "$DEFAULT_WITH_OTHERS" ]; then
        DATASET_SUFFIX="$CONDITION"
        CONDITION_DESC="$WITH_CONTEXT; $DEFAULT_OTHERS are already placed correctly; only $LETTER starts from a random source pose."
        SETUP_LINE="$PRESENT_LINE"
    else
        DATASET_SUFFIX="with_${CONDITION}"
        CONDITION_DESC="$NO_CONTEXT; $DEFAULT_OTHERS are absent; only $LETTER starts from a random source pose."
        SETUP_LINE="$ABSENT_LINE"
    fi

    DATASET_NAME="${DATASET_NAME:-guanlin8/cuhksz_recovery_random_${LETTER_LOWER}_${DATASET_SUFFIX}_20260504}"

    echo "=== CUHK Stage 2.5 random-letter recovery recording ==="
    echo "Letter: $LETTER"
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
    echo "  4. Vary $LETTER source position and block orientation across episodes."
    echo "  5. Keep the $LETTER target slot fixed; do not move target boxes during this dataset."
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

    unset DATASET_NAME
done
