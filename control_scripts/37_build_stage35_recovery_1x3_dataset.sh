#!/usr/bin/env bash
set -euo pipefail

# Build the OpenPI pi0.5 Stage 3.5 recovery-heavy aggregate dataset.
#
# Composition:
#   - Stage 2 main-disorder aggregate: 1x
#   - Stage 3 recovery pool: 3x
#
# The resulting LeRobot dataset uses one unified task prompt for all episodes.

ROOT="${ROOT:-/home/ubuntu/data}"
PYTHON_BIN="${PYTHON_BIN:-/home/ubuntu/anaconda3/envs/evo-rl/bin/python}"
EVO_REPO_DIR="${EVO_REPO_DIR:-/home/ubuntu/Evo-RL}"
TARGET_REPO="${TARGET_REPO:-guanlin8/cuhksz_pi05_stage35_recovery_1x3_20260505}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_ROOT="${LOG_ROOT:-/home/ubuntu/evo-rl-control/outputs/dataset_build_logs}"
LOG_FILE="${LOG_ROOT}/${RUN_STAMP}_stage35_recovery_1x3.log"

TASK="Sort the visible CUHK letter blocks into the lower target slots in left-to-right order C, U, H, K."

STAGE2_REPO="guanlin8/cuhksz_pi05_stage2_main_disorder_20260504"
RECOVERY_REPOS=(
  "guanlin8/cuhksz_recovery_random_c_with_uhk_20260503"
  "guanlin8/cuhksz_recovery_random_u_with_hk_20260504"
  "guanlin8/cuhksz_recovery_random_h_with_k_20260504"
  "guanlin8/cuhksz_recovery_swap_cu_20260504"
  "guanlin8/cuhksz_recovery_swap_uh_20260504"
  "guanlin8/cuhksz_recovery_swap_hk_20260504"
  "guanlin8/cuhksz_recovery_swap_ch_20260504"
  "guanlin8/cuhksz_recovery_swap_uk_20260504"
  "guanlin8/cuhksz_recovery_swap_ck_20260504"
  "guanlin8/cuhksz_recovery_triple_c_hku_20260504"
  "guanlin8/cuhksz_recovery_triple_h_u_kc_20260504"
  "guanlin8/cuhksz_recovery_triple_uk_h_c_20260504"
  "guanlin8/cuhksz_recovery_triple_uhc_k_20260504"
  "guanlin8/cuhksz_recovery_triple_kc_h_u_20260504"
  "guanlin8/cuhksz_recovery_swap_cu_20260505"
  "guanlin8/cuhksz_recovery_swap_ch_20260505"
  "guanlin8/cuhksz_recovery_swap_ck_20260505"
  "guanlin8/cuhksz_recovery_swap_uh_20260505"
  "guanlin8/cuhksz_recovery_swap_hk_20260505"
  "guanlin8/cuhksz_recovery_swap_uk_20260505"
)

mkdir -p "$LOG_ROOT"
exec > >(tee "$LOG_FILE") 2>&1

echo "=== Build OpenPI Stage 3.5 recovery 1:3 dataset ==="
echo "Target: $TARGET_REPO"
echo "Root: $ROOT"
echo "Log: $LOG_FILE"
echo "Force rebuild: $FORCE_REBUILD"
echo

export PYTHONPATH="$EVO_REPO_DIR/src"

target_dir="$ROOT/$TARGET_REPO"
if [[ -e "$target_dir" ]]; then
  if [[ "$FORCE_REBUILD" != "1" ]]; then
    echo "Target already exists: $target_dir"
    echo "Set FORCE_REBUILD=1 to move it aside and rebuild."
    exit 1
  fi
  backup="${target_dir}.backup_${RUN_STAMP}"
  echo "Moving existing target to: $backup"
  mv "$target_dir" "$backup"
fi

for repo in "$STAGE2_REPO" "${RECOVERY_REPOS[@]}"; do
  if [[ ! -d "$ROOT/$repo" ]]; then
    echo "Missing source dataset: $ROOT/$repo" >&2
    exit 1
  fi
done

