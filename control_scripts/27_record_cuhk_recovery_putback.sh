#!/usr/bin/env bash
# ============================================================
# Record CUHK put-back recovery datasets.
#
# Scenario:
#   - Some CUHK target slots may already contain correctly placed blocks.
#   - One letter block has been moved back to the top/source box.
#   - Demonstrate picking that visible block and returning it to its matching slot.
#
# Usage:
#   bash control_scripts/27_record_cuhk_recovery_putback.sh
#   bash control_scripts/27_record_cuhk_recovery_putback.sh C
#   C_EPISODES=16 U_EPISODES=16 H_EPISODES=16 K_EPISODES=10 bash control_scripts/27_record_cuhk_recovery_putback.sh all
#   RESET_TIME_S=10 bash control_scripts/27_record_cuhk_recovery_putback.sh C
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

DATASET_PREFIX="${DATASET_PREFIX:-guanlin8/cuhksz_recovery_putback_spatial_20260503}"
C_EPISODES="${C_EPISODES:-15}"
U_EPISODES="${U_EPISODES:-15}"
H_EPISODES="${H_EPISODES:-15}"
K_EPISODES="${K_EPISODES:-10}"
EPISODE_TIME_S="${EPISODE_TIME_S:-20}"
RESET_TIME_S="${RESET_TIME_S:-10}"
RESUME="${RESUME:-false}"
COPY_TO_DATA_ROOT="${COPY_TO_DATA_ROOT:-1}"
CAMERA_MAX_AGE_MS="${CAMERA_MAX_AGE_MS:-2000}"
DATASET_FPS="${DATASET_FPS:-30}"
VIDEO_CODEC="${VIDEO_CODEC:-libsvtav1}"

episodes_for_letter() {
    case "$1" in
        C) printf '%s' "$C_EPISODES" ;;
        U) printf '%s' "$U_EPISODES" ;;
        H) printf '%s' "$H_EPISODES" ;;
        K) printf '%s' "$K_EPISODES" ;;
        *) return 1 ;;
    esac
}

ordinal_for_letter() {
    case "$1" in
        C) printf 'first' ;;
        U) printf 'second' ;;
        H) printf 'third' ;;
        K) printf 'fourth' ;;
        *) return 1 ;;
    esac
}

task_for_letter() {
    local letter="$1"
    local ordinal
    ordinal="$(ordinal_for_letter "$letter")"
    printf 'The target slots from left to right are C, U, H, K. Pick up the visible %s block and place it in the %s target slot, the %s slot from the left.' "$letter" "$letter" "$ordinal"
}

echo "=== CUHK put-back recovery recording ==="
echo "Letters: ${LETTERS[*]}"
echo "Dataset prefix: $DATASET_PREFIX"
echo "Episode targets: C=$C_EPISODES U=$U_EPISODES H=$H_EPISODES K=$K_EPISODES"
echo "Episode/reset seconds: $EPISODE_TIME_S / $RESET_TIME_S"
echo "Resume: $RESUME"
echo "Copy to /home/ubuntu/data: $COPY_TO_DATA_ROOT"
echo ""
echo "Protocol:"
echo "  1. Keep the target slot layout fixed: C, U, H, K from left to right."
echo "  2. Put the requested visible letter in the top/source box."
echo "  3. Other already completed letters may remain in their correct slots."
echo "  4. Demonstrate a clean return to the matching slot, then withdraw."
echo "  5. Use Left Arrow to rerecord failed, hesitant, blocked, or wrong-slot episodes."
echo ""

for letter in "${LETTERS[@]}"; do
    dataset_name="${DATASET_PREFIX}_${letter}"
    task_desc="$(task_for_letter "$letter")"
    episodes="$(episodes_for_letter "$letter")"

    echo "============================================================"
    echo "Next put-back letter: $letter"
    echo "Dataset: $dataset_name"
    echo "Episodes: $episodes"
    echo "Task: $task_desc"
    echo "Place visible $letter in the top/source box before starting."
    echo "============================================================"

    COPY_TO_DATA_ROOT="$COPY_TO_DATA_ROOT" \
    CAMERA_MAX_AGE_MS="$CAMERA_MAX_AGE_MS" \
    DATASET_FPS="$DATASET_FPS" \
    VIDEO_CODEC="$VIDEO_CODEC" \
    bash "$SCRIPT_DIR/09_record_data.sh" \
        "$dataset_name" \
        "$task_desc" \
        "$episodes" \
        "$EPISODE_TIME_S" \
        "$RESET_TIME_S" \
        "$RESUME"
done

echo ""
echo "=== CUHK put-back recovery recording sequence complete ==="
