#!/bin/bash
# Monitor the current ACT pick-and-place training run.

set -euo pipefail

cd "$(dirname "$0")/.."

export DATASET_REPO_ID="${DATASET_REPO_ID:-guanlin8/cuhksz_pick_and_place_20260429}"
export JOB_PREFIX="${JOB_PREFIX:-act_cuhksz_pick_and_place}"
export STEPS="${STEPS:-100000}"
export SAVE_FREQ="${SAVE_FREQ:-20000}"
export LOG_FREQ="${LOG_FREQ:-200}"

case "${1:-status}" in
    status)
        bash control_scripts/14_train_act_pick_letter.sh --status
        ;;
    tail)
        latest_log=$(ls -t /home/ubuntu/outputs/train_logs/${JOB_PREFIX}_b*_*.log 2>/dev/null | head -1 || true)
        if [ -z "$latest_log" ]; then
            echo "No log found for JOB_PREFIX=$JOB_PREFIX" >&2
            exit 1
        fi
        echo "$latest_log"
        tail -f "$latest_log"
        ;;
    gpu)
        watch -n 2 nvidia-smi
        ;;
    *)
        echo "Usage: $0 [status|tail|gpu]" >&2
        exit 1
        ;;
esac
