#!/bin/bash
# ============================================================
# Train an ACT baseline for SO101 pick-letter data on lab.
#
# Usage:
#   bash control_scripts/14_train_act_pick_letter.sh
#   STEPS=10000 BATCH_SIZE=2 bash control_scripts/14_train_act_pick_letter.sh
#   bash control_scripts/14_train_act_pick_letter.sh --status
#   bash control_scripts/14_train_act_pick_letter.sh --stop
# ============================================================

set -euo pipefail

LAB_HOST="${LAB_HOST:-local}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-/home/ubuntu/Evo-RL}"
REMOTE_PYTHON="${REMOTE_PYTHON:-/home/ubuntu/anaconda3/envs/evo-rl/bin/python}"

DATASET_REPO_ID="${DATASET_REPO_ID:-guanlin8/cuhksz_pick_C_corrective_20260426}"
DATASET_ROOT="${DATASET_ROOT:-/home/ubuntu/data/$DATASET_REPO_ID}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/home/ubuntu/outputs/train}"

STEPS="${STEPS:-20000}"
BATCH_SIZE="${BATCH_SIZE:-2}"
CHUNK_SIZE="${CHUNK_SIZE:-30}"
N_ACTION_STEPS="${N_ACTION_STEPS:-10}"
SAVE_FREQ="${SAVE_FREQ:-2500}"
LOG_FREQ="${LOG_FREQ:-100}"
NUM_WORKERS="${NUM_WORKERS:-4}"
POLICY_DEVICE="${POLICY_DEVICE:-cuda}"
PRETRAINED_BACKBONE_WEIGHTS="${PRETRAINED_BACKBONE_WEIGHTS:-ResNet18_Weights.IMAGENET1K_V1}"

JOB_PREFIX="${JOB_PREFIX:-act_cuhksz_pick_C_corrective}"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
JOB_NAME="${JOB_PREFIX}_b${BATCH_SIZE}_${STEPS}_${RUN_ID}"
OUTPUT_DIR="$OUTPUT_ROOT/$JOB_NAME"
LOG_DIR="${LOG_DIR:-/home/ubuntu/outputs/train_logs}"
TRAIN_LOG="$LOG_DIR/$JOB_NAME.log"
PID_FILE="$LOG_DIR/$JOB_NAME.pid"

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

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

lab_exec() {
    local command="$1"

    if is_local_lab; then
        bash -lc "$command"
    else
        ssh "$LAB_HOST" "$command"
    fi
}