repo_list_python="$(mktemp)"
python - "$repo_list_python" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
stage2 = "guanlin8/cuhksz_pi05_stage2_main_disorder_20260504"
recovery = [
    "guanlin8/cuhksz_recovery_random_c_with_uhk_20260503",
    "guanlin8/cuhksz_recovery_random_u_with_hk_20260504",
    "guanlin8/cuhksz_recovery_random_h_with_k_20260504",
    "guanlin8/cuhksz_recovery_swap_cu_20260504",
    "guanlin8/cuhksz_recovery_swap_uh_20260504",
    "guanlin8/cuhksz_recovery_swap_hk_20260504",
    "guanlin8/cuhksz_recovery_swap_ch_20260504",
    "guanlin8/cuhksz_recovery_swap_uk_20260504",
    "guanlin8/cuhksz_recovery_swap_ck_20260504",
    "guanlin8/cuhksz_recovery_triple_c_hku_20260504",
    "guanlin8/cuhksz_recovery_triple_h_u_kc_20260504",
    "guanlin8/cuhksz_recovery_triple_uk_h_c_20260504",
    "guanlin8/cuhksz_recovery_triple_uhc_k_20260504",
    "guanlin8/cuhksz_recovery_triple_kc_h_u_20260504",
    "guanlin8/cuhksz_recovery_swap_cu_20260505",
    "guanlin8/cuhksz_recovery_swap_ch_20260505",
    "guanlin8/cuhksz_recovery_swap_ck_20260505",
    "guanlin8/cuhksz_recovery_swap_uh_20260505",
    "guanlin8/cuhksz_recovery_swap_hk_20260505",
    "guanlin8/cuhksz_recovery_swap_uk_20260505",
]
repos = [stage2] + recovery * 3
path.write_text(repr(repos), encoding="utf-8")
print(f"merge_repo_count={len(repos)}")
print(f"recovery_repo_count={len(recovery)}")
PY

repo_list="$(cat "$repo_list_python")"
rm -f "$repo_list_python"

echo "Merging datasets..."
"$PYTHON_BIN" -m lerobot.scripts.lerobot_edit_dataset \
  --root "$ROOT" \
  --repo_id "$TARGET_REPO" \
  --operation.type merge \
  --operation.repo_ids "$repo_list"

echo
echo "Forcing unified task prompt..."
"$PYTHON_BIN" -m lerobot.scripts.lerobot_edit_dataset \
  --root "$ROOT" \
  --repo_id "$TARGET_REPO" \
  --operation.type modify_tasks \
  --operation.new_task "$TASK"

echo
echo "Adding Stage 3.5 provenance to info.json..."
"$PYTHON_BIN" - "$ROOT/$TARGET_REPO" <<'PY'
import json
import pathlib

root = pathlib.Path(__import__("sys").argv[1])
info_path = root / "meta" / "info.json"
info = json.loads(info_path.read_text())
info["stage35_unified_prompt"] = "Sort the visible CUHK letter blocks into the lower target slots in left-to-right order C, U, H, K."
info["stage35_mix"] = {
    "stage2_replay_copies": 1,
    "recovery_pool_copies": 3,
    "stage2_frames_expected": 88302,
    "recovery_frames_one_pass_expected": 133724,
    "recovery_ratio_expected": 401172 / 489474,
}
info_path.write_text(json.dumps(info, indent=2) + "\n")
PY

echo
echo "Validating aggregate..."
"$PYTHON_BIN" -m lerobot.scripts.lerobot_dataset_report \
  --dataset "$TARGET_REPO" \
  --root "$ROOT"

echo
echo "Summary:"
"$PYTHON_BIN" - "$ROOT/$TARGET_REPO" <<'PY'
import json
import pathlib
import pandas as pd
import sys

root = pathlib.Path(sys.argv[1])
info = json.loads((root / "meta" / "info.json").read_text())
tasks = pd.read_parquet(root / "meta" / "tasks.parquet")
data = pd.read_parquet(root / "data" / "chunk-000" / "file-000.parquet", columns=["task_index", "episode_index"])
episodes = pd.read_parquet(root / "meta" / "episodes" / "chunk-000" / "file-000.parquet", columns=["episode_index", "length", "tasks"])
print(f"episodes={info['total_episodes']}")
print(f"frames={info['total_frames']}")
print(f"task_rows={len(tasks)}")
print(f"task_index_values={sorted(data['task_index'].unique().tolist())}")
print(f"episode_range={int(episodes['episode_index'].min())}:{int(episodes['episode_index'].max())}")
print(f"first_task={tasks.iloc[0].to_dict()}")
PY

echo
echo "Done. Dataset: $ROOT/$TARGET_REPO"
