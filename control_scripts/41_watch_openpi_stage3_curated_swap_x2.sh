#!/usr/bin/env bash
set -euo pipefail

# Watchdog for the OpenPI Stage 3 curated-swap 50k run.
#
# It records step/loss progress and restarts the same run prefix with --resume
# if the manager exits before the target step is reached.

LOG_DIR="${LOG_DIR:-/home/ubuntu/outputs/openpi/logs}"
CHECKPOINT_BASE="${CHECKPOINT_BASE:-/home/ubuntu/outputs/openpi/checkpoints}"
CONFIG_NAME="${CONFIG_NAME:-pi05_so101_cuhksz_stage3_curated_swap_x2_lora}"
TRAIN_SCRIPT="${TRAIN_SCRIPT:-/home/ubuntu/evo-rl-control/control_scripts/40_train_openpi_stage3_curated_swap_x2.sh}"
RUN_PREFIX="${RUN_PREFIX:-}"
TARGET_STEPS="${TARGET_STEPS:-50000}"
POLL_SECONDS="${POLL_SECONDS:-120}"
STALE_SECONDS="${STALE_SECONDS:-900}"
MAX_RESTARTS="${MAX_RESTARTS:-6}"
WATCH_LOG_DIR="${WATCH_LOG_DIR:-/home/ubuntu/evo-rl-control/outputs/train_watch_logs}"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
WATCH_LOG="${WATCH_LOG:-${WATCH_LOG_DIR}/${RUN_STAMP}_stage3_curated_swap_x2_watch.log}"
METRICS_CSV="${METRICS_CSV:-${WATCH_LOG_DIR}/${RUN_STAMP}_stage3_curated_swap_x2_metrics.csv}"

mkdir -p "$WATCH_LOG_DIR"

log() {
  echo "[$(date -Is)] $*" | tee -a "$WATCH_LOG"
}

latest_manager_pid_file() {
  if [[ -n "$RUN_PREFIX" ]]; then
    printf '%s\n' "$LOG_DIR/${RUN_PREFIX}_manager.pid"
    return 0
  fi
  find "$LOG_DIR" -maxdepth 1 -type f \
    -name 'pi05_so101_stage3_curated_swap_x2_20260505_*_from_stage2_50k_lr1e-5*_manager.pid' \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}'
}

resolve_run_prefix() {
  local pid_file
  pid_file="$(latest_manager_pid_file || true)"
  if [[ -z "${pid_file:-}" ]]; then
    return 1
  fi
  basename "$pid_file" _manager.pid
}

manager_alive() {
  local pid_file="$LOG_DIR/${RUN_PREFIX}_manager.pid"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

training_alive() {
  pgrep -f "scripts/train.py ${CONFIG_NAME}.*--exp-name ${RUN_PREFIX}_b" >/dev/null 2>&1
}

latest_train_log() {
  find "$LOG_DIR" -maxdepth 1 -type f \
    -name "${RUN_PREFIX}_b*.log" \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}'
}

latest_progress() {
  local log_file="$1"
  python - "$log_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("0,,0,")
    raise SystemExit

step = 0
loss = ""
grad = ""
mtime = int(path.stat().st_mtime)
pattern = re.compile(r"Step\s+(\d+):\s+grad_norm=([0-9.eE+-]+),\s+loss=([0-9.eE+-]+)")
with path.open("r", errors="ignore") as f:
    for line in f:
        m = pattern.search(line)
        if m:
            step = int(m.group(1))
            grad = m.group(2)
            loss = m.group(3)
print(f"{step},{loss},{mtime},{grad}")
PY
}

