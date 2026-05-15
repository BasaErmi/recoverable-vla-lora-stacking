#!/usr/bin/env bash
set -uo pipefail

OPENPI_DIR="/home/ubuntu/openpi"
PYTHON_BIN="${OPENPI_DIR}/.venv/bin/python"
CONFIG_NAME="pi05_so101_cuhksz_slots_lora"
DATASET_ID="guanlin8/cuhksz_pick_place_slots_ordered_20260430_all"
STATS_FILE="/home/ubuntu/outputs/openpi/assets/${CONFIG_NAME}/${DATASET_ID}/norm_stats.json"
LOG_DIR="/home/ubuntu/outputs/openpi/logs"
RUN_PREFIX="pi05_so101_cuhksz_slots_lora_$(date +%Y%m%d_%H%M%S)"
MANAGER_LOG="${LOG_DIR}/${RUN_PREFIX}_manager.log"

mkdir -p "${LOG_DIR}"
exec >> "${MANAGER_LOG}" 2>&1

echo "=== OpenPI pi0.5 SO101 LoRA training manager ==="
echo "Started: $(date -Is)"
echo "Config: ${CONFIG_NAME}"
echo "Dataset: ${DATASET_ID}"
echo "Norm stats: ${STATS_FILE}"
echo "Run prefix: ${RUN_PREFIX}"

cd "${OPENPI_DIR}" || exit 1

if [[ ! -x "${PYTHON_BIN}" ]]; then
  echo "Python binary not found: ${PYTHON_BIN}"
  exit 1
fi

echo "Ensuring LeRobot v3-compatible datasets package is installed..."
/home/ubuntu/.local/bin/uv pip install "datasets==4.1.1"

echo "Waiting for norm stats..."
while [[ ! -f "${STATS_FILE}" ]]; do
  sleep 60
  echo "Still waiting for norm stats: $(date -Is)"
done
echo "Found norm stats: ${STATS_FILE}"

export PYTHONPATH="/home/ubuntu/Evo-RL/src"
export HF_LEROBOT_HOME="/home/ubuntu/data"
export XLA_PYTHON_CLIENT_MEM_FRACTION="0.92"
export XLA_PYTHON_CLIENT_PREALLOCATE="false"
export XLA_FLAGS="${XLA_FLAGS:-} --xla_gpu_enable_triton_gemm=false"
export PYTHONUNBUFFERED="1"

OOM_PATTERN="(out of memory|oom|resource exhausted|RESOURCE_EXHAUSTED|CUDA_ERROR_OUT_OF_MEMORY|cannot allocate memory|failed to allocate)"

for BATCH_SIZE in 8 4 2 1; do
  EXP_NAME="${RUN_PREFIX}_b${BATCH_SIZE}"
  TRAIN_LOG="${LOG_DIR}/${EXP_NAME}.log"
  PID_FILE="${LOG_DIR}/${EXP_NAME}.pid"

  echo
  echo "=== Attempting training with batch_size=${BATCH_SIZE} ==="
  echo "Experiment: ${EXP_NAME}"
  echo "Train log: ${TRAIN_LOG}"
  echo "$$" > "${PID_FILE}"

  "${PYTHON_BIN}" scripts/train.py "${CONFIG_NAME}" \
    --exp-name "${EXP_NAME}" \
    --batch-size "${BATCH_SIZE}" \
    --num-train-steps 15000 \
    --log-interval 50 \
    --save-interval 1000 \
    --keep-period 5000 \
    --no-wandb-enabled \
    --overwrite \
    >> "${TRAIN_LOG}" 2>&1
  STATUS=$?

  if [[ "${STATUS}" -eq 0 ]]; then
    echo "Training finished successfully with batch_size=${BATCH_SIZE}"
    echo "${EXP_NAME}" > "${LOG_DIR}/${RUN_PREFIX}_successful_exp.txt"
    echo "Finished: $(date -Is)"
    exit 0
  fi

  echo "Training exited with status ${STATUS} for batch_size=${BATCH_SIZE}"
  if grep -Eiq "${OOM_PATTERN}" "${TRAIN_LOG}"; then
    echo "OOM-like failure detected. Trying smaller batch size."
    continue
  fi

  echo "Failure did not look like OOM. Not retrying automatically."
  echo "Inspect: ${TRAIN_LOG}"
  exit "${STATUS}"
done

echo "All batch sizes failed with OOM-like errors."
exit 1
