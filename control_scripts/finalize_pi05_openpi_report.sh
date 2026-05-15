#!/usr/bin/env bash
set -uo pipefail

RUN_PREFIX="${1:?run prefix required}"
MANAGER_PID="${2:-}"

LOG_DIR="/home/ubuntu/outputs/openpi/logs"
REPORT_DIR="/home/ubuntu/outputs/openpi/reports"
CHECKPOINT_BASE="/home/ubuntu/outputs/openpi/checkpoints/pi05_so101_cuhksz_slots_lora"
CONFIG_NAME="pi05_so101_cuhksz_slots_lora"
DATASET_ID="guanlin8/cuhksz_pick_place_slots_ordered_20260430_all"
REPORT="${REPORT_DIR}/${RUN_PREFIX}_report.md"

mkdir -p "${REPORT_DIR}"

if [[ -n "${MANAGER_PID}" ]]; then
  while kill -0 "${MANAGER_PID}" 2>/dev/null; do
    sleep 300
  done
fi

SUCCESS_FILE="${LOG_DIR}/${RUN_PREFIX}_successful_exp.txt"
MANAGER_LOG="${LOG_DIR}/${RUN_PREFIX}_manager.log"

STATUS="failed"
SUCCESS_EXP=""
if [[ -f "${SUCCESS_FILE}" ]]; then
  STATUS="completed"
  SUCCESS_EXP="$(tr -d '\n' < "${SUCCESS_FILE}")"
fi

ATTEMPTS="$(find "${LOG_DIR}" -maxdepth 1 -type f -name "${RUN_PREFIX}_b*.log" -printf "%f\n" | sort)"
LATEST_LOG=""
if [[ -n "${SUCCESS_EXP}" && -f "${LOG_DIR}/${SUCCESS_EXP}.log" ]]; then
  LATEST_LOG="${LOG_DIR}/${SUCCESS_EXP}.log"
else
  LATEST_LOG="$(find "${LOG_DIR}" -maxdepth 1 -type f -name "${RUN_PREFIX}_b*.log" | sort | tail -1)"
fi

LAST_STEP_LINES=""
if [[ -n "${LATEST_LOG}" && -f "${LATEST_LOG}" ]]; then
  LAST_STEP_LINES="$(grep -E "Step [0-9]+:" "${LATEST_LOG}" | tail -20 || true)"
fi

CHECKPOINTS=""
if [[ -n "${SUCCESS_EXP}" && -d "${CHECKPOINT_BASE}/${SUCCESS_EXP}" ]]; then
  CHECKPOINTS="$(find "${CHECKPOINT_BASE}/${SUCCESS_EXP}" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" | sort -n 2>/dev/null || true)"
fi

{
  echo "# OpenPI pi0.5 SO101 LoRA Report"
  echo
  echo "Generated: $(date -Is)"
  echo
  echo "## Run Status"
  echo
  echo "- Status: ${STATUS}"
  echo "- Config: ${CONFIG_NAME}"
  echo "- Dataset: ${DATASET_ID}"
  echo "- Run prefix: ${RUN_PREFIX}"
  echo "- Successful experiment: ${SUCCESS_EXP:-none}"
  echo "- Manager log: ${MANAGER_LOG}"
  echo "- Latest train log: ${LATEST_LOG:-none}"
  echo
  echo "## Training Parameters"
  echo
  echo "- Base checkpoint: gs://openpi-assets/checkpoints/pi05_base/params"
  echo "- Backend: official OpenPI JAX training path"
  echo "- LoRA variants: paligemma_variant=gemma_2b_lora, action_expert_variant=gemma_300m_lora"
  echo "- LoRA ranks: PaliGemma rank 16, action expert rank 32, as defined by OpenPI Gemma LoRA variants"
  echo "- Freeze policy: OpenPI model_config.get_freeze_filter(); train LoRA parameters only"
  echo "- EMA: disabled for LoRA"
  echo "- Batch retry order: 8 -> 4 -> 2 -> 1, retrying only for OOM-like failures"
  echo "- Steps: 15000"
  echo "- LR schedule: warmup 1000, peak_lr 2.5e-5, cosine decay to 2.5e-6"
  echo "- Optimizer: AdamW, clip_gradient_norm=1.0"
  echo "- Action horizon: 50"
  echo "- XLA workaround: --xla_gpu_enable_triton_gemm=false to avoid local ptxas GEMM-fusion crashes on this host"
  echo "- Action transform: first 5 SO101 joints as deltas, gripper absolute"
  echo "- State/action normalization: full-dataset OpenPI norm_stats over 61322 frames"
  echo "- Cameras: front -> base_0_rgb, wrist -> left_wrist_0_rgb, right_wrist_0_rgb masked false"
  echo "- Prompt source: LeRobot task field via prompt_from_task=True"
  echo
  echo "## Prompt Recommendation"
  echo
  echo "Use stage-specific but simple object-location prompts, not one unified prompt."
  echo
  echo "- C: pick up the letter C from the top box and place it in the C box"
  echo "- U: pick up the letter U from the top box and place it in the U box"
  echo "- H: pick up the letter H from the top box and place it in the H box"
  echo "- K: pick up the letter K from the top box and place it in the K box"
  echo
  echo "Reason: the recorded episodes are one-letter stages, not full autonomous spelling trajectories. A single prompt like \"Please pick and place CUHK\" would attach several different next-action modes to the same language condition and force the model to infer phase only from vision. The per-letter prompt keeps the language-action target unambiguous and still supports recovery when a letter is moved back to the top box."
  echo
  echo "## Research Basis"
  echo
  echo "- OpenPI README: pi0.5 base checkpoint, LeRobot custom data workflow, compute_norm_stats before training, and XLA memory guidance."
  echo "- OpenPI training config: official low-memory LoRA pattern uses gemma_2b_lora + gemma_300m_lora, get_freeze_filter(), and ema_decay=None."
  echo "- OpenPI README PyTorch note: PyTorch backend does not currently support LoRA, so official LoRA training should use JAX."
  echo "- LeRobot pi0.5/LIBERO practice: multi-view images, task descriptions for VLA training, and action chunking are expected."
  echo "- SO101-specific adaptation: because our LeRobot actions are absolute joint targets, arm joints are converted to deltas while gripper remains absolute."
  echo
  echo "## Attempts"
  echo
  if [[ -n "${ATTEMPTS}" ]]; then
    echo "${ATTEMPTS}" | sed 's/^/- /'
  else
    echo "- none"
  fi
  echo
  echo "## Last Training Metrics"
  echo
  if [[ -n "${LAST_STEP_LINES}" ]]; then
    echo '```text'
    echo "${LAST_STEP_LINES}"
    echo '```'
  else
    echo "No Step metrics found yet."
  fi
  echo
  echo "## Checkpoints"
  echo
  if [[ -n "${CHECKPOINTS}" ]]; then
    echo "${CHECKPOINTS}" | sed "s#^#- ${CHECKPOINT_BASE}/${SUCCESS_EXP}/#"
  else
    echo "- No completed checkpoint list found."
  fi
} > "${REPORT}"

echo "Wrote report: ${REPORT}"
