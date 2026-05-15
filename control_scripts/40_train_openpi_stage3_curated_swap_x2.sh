#!/usr/bin/env bash
set -uo pipefail

# OpenPI pi0.5 CUHK curated Stage 3 recovery continuation training.
#
# Default run:
#   bash control_scripts/40_train_openpi_stage3_curated_swap_x2.sh
#
# Monitor:
#   bash control_scripts/40_train_openpi_stage3_curated_swap_x2.sh --status

OPENPI_DIR="${OPENPI_DIR:-/home/ubuntu/openpi}"
PYTHON_BIN="${PYTHON_BIN:-${OPENPI_DIR}/.venv/bin/python}"
CONFIG_NAME="${CONFIG_NAME:-pi05_so101_cuhksz_stage3_curated_swap_x2_lora}"
DATASET_ID="${DATASET_ID:-guanlin8/cuhksz_pi05_stage3_curated_swap_x2_20260505}"
LOG_DIR="${LOG_DIR:-/home/ubuntu/outputs/openpi/logs}"
RUN_PREFIX="${RUN_PREFIX:-pi05_so101_stage3_curated_swap_x2_20260505_$(date +%Y%m%d_%H%M%S)_from_stage2_50k_lr1e-5}"
MANAGER_LOG="${LOG_DIR}/${RUN_PREFIX}_manager.log"
PID_FILE="${LOG_DIR}/${RUN_PREFIX}_manager.pid"
NUM_TRAIN_STEPS="${NUM_TRAIN_STEPS:-50000}"
BATCH_SIZES="${BATCH_SIZES:-2 1}"
STATS_FILE="${STATS_FILE:-/home/ubuntu/outputs/openpi/assets/${CONFIG_NAME}/${DATASET_ID}/norm_stats.json}"
RESUME="${RESUME:-0}"

OOM_PATTERN="(out of memory|oom|resource exhausted|RESOURCE_EXHAUSTED|CUDA_ERROR_OUT_OF_MEMORY|cannot allocate memory|failed to allocate)"

latest_stage3_curated_log() {
  find "$LOG_DIR" -maxdepth 1 -type f \
    -name 'pi05_so101_stage3_curated_swap_x2_20260505_*_from_stage2_50k_lr1e-5*_b*.log' \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}'
}

latest_manager_pid_file() {
  find "$LOG_DIR" -maxdepth 1 -type f \
    -name 'pi05_so101_stage3_curated_swap_x2_20260505_*_from_stage2_50k_lr1e-5*_manager.pid' \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}'
}

show_status() {
  echo "=== OpenPI Stage 3 curated-swap manager ==="
  local manager_pid_file manager_pid
  manager_pid_file="$(latest_manager_pid_file || true)"
  if [[ -n "${manager_pid_file:-}" ]]; then
    manager_pid="$(cat "$manager_pid_file" 2>/dev/null || true)"
    echo "PID file: $manager_pid_file"
    echo "PID: ${manager_pid:-unknown}"
    if [[ -n "${manager_pid:-}" ]] && kill -0 "$manager_pid" 2>/dev/null; then
      ps -p "$manager_pid" -o pid,ppid,stat,etime,cmd
    else
      echo "Manager is not running."
    fi
  else
    echo "No Stage 3 curated-swap manager pid file found in $LOG_DIR"
  fi
  echo
  echo "=== OpenPI Stage 3 curated-swap training processes ==="
  ps -ef \
    | grep -E 'compute_norm_stats.py|scripts/train.py|40_train_openpi_stage3_curated_swap_x2' \
    | grep -v grep \
    | grep -v -- '--status' || true
  echo
  echo "=== Latest Stage 3 curated-swap train log ==="
  local latest_log
  latest_log="$(latest_stage3_curated_log || true)"
  if [[ -z "${latest_log:-}" ]]; then
    echo "No Stage 3 curated-swap train log found in $LOG_DIR"
    return 0
  fi
  echo "$latest_log"
  grep -E 'Step|loss|Saving checkpoint|Finished|Error|Traceback|RESOURCE_EXHAUSTED|out of memory|OOM' "$latest_log" | tail -30 || tail -30 "$latest_log"
}

stop_training() {
  echo "Stopping OpenPI Stage 3 curated-swap training processes..."
  pkill -TERM -f "scripts/train.py ${CONFIG_NAME}" 2>/dev/null || true
  pkill -TERM -f "40_train_openpi_stage3_curated_swap_x2.sh" 2>/dev/null || true
  sleep 2
  show_status
}