status() {
    lab_exec \
        "OUTPUT_ROOT='$OUTPUT_ROOT' JOB_PREFIX='$JOB_PREFIX' LOG_DIR='$LOG_DIR' STEPS='$STEPS' SAVE_FREQ='$SAVE_FREQ' LOG_FREQ='$LOG_FREQ' REMOTE_PYTHON='$REMOTE_PYTHON' bash -s" <<'REMOTE_STATUS'
set -euo pipefail

echo '=== ACT training processes ==='
ps -ef | grep -E 'lerobot.scripts.lerobot_train|lerobot-train' | grep -- '--policy.type=act' | grep -v grep || true
echo ''
echo '=== Latest ACT outputs ==='
ls -td "$OUTPUT_ROOT"/${JOB_PREFIX}_* 2>/dev/null | head -5 || true
echo ''
echo '=== Latest ACT logs ==='
latest_log=$(ls -t "$LOG_DIR"/${JOB_PREFIX}_*.log 2>/dev/null | head -1 || true)
if [ -n "$latest_log" ]; then
    echo "$latest_log"
    echo ''
    echo '=== Exact progress ==='
    LATEST_LOG="$latest_log" TOTAL_STEPS="$STEPS" SAVE_FREQ="$SAVE_FREQ" LOG_FREQ="$LOG_FREQ" "$REMOTE_PYTHON" - <<'PY'
import os
import re
from pathlib import Path

def fmt_duration(seconds: float) -> str:
    seconds = max(0, int(round(seconds)))
    hours, rem = divmod(seconds, 3600)
    minutes, seconds = divmod(rem, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"

log_path = Path(os.environ["LATEST_LOG"])
total_steps = int(os.environ["TOTAL_STEPS"])
save_freq = int(os.environ["SAVE_FREQ"])
log_freq = int(os.environ["LOG_FREQ"])

lines = log_path.read_text(errors="replace").splitlines()
entries = []
for line in lines:
    match = re.search(
        r"step:\S+\b.*?loss:([0-9.eE+-]+).*?grdn:([0-9.eE+-]+).*?lr:([0-9.eE+-]+).*?updt_s:([0-9.]+).*?data_s:([0-9.]+)",
        line,
    )
    if match:
        exact_step = min((len(entries) + 1) * log_freq, total_steps)
        entries.append(
            (
                exact_step,
                float(match.group(1)),
                float(match.group(2)),
                float(match.group(3)),
                float(match.group(4)),
                float(match.group(5)),
            )
        )

completed = any("End of training" in line for line in lines)

if not entries:
    print(f"log_path={log_path}")
    print(f"total_steps={total_steps}")
    print("current_step=0")
    print("remaining_steps=unknown")
    print("eta=unknown")
else:
    current_step, loss, grad_norm, lr, update_s, data_s = entries[-1]
    if completed:
        current_step = total_steps
    recent = entries[-10:]
    avg_step_s = sum(item[4] + item[5] for item in recent) / len(recent)
    remaining_steps = max(total_steps - current_step, 0)
    eta_s = 0.0 if completed else remaining_steps * avg_step_s

    if save_freq > 0 and not completed and current_step < total_steps:
        next_checkpoint_step = min(((current_step // save_freq) + 1) * save_freq, total_steps)
        next_checkpoint_eta_s = max(next_checkpoint_step - current_step, 0) * avg_step_s
    else:
        next_checkpoint_step = "complete"
        next_checkpoint_eta_s = 0.0

    print(f"log_path={log_path}")
    print(f"current_step={current_step}")
    print(f"total_steps={total_steps}")
    print(f"remaining_steps={remaining_steps}")
    print(f"completed={str(completed).lower()}")
    print(f"last_loss={loss:.6f}")
    print(f"last_grad_norm={grad_norm:.6f}")
    print(f"last_lr={lr:.8f}")
    print(f"avg_step_seconds={avg_step_s:.4f}")
    print(f"eta={fmt_duration(eta_s)}")
    print(f"next_checkpoint_step={next_checkpoint_step}")
    print(f"next_checkpoint_eta={fmt_duration(next_checkpoint_eta_s)}")
    print("recent_exact_events=")
    for step, loss, grad_norm, lr, update_s, data_s in entries[-20:]:
        print(
            f"  step={step}/{total_steps} "
            f"loss={loss:.6f} grad_norm={grad_norm:.6f} "
            f"lr={lr:.8f} update_s={update_s:.4f} data_s={data_s:.4f}"
        )
PY
    checkpoint_lines=$(grep -E 'Checkpoint policy after step|End of training|ERROR|Traceback' "$latest_log" | tail -20 || true)
    if [ -n "$checkpoint_lines" ]; then
        echo ''
        echo '=== Checkpoint/errors ==='
        printf '%s\n' "$checkpoint_lines"
    fi
fi
echo ''
echo '=== GPU ==='
nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits
REMOTE_STATUS
}

stop_training() {
    lab_exec "
        echo 'Stopping ACT training processes...'
        pkill -TERM -f 'lerobot.scripts.lerobot_train.*--policy.type=act' 2>/dev/null || true
        pkill -TERM -f 'lerobot-train.*--policy.type=act' 2>/dev/null || true
        sleep 2
        ps -ef | grep -E 'lerobot.scripts.lerobot_train|lerobot-train' | grep -- '--policy.type=act' | grep -v grep || true
        nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits
    "
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --status)
        status
        exit 0
        ;;
    --stop)
        stop_training
        exit 0
        ;;
esac

echo "=== ACT Pick-Letter Training ==="
echo "Lab: $LAB_HOST"
echo "Dataset: $DATASET_REPO_ID"
echo "Dataset root: $DATASET_ROOT"
echo "Output dir: $OUTPUT_DIR"
echo "Train log: $TRAIN_LOG"
echo "Steps/batch/chunk: $STEPS / $BATCH_SIZE / $CHUNK_SIZE"
echo "N action steps: $N_ACTION_STEPS"
echo "Backbone weights: $PRETRAINED_BACKBONE_WEIGHTS"
echo ""

lab_exec "test -d '$DATASET_ROOT'" || {
    echo "ERROR: dataset root not found on lab: $DATASET_ROOT" >&2
    exit 1
}

lab_exec "mkdir -p '$LOG_DIR'"

lab_exec "cd '$REMOTE_REPO_DIR' && setsid bash -lc '
    set -euo pipefail
    PYTHONPATH=$REMOTE_REPO_DIR/src $REMOTE_PYTHON -m lerobot.scripts.lerobot_train \
      --dataset.repo_id=$DATASET_REPO_ID \
      --dataset.root=$DATASET_ROOT \
      --policy.type=act \
      --policy.device=$POLICY_DEVICE \
      --policy.push_to_hub=false \
      --policy.pretrained_backbone_weights=$PRETRAINED_BACKBONE_WEIGHTS \
      --policy.chunk_size=$CHUNK_SIZE \
      --policy.n_action_steps=$N_ACTION_STEPS \
      --output_dir=$OUTPUT_DIR \
      --job_name=$JOB_NAME \
      --batch_size=$BATCH_SIZE \
      --steps=$STEPS \
      --save_freq=$SAVE_FREQ \
      --log_freq=$LOG_FREQ \
      --eval_freq=0 \
      --num_workers=$NUM_WORKERS \
      --wandb.enable=false
' > '$TRAIN_LOG' 2>&1 < /dev/null & echo \$! > '$PID_FILE'"

echo "Started ACT training on lab."
echo "PID file: $PID_FILE"
echo "Monitor:"
echo "  bash control_scripts/14_train_act_pick_letter.sh --status"
if is_local_lab; then
    echo "  tail -f $TRAIN_LOG"
else
    echo "  ssh $LAB_HOST 'tail -f $TRAIN_LOG'"
fi
