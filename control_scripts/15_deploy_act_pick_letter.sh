#!/bin/bash
# ============================================================
# Deploy the latest ACT pick-letter checkpoint through the existing
# SO101 async inference launcher.
#
# Usage:
#   bash control_scripts/15_deploy_act_pick_letter.sh C
#   ACT_MODEL_PATH=/home/ubuntu/outputs/train/.../checkpoints/last/pretrained_model bash control_scripts/15_deploy_act_pick_letter.sh C
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_HOST="${LAB_HOST:-local}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/home/ubuntu/outputs/train}"
JOB_PREFIX="${JOB_PREFIX:-act_cuhksz_pick_C_corrective}"

is_local_lab() {
    case "$LAB_HOST" in
        local|localhost|127.0.0.1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

case "${1:-}" in
    -h|--help)
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

if [ -z "${ACT_MODEL_PATH:-}" ]; then
    if is_local_lab; then
        ACT_MODEL_PATH="$(ls -td "$OUTPUT_ROOT"/${JOB_PREFIX}_*/checkpoints/last/pretrained_model 2>/dev/null | head -1 || true)"
    else
        ACT_MODEL_PATH="$(ssh "$LAB_HOST" "ls -td '$OUTPUT_ROOT'/${JOB_PREFIX}_*/checkpoints/last/pretrained_model 2>/dev/null | head -1 || true")"
    fi
fi

if [ -z "$ACT_MODEL_PATH" ]; then
    echo "ERROR: no ACT checkpoint found. Train first with:" >&2
    echo "  bash control_scripts/14_train_act_pick_letter.sh" >&2
    exit 1
fi

echo "Deploying ACT checkpoint:"
echo "  $ACT_MODEL_PATH"
echo ""

export POLICY_TYPE="${POLICY_TYPE:-act}"
export MODEL_PATH="$ACT_MODEL_PATH"
export CLIENT_FPS="${CLIENT_FPS:-10}"
export ACTIONS_PER_CHUNK="${ACTIONS_PER_CHUNK:-10}"
export CHUNK_SIZE_THRESHOLD="${CHUNK_SIZE_THRESHOLD:-0.25}"
export MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-4}"
export ACTION_EMA_ALPHA="${ACTION_EMA_ALPHA:-0.3}"
export ACTION_MAX_DELTA="${ACTION_MAX_DELTA:-3}"
export GRIPPER_ACTION_MAX_DELTA="${GRIPPER_ACTION_MAX_DELTA:-8}"
export GRIPPER_MAX_RELATIVE_TARGET="${GRIPPER_MAX_RELATIVE_TARGET:-100}"
export LOG_ACTIONS="${LOG_ACTIONS:-1}"
export ASYNC_OBSERVATION_SEND="${ASYNC_OBSERVATION_SEND:-1}"
export OBSERVATION_SEND_QUEUE_SIZE="${OBSERVATION_SEND_QUEUE_SIZE:-1}"
export OBSERVATION_SEND_TIMEOUT_MS="${OBSERVATION_SEND_TIMEOUT_MS:-800}"
export MAX_ACTION_AGE_MS="${MAX_ACTION_AGE_MS:-500}"
export REBASE_ACTION_TIMESTAMPS_ON_RECEIVE="${REBASE_ACTION_TIMESTAMPS_ON_RECEIVE:-1}"

bash "$SCRIPT_DIR/12_deploy_pick_letter.sh" "${1:-C}"