max_checkpoint_step() {
  local max_step=0
  for exp_dir in "$CHECKPOINT_BASE/$CONFIG_NAME/${RUN_PREFIX}"_b*; do
    [[ -d "$exp_dir" ]] || continue
    while IFS= read -r step; do
      [[ "$step" =~ ^[0-9]+$ ]] || continue
      if (( step > max_step )); then
        max_step="$step"
      fi
    done < <(find "$exp_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null)
  done
  echo "$max_step"
}

checkpoint_ready() {
  local step="$1"
  for exp_dir in "$CHECKPOINT_BASE/$CONFIG_NAME/${RUN_PREFIX}"_b*; do
    [[ -d "$exp_dir/$step/params" && -d "$exp_dir/$step/train_state" ]] && return 0
  done
  return 1
}

restart_training() {
  local latest_log="$1"
  local ckpt_step
  ckpt_step="$(max_checkpoint_step)"
  local resume=0
  if (( ckpt_step > 0 )); then
    resume=1
  fi

  local batch_sizes="2 1"
  if [[ "$latest_log" == *_b1.log ]]; then
    batch_sizes="1"
  fi

  log "Restarting training: RUN_PREFIX=$RUN_PREFIX RESUME=$resume BATCH_SIZES=$batch_sizes latest_checkpoint=$ckpt_step"
  RUN_PREFIX="$RUN_PREFIX" \
    RESUME="$resume" \
    BATCH_SIZES="$batch_sizes" \
    NUM_TRAIN_STEPS="$TARGET_STEPS" \
    bash "$TRAIN_SCRIPT" >> "$WATCH_LOG" 2>&1
}

main() {
  if [[ -z "$RUN_PREFIX" ]]; then
    RUN_PREFIX="$(resolve_run_prefix)"
  fi
  if [[ -z "$RUN_PREFIX" ]]; then
    echo "ERROR: RUN_PREFIX is required, or a latest Stage 3 curated-swap manager pid must exist." >&2
    exit 1
  fi

  echo "timestamp,step,loss,grad_norm,checkpoint_step,manager_alive,training_alive,train_log" > "$METRICS_CSV"
  log "=== Stage 3 curated-swap watchdog started ==="
  log "run_prefix=$RUN_PREFIX"
  log "target_steps=$TARGET_STEPS poll=${POLL_SECONDS}s stale=${STALE_SECONDS}s max_restarts=$MAX_RESTARTS"
  log "watch_log=$WATCH_LOG"
  log "metrics_csv=$METRICS_CSV"

  local restarts=0
  while true; do
    local train_log step loss mtime grad ckpt_step now age manager_state train_state
    train_log="$(latest_train_log || true)"
    if [[ -n "${train_log:-}" ]]; then
      IFS=',' read -r step loss mtime grad < <(latest_progress "$train_log")
    else
      step=0
      loss=""
      grad=""
      mtime=0
    fi
    ckpt_step="$(max_checkpoint_step)"
    now="$(date +%s)"
    age=$((now - mtime))

    manager_state=0
    train_state=0
    manager_alive && manager_state=1 || true
    training_alive && train_state=1 || true

    echo "$(date -Is),$step,$loss,$grad,$ckpt_step,$manager_state,$train_state,${train_log:-}" >> "$METRICS_CSV"
    log "progress step=$step loss=${loss:-na} grad=${grad:-na} checkpoint=$ckpt_step manager=$manager_state train=$train_state log=${train_log:-none}"

    if checkpoint_ready 49999 || checkpoint_ready "$TARGET_STEPS"; then
      log "Final checkpoint is ready. Watchdog finished."
      exit 0
    fi

    if (( manager_state == 0 && train_state == 0 )); then
      if (( restarts >= MAX_RESTARTS )); then
        log "ERROR: max restarts reached before final checkpoint."
        exit 1
      fi
      restarts=$((restarts + 1))
      log "No active manager/training process before target. restart=$restarts/$MAX_RESTARTS"
      restart_training "${train_log:-}"
      sleep "$POLL_SECONDS"
      continue
    fi

    if [[ -n "${train_log:-}" && "$mtime" != "0" && "$age" -gt "$STALE_SECONDS" ]]; then
      log "WARNING: train log has been stale for ${age}s. Keeping watch; not killing active process automatically."
    fi

    sleep "$POLL_SECONDS"
  done
}

main "$@"
