#!/bin/bash
# ============================================================
# Responsive ACT deployment preset for SO101 pick-and-place.
#
# This keeps the official async inference path, but avoids executing a long
# stale chunk open-loop after the robot has already diverged from the plan.
#
# Usage:
#   bash control_scripts/22_deploy_act_pick_and_place_responsive.sh
#   bash control_scripts/22_deploy_act_pick_and_place_responsive.sh "pick up the object and place it in the target area"
#   ACT_MODEL_PATH=/home/ubuntu/outputs/train/.../checkpoints/last/pretrained_model bash control_scripts/22_deploy_act_pick_and_place_responsive.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export JOB_PREFIX="${JOB_PREFIX:-act_cuhksz_pick_and_place}"

# Match the recording rate and use the official async example cadence:
# 50 actions per chunk, refilling when about half the queue remains. This keeps
# overlap without replacing the plan every few actions.
export CLIENT_FPS="${CLIENT_FPS:-30}"
export ACTIONS_PER_CHUNK="${ACTIONS_PER_CHUNK:-50}"
export CHUNK_SIZE_THRESHOLD="${CHUNK_SIZE_THRESHOLD:-0.5}"
export AGGREGATE_FN_NAME="${AGGREGATE_FN_NAME:-weighted_average}"
export SINGLE_ACTION_REQUEST_IN_FLIGHT="${SINGLE_ACTION_REQUEST_IN_FLIGHT:-1}"
# Preserve the already-queued near-term plan for ~0.4s at 30Hz when a new
# chunk arrives. This prevents a fresh replan from immediately yanking the arm
# backward in the next few frames.
export ACTION_COMMIT_HORIZON="${ACTION_COMMIT_HORIZON:-12}"

# The dataset's body-joint per-frame max delta is roughly p90=2.7deg,
# p99=4.5deg, max=6.7deg. A 5deg safety limit preserves normal demonstration
# speed better than 3deg while still catching large jumps.
export MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-5}"
export ACTION_EMA_ALPHA="${ACTION_EMA_ALPHA:-0.35}"
export ACTION_MAX_DELTA="${ACTION_MAX_DELTA:-5}"
export GRIPPER_ACTION_MAX_DELTA="${GRIPPER_ACTION_MAX_DELTA:-5}"
export GRIPPER_MAX_RELATIVE_TARGET="${GRIPPER_MAX_RELATIVE_TARGET:-100}"

export LOG_ACTIONS="${LOG_ACTIONS:-1}"
export DIAGNOSTIC_LOGS="${DIAGNOSTIC_LOGS:-1}"
export DIAGNOSTIC_EVERY_N="${DIAGNOSTIC_EVERY_N:-1}"
export RESTART_SERVER_FOR_DIAGNOSTICS="${RESTART_SERVER_FOR_DIAGNOSTICS:-1}"

TASK="${1:-pick up the object and place it in the target area}"
exec bash "$SCRIPT_DIR/15_deploy_act_pick_letter.sh" "$TASK"