run_manager() {
  mkdir -p "$LOG_DIR"
  exec >> "$MANAGER_LOG" 2>&1

  echo "=== OpenPI pi0.5 SO101 Stage 3 curated-swap training manager ==="
  echo "Started: $(date -Is)"
  echo "Config: $CONFIG_NAME"
  echo "Dataset: $DATASET_ID"
  echo "Run prefix: $RUN_PREFIX"
  echo "Steps: $NUM_TRAIN_STEPS"
  echo "Batch sizes: $BATCH_SIZES"
  echo "Norm stats: $STATS_FILE"
  echo "Resume: $RESUME"

  cd "$OPENPI_DIR" || exit 1

  if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "Python binary not found: $PYTHON_BIN"
    exit 1
  fi

  export PYTHONPATH="/home/ubuntu/Evo-RL/src"
  export HF_LEROBOT_HOME="/home/ubuntu/data"
  export XLA_PYTHON_CLIENT_MEM_FRACTION="${XLA_PYTHON_CLIENT_MEM_FRACTION:-0.92}"
  export XLA_PYTHON_CLIENT_PREALLOCATE="${XLA_PYTHON_CLIENT_PREALLOCATE:-false}"
  export XLA_FLAGS="${XLA_FLAGS:-} --xla_gpu_enable_triton_gemm=false"
  export PYTHONUNBUFFERED="1"

  if [[ ! -f "$STATS_FILE" ]]; then
    echo "Computing OpenPI norm stats..."
    "$PYTHON_BIN" scripts/compute_norm_stats.py \
      --config-name "$CONFIG_NAME" \
      --batch-size "${NORM_STATS_BATCH_SIZE:-16}" \
      --num-workers "${NORM_STATS_NUM_WORKERS:-4}"
  else
    echo "Found existing norm stats."
  fi

  for BATCH_SIZE in $BATCH_SIZES; do
    EXP_NAME="${RUN_PREFIX}_b${BATCH_SIZE}"
    TRAIN_LOG="${LOG_DIR}/${EXP_NAME}.log"
    TRAIN_PID_FILE="${LOG_DIR}/${EXP_NAME}.pid"

    echo
    echo "=== Attempting Stage 3 curated-swap training with batch_size=${BATCH_SIZE} ==="
    echo "Experiment: $EXP_NAME"
    echo "Train log: $TRAIN_LOG"
    echo "$$" > "$TRAIN_PID_FILE"

    TRAIN_MODE_ARGS=(--overwrite)
    if [[ "$RESUME" == "1" ]]; then
      TRAIN_MODE_ARGS=(--resume)
    fi

    "$PYTHON_BIN" scripts/train.py "$CONFIG_NAME" \
      --exp-name "$EXP_NAME" \
      --batch-size "$BATCH_SIZE" \
      --num-train-steps "$NUM_TRAIN_STEPS" \
      --log-interval 50 \
      --save-interval 1000 \
      --keep-period 5000 \
      --no-wandb-enabled \
      "${TRAIN_MODE_ARGS[@]}" \
      >> "$TRAIN_LOG" 2>&1
    STATUS=$?

    if [[ "$STATUS" -eq 0 ]]; then
      echo "Training finished successfully with batch_size=${BATCH_SIZE}"
      echo "$EXP_NAME" > "${LOG_DIR}/${RUN_PREFIX}_successful_exp.txt"
      echo "Finished: $(date -Is)"
      exit 0
    fi

    echo "Training exited with status $STATUS for batch_size=${BATCH_SIZE}"
    if grep -Eiq "$OOM_PATTERN" "$TRAIN_LOG"; then
      echo "OOM-like failure detected. Trying smaller batch size."
      continue
    fi

    echo "Failure did not look like OOM. Not retrying automatically."
    echo "Inspect: $TRAIN_LOG"
    exit "$STATUS"
  done

  echo "All batch sizes failed with OOM-like errors."
  exit 1
}

case "${1:-}" in
  --status)
    show_status
    exit 0
    ;;
  --stop)
    stop_training
    exit 0
    ;;
esac

if [[ "${_STAGE3_CURATED_MANAGER:-0}" == "1" ]]; then
  run_manager
fi

mkdir -p "$LOG_DIR"
setsid env _STAGE3_CURATED_MANAGER=1 \
  OPENPI_DIR="$OPENPI_DIR" \
  PYTHON_BIN="$PYTHON_BIN" \
  CONFIG_NAME="$CONFIG_NAME" \
  DATASET_ID="$DATASET_ID" \
  LOG_DIR="$LOG_DIR" \
  RUN_PREFIX="$RUN_PREFIX" \
  MANAGER_LOG="$MANAGER_LOG" \
  PID_FILE="$PID_FILE" \
  NUM_TRAIN_STEPS="$NUM_TRAIN_STEPS" \
  BATCH_SIZES="$BATCH_SIZES" \
  STATS_FILE="$STATS_FILE" \
  RESUME="$RESUME" \
  "$0" >> /dev/null 2>&1 < /dev/null &
PID=$!
echo "$PID" > "$PID_FILE"

echo "Started OpenPI Stage 3 curated-swap training manager."
echo "PID: $PID"
echo "Manager log: $MANAGER_LOG"
echo "Status: bash control_scripts/40_train_openpi_stage3_curated_swap_x2.sh --status"
