#!/usr/bin/env bash
set -euo pipefail

OPENPI_DIR="${OPENPI_DIR:-/home/ubuntu/openpi}"
PYTHON_BIN="${PYTHON_BIN:-${OPENPI_DIR}/.venv/bin/python}"
CONFIG_NAME="${CONFIG_NAME:-pi05_so101_cuhksz_stage2_main_disorder_lora}"
EXP_NAME="${EXP_NAME:-pi05_so101_stage2_main_disorder_20260504_20260504_052700_from_stage1_b2_norm_b2}"
CHECKPOINT_DIR="${CHECKPOINT_DIR:-/home/ubuntu/outputs/openpi/checkpoints/${CONFIG_NAME}/${EXP_NAME}}"
LOG_DIR="${LOG_DIR:-/home/ubuntu/outputs/openpi/logs}"
PRIMARY_MANAGER_LOG="${PRIMARY_MANAGER_LOG:-${LOG_DIR}/pi05_so101_stage2_main_disorder_20260504_20260504_052700_from_stage1_b2_norm_manager.log}"
PRIMARY_TRAIN_LOG="${PRIMARY_TRAIN_LOG:-${LOG_DIR}/${EXP_NAME}.log}"
CONTINUE_LOG="${CONTINUE_LOG:-${LOG_DIR}/${EXP_NAME}_resume_to_50k.log}"
MONITOR_LOG="${MONITOR_LOG:-${LOG_DIR}/${EXP_NAME}_auto_continue_monitor.log}"
PID_FILE="${PID_FILE:-${LOG_DIR}/${EXP_NAME}_resume_to_50k.pid}"
PRESERVE_DIR="${PRESERVE_DIR:-/home/ubuntu/outputs/openpi/checkpoints/${CONFIG_NAME}/preserved_global_stage2_20260504}"

CURRENT_TRAIN_PID="${CURRENT_TRAIN_PID:-830912}"
CURRENT_MANAGER_PID="${CURRENT_MANAGER_PID:-830908}"
TARGET_TOTAL_STEPS="${TARGET_TOTAL_STEPS:-50000}"
POLL_SECONDS="${POLL_SECONDS:-60}"

mkdir -p "$LOG_DIR" "$PRESERVE_DIR"

log() {
  echo "[$(date -Is)] $*" | tee -a "$MONITOR_LOG" >&2
}

pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

checkpoint_ready() {
  local dir="$1"
  [[ -d "$dir/params" && -d "$dir/train_state" ]]
}

max_checkpoint_step() {
  find "$CHECKPOINT_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' \
    | grep -E '^[0-9]+$' \
    | sort -n \
    | tail -n 1
}

wait_for_checkpoint() {
  local step="$1"
  local dir="$CHECKPOINT_DIR/$step"
  while ! checkpoint_ready "$dir"; do
    log "Waiting for checkpoint step ${step}: ${dir}"
    sleep "$POLL_SECONDS"
  done
  echo "$dir"
}

archive_checkpoint() {
  local label="$1"
  local src="$2"
  local dst="$PRESERVE_DIR/$label"
  local tmp="${dst}.tmp.$$"

  if [[ -e "$dst" ]]; then
    log "Archive ${label} already exists: ${dst}"
    return 0
  fi

  if ! checkpoint_ready "$src"; then
    log "ERROR: checkpoint is not ready for archive ${label}: ${src}"
    return 1
  fi

  rm -rf "$tmp"
  if cp -al "$src" "$tmp" 2>/dev/null; then
    :
  else
    rm -rf "$tmp"
    cp -a "$src" "$tmp"
  fi
  mv "$tmp" "$dst"
  log "Archived checkpoint ${label}: ${dst} -> ${src}"
}

wait_for_primary_training() {
  log "Monitoring primary 30k run. train_pid=${CURRENT_TRAIN_PID}, manager_pid=${CURRENT_MANAGER_PID}"
  while pid_alive "$CURRENT_TRAIN_PID" || pid_alive "$CURRENT_MANAGER_PID"; do
    local latest_step
    latest_step="$(max_checkpoint_step || true)"
    log "Primary still running. latest_checkpoint=${latest_step:-none}"
    sleep "$POLL_SECONDS"
  done

  log "Primary process exited; waiting for final checkpoint materialization."
  local waited=0
  while true; do
    if checkpoint_ready "$CHECKPOINT_DIR/29999"; then
      archive_checkpoint "30000" "$CHECKPOINT_DIR/29999"
      return 0
    fi
    if checkpoint_ready "$CHECKPOINT_DIR/30000"; then
      archive_checkpoint "30000" "$CHECKPOINT_DIR/30000"
      return 0
    fi
    if (( waited >= 1800 )); then
      log "ERROR: 30k checkpoint did not appear under ${CHECKPOINT_DIR}"
      return 1
    fi
    log "Waiting for 30k checkpoint. elapsed=${waited}s"
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
  done
}

start_resume_to_50k() {
  log "Starting resume run to ${TARGET_TOTAL_STEPS} total steps."
  cd "$OPENPI_DIR"

  export PYTHONPATH="/home/ubuntu/Evo-RL/src"
  export HF_LEROBOT_HOME="/home/ubuntu/data"
  export XLA_PYTHON_CLIENT_MEM_FRACTION="${XLA_PYTHON_CLIENT_MEM_FRACTION:-0.92}"
  export XLA_PYTHON_CLIENT_PREALLOCATE="${XLA_PYTHON_CLIENT_PREALLOCATE:-false}"
  export XLA_FLAGS="${XLA_FLAGS:-} --xla_gpu_enable_triton_gemm=false"
  export PYTHONUNBUFFERED="1"

  setsid "$PYTHON_BIN" scripts/train.py "$CONFIG_NAME" \
    --exp-name "$EXP_NAME" \
    --batch-size 2 \
    --num-train-steps "$TARGET_TOTAL_STEPS" \
    --log-interval 50 \
    --save-interval 1000 \
    --keep-period 5000 \
    --no-wandb-enabled \
    --resume \
    >> "$CONTINUE_LOG" 2>&1 < /dev/null &

  local pid="$!"
  echo "$pid" > "$PID_FILE"
  log "Resume process started. pid=${pid}, log=${CONTINUE_LOG}"
}

archive_resume_milestones() {
  archive_checkpoint "35000" "$(wait_for_checkpoint 35000)"
  archive_checkpoint "40000" "$(wait_for_checkpoint 40000)"
  archive_checkpoint "45000" "$(wait_for_checkpoint 45000)"

  local resume_pid
  resume_pid="$(cat "$PID_FILE")"
  while pid_alive "$resume_pid"; do
    local latest_step
    latest_step="$(max_checkpoint_step || true)"
    log "Resume still running. latest_checkpoint=${latest_step:-none}"
    sleep "$POLL_SECONDS"
  done

  if checkpoint_ready "$CHECKPOINT_DIR/49999"; then
    archive_checkpoint "50000" "$CHECKPOINT_DIR/49999"
  elif checkpoint_ready "$CHECKPOINT_DIR/50000"; then
    archive_checkpoint "50000" "$CHECKPOINT_DIR/50000"
  else
    log "ERROR: final 50k checkpoint was not found."
    return 1
  fi
}

main() {
  log "=== Stage2 auto-continue monitor started ==="
  log "checkpoint_dir=${CHECKPOINT_DIR}"
  log "preserve_dir=${PRESERVE_DIR}"
  wait_for_primary_training
  start_resume_to_50k
  archive_resume_milestones
  log "=== Stage2 auto-continue monitor finished ==="
}

main "$@"
