#!/bin/bash
# ============================================================
# ACT pick-and-place deployment preset using the older rollout parameters.
#
# Usage:
#   bash control_scripts/23_deploy_act_pick_and_place_old_params.sh
#   bash control_scripts/23_deploy_act_pick_and_place_old_params.sh "pick up the object and place it in the target area"
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export JOB_PREFIX="${JOB_PREFIX:-act_cuhksz_pick_and_place}"

export CLIENT_FPS="${CLIENT_FPS:-30}"
export ACTIONS_PER_CHUNK="${ACTIONS_PER_CHUNK:-100}"
export CHUNK_SIZE_THRESHOLD="${CHUNK_SIZE_THRESHOLD:-0.3}"
export AGGREGATE_FN_NAME="${AGGREGATE_FN_NAME:-conservative}"
export ACTION_COMMIT_HORIZON="${ACTION_COMMIT_HORIZON:-0}"
export SINGLE_ACTION_REQUEST_IN_FLIGHT="${SINGLE_ACTION_REQUEST_IN_FLIGHT:-1}"

export MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-3}"
export ACTION_EMA_ALPHA="${ACTION_EMA_ALPHA:-0.6}"
export ACTION_MAX_DELTA="${ACTION_MAX_DELTA:-1.5}"
export GRIPPER_ACTION_MAX_DELTA="${GRIPPER_ACTION_MAX_DELTA:-6}"
export GRIPPER_MAX_RELATIVE_TARGET="${GRIPPER_MAX_RELATIVE_TARGET:-100}"

export LOG_ACTIONS="${LOG_ACTIONS:-1}"
export DIAGNOSTIC_LOGS="${DIAGNOSTIC_LOGS:-1}"
export DIAGNOSTIC_EVERY_N="${DIAGNOSTIC_EVERY_N:-1}"
export RESTART_SERVER_FOR_DIAGNOSTICS="${RESTART_SERVER_FOR_DIAGNOSTICS:-1}"

TASK="${1:-pick up the object and place it in the target area}"
exec bash "$SCRIPT_DIR/22_deploy_act_pick_and_place_responsive.sh" "$TASK"
