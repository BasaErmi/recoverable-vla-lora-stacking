#!/usr/bin/env bash
set -euo pipefail

# Build the OpenPI pi0.5 CUHK Stage 4 aggregate dataset.
#
# Composition:
#   - Stage 2 main-disorder aggregate: 1x
#   - Curated Stage 3 recovery pool: 1x
#   - New Stage 4 two-random/alignment data: 4x

ROOT="${ROOT:-/home/ubuntu/data}"
PYTHON_BIN="${PYTHON_BIN:-/home/ubuntu/anaconda3/envs/evo-rl/bin/python}"
EVO_REPO_DIR="${EVO_REPO_DIR:-/home/ubuntu/Evo-RL}"
TARGET_REPO="${TARGET_REPO:-guanlin8/cuhksz_pi05_stage4_s2_recovery_x1_stage4_x4_20260506}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_ROOT="${LOG_ROOT:-/home/ubuntu/evo-rl-control/outputs/dataset_build_logs}"
LOG_FILE="${LOG_ROOT}/${RUN_STAMP}_stage4_s2_recovery_x1_stage4_x4.log"

TASK="Sort the visible CUHK letter blocks into the lower target slots in left-to-right order C, U, H, K."

STAGE2_REPO="guanlin8/cuhksz_pi05_stage2_main_disorder_20260504"
RECOVERY_REPOS=(
  "guanlin8/cuhksz_recovery_swap_cu_20260504"
  "guanlin8/cuhksz_recovery_swap_cu_20260505"
  "guanlin8/cuhksz_recovery_swap_ch_20260504"
  "guanlin8/cuhksz_recovery_swap_ch_20260505"
  "guanlin8/cuhksz_recovery_swap_ck_20260504"
  "guanlin8/cuhksz_recovery_swap_ck_20260505"
  "guanlin8/cuhksz_recovery_swap_uh_20260504"
  "guanlin8/cuhksz_recovery_swap_uh_20260505"
  "guanlin8/cuhksz_recovery_swap_hk_20260504"
  "guanlin8/cuhksz_recovery_swap_hk_20260505"
  "guanlin8/cuhksz_recovery_swap_uk_20260504"
  "guanlin8/cuhksz_recovery_swap_uk_20260505"
  "guanlin8/cuhksz_recovery_random_c_with_uhk_20260503"
  "guanlin8/cuhksz_recovery_random_u_with_hk_20260504"
  "guanlin8/cuhksz_recovery_random_h_with_k_20260504"
  "guanlin8/cuhksz_recovery_random_k_with_cuh_20260504"
)
STAGE4_REPOS=(
  "guanlin8/cuhksz_stage4_two_random_cu_two_fixed_20260506"
  "guanlin8/cuhksz_stage4_two_random_ch_two_fixed_20260506"
  "guanlin8/cuhksz_stage4_two_random_ck_two_fixed_20260506"
  "guanlin8/cuhksz_stage4_two_random_uh_two_fixed_20260506"
  "guanlin8/cuhksz_stage4_two_random_uk_two_fixed_20260506"
  "guanlin8/cuhksz_stage4_two_random_hk_two_fixed_20260506"
  "guanlin8/cuhksz_stage4_near_slot_align_c_20260506"
  "guanlin8/cuhksz_stage4_near_slot_align_u_20260506"
  "guanlin8/cuhksz_stage4_near_slot_align_h_20260506"
  "guanlin8/cuhksz_stage4_near_slot_align_k_20260506"
)

mkdir -p "$LOG_ROOT"
exec > >(tee "$LOG_FILE") 2>&1

echo "=== Build OpenPI Stage 4 s2+recovery x1, stage4 x4 dataset ==="
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

for repo in "$STAGE2_REPO" "${RECOVERY_REPOS[@]}" "${STAGE4_REPOS[@]}"; do
  if [[ ! -d "$ROOT/$repo" ]]; then
    echo "Missing source dataset: $ROOT/$repo" >&2
    exit 1
  fi
done

echo "Creating normalized temporary source copies and merging datasets..."
TEMP_ROOT="${ROOT}/.tmp_stage4_s2_recovery_x1_stage4_x4_${RUN_STAMP}"
trap 'rm -rf "$TEMP_ROOT"' EXIT

"$PYTHON_BIN" - "$ROOT" "$TEMP_ROOT" "$TARGET_REPO" "$TASK" <<'PY'
import json
import os
import pathlib
import shutil
import sys

import pandas as pd

from lerobot.datasets.aggregate import aggregate_datasets

root = pathlib.Path(sys.argv[1])
temp_root = pathlib.Path(sys.argv[2])
target_repo = sys.argv[3]
task = sys.argv[4]

stage2 = "guanlin8/cuhksz_pi05_stage2_main_disorder_20260504"
recovery = [
    "guanlin8/cuhksz_recovery_swap_cu_20260504",
    "guanlin8/cuhksz_recovery_swap_cu_20260505",
    "guanlin8/cuhksz_recovery_swap_ch_20260504",
    "guanlin8/cuhksz_recovery_swap_ch_20260505",
    "guanlin8/cuhksz_recovery_swap_ck_20260504",
    "guanlin8/cuhksz_recovery_swap_ck_20260505",
    "guanlin8/cuhksz_recovery_swap_uh_20260504",
    "guanlin8/cuhksz_recovery_swap_uh_20260505",
    "guanlin8/cuhksz_recovery_swap_hk_20260504",
    "guanlin8/cuhksz_recovery_swap_hk_20260505",
    "guanlin8/cuhksz_recovery_swap_uk_20260504",
    "guanlin8/cuhksz_recovery_swap_uk_20260505",
    "guanlin8/cuhksz_recovery_random_c_with_uhk_20260503",
    "guanlin8/cuhksz_recovery_random_u_with_hk_20260504",
    "guanlin8/cuhksz_recovery_random_h_with_k_20260504",
    "guanlin8/cuhksz_recovery_random_k_with_cuh_20260504",
]
stage4 = [
    "guanlin8/cuhksz_stage4_two_random_cu_two_fixed_20260506",
    "guanlin8/cuhksz_stage4_two_random_ch_two_fixed_20260506",
    "guanlin8/cuhksz_stage4_two_random_ck_two_fixed_20260506",
    "guanlin8/cuhksz_stage4_two_random_uh_two_fixed_20260506",
    "guanlin8/cuhksz_stage4_two_random_uk_two_fixed_20260506",
    "guanlin8/cuhksz_stage4_two_random_hk_two_fixed_20260506",
    "guanlin8/cuhksz_stage4_near_slot_align_c_20260506",
    "guanlin8/cuhksz_stage4_near_slot_align_u_20260506",
    "guanlin8/cuhksz_stage4_near_slot_align_h_20260506",
    "guanlin8/cuhksz_stage4_near_slot_align_k_20260506",
]
repos = [stage2] + recovery + stage4 * 4
print(f"merge_repo_count={len(repos)}")
print(f"recovery_repo_count={len(recovery)}")
print(f"stage4_repo_count={len(stage4)}")

def link_or_copy(src: str, dst: str) -> None:
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)

unique_repos = [stage2] + recovery + stage4
for repo in unique_repos:
    src = root / repo
    dst = temp_root / repo
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst, copy_function=link_or_copy, symlinks=True)

    tasks_path = dst / "meta" / "tasks.parquet"
    if tasks_path.exists():
        tasks_path.unlink()
    pd.DataFrame({"task_index": [0]}, index=pd.Index([task], name=None)).to_parquet(tasks_path)

    info_path = dst / "meta" / "info.json"
    info = json.loads(info_path.read_text())
    info["total_tasks"] = 1
    info_path.unlink()
    info_path.write_text(json.dumps(info, indent=2) + "\n")

roots = [temp_root / repo for repo in repos]
aggregate_datasets(
    repo_ids=repos,
    aggr_repo_id=target_repo,
    roots=roots,
    aggr_root=root / target_repo,
)
PY

echo
echo "Forcing unified episode-level task metadata..."
"$PYTHON_BIN" - "$ROOT/$TARGET_REPO" "$TASK" <<'PY'
import pathlib
import sys

import pandas as pd

root = pathlib.Path(sys.argv[1])
task = sys.argv[2]

for path in sorted((root / "meta" / "episodes").glob("chunk-*/file-*.parquet")):
    df = pd.read_parquet(path)
    df["tasks"] = [[task] for _ in range(len(df))]
    path.unlink()
    df.to_parquet(path)
PY

echo
echo "Adding Stage 4 provenance to info.json..."
"$PYTHON_BIN" - "$ROOT/$TARGET_REPO" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
info_path = root / "meta" / "info.json"
info = json.loads(info_path.read_text())
info["stage4_s2_recovery_x1_stage4_x4_unified_prompt"] = (
    "Sort the visible CUHK letter blocks into the lower target slots in left-to-right order C, U, H, K."
)
info["stage4_s2_recovery_x1_stage4_x4_mix"] = {
    "stage2_replay_copies": 1,
    "curated_recovery_copies": 1,
    "stage4_new_copies": 4,
    "stage2_frames_expected": 88302,
    "curated_recovery_frames_expected": 112753,
    "stage4_frames_one_pass_expected": 45141,
    "total_frames_expected": 381619,
    "stage2_ratio_expected": 88302 / 381619,
    "curated_recovery_ratio_expected": 112753 / 381619,
    "stage4_ratio_expected": (45141 * 4) / 381619,
    "stage4_sources": [
        "cuhksz_stage4_two_random_cu_two_fixed_20260506",
        "cuhksz_stage4_two_random_ch_two_fixed_20260506",
        "cuhksz_stage4_two_random_ck_two_fixed_20260506",
        "cuhksz_stage4_two_random_uh_two_fixed_20260506",
        "cuhksz_stage4_two_random_uk_two_fixed_20260506",
        "cuhksz_stage4_two_random_hk_two_fixed_20260506",
        "cuhksz_stage4_near_slot_align_c_20260506",
        "cuhksz_stage4_near_slot_align_u_20260506",
        "cuhksz_stage4_near_slot_align_h_20260506",
        "cuhksz_stage4_near_slot_align_k_20260506",
    ],
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
import sys

import pandas as pd
import pyarrow.dataset as pa_ds

root = pathlib.Path(sys.argv[1])
info = json.loads((root / "meta" / "info.json").read_text())
tasks = pd.read_parquet(root / "meta" / "tasks.parquet")
episodes_ds = pa_ds.dataset(root / "meta" / "episodes", format="parquet")
episodes = episodes_ds.to_table(columns=["episode_index", "length", "tasks"]).to_pandas()
data_ds = pa_ds.dataset(root / "data", format="parquet")
data = data_ds.to_table(columns=["task_index"]).to_pandas()
print(f"episodes={info['total_episodes']}")
print(f"frames={info['total_frames']}")
print(f"task_rows={len(tasks)}")
print(f"task_index_values={sorted(data['task_index'].unique().tolist())}")
print(f"episode_range={int(episodes['episode_index'].min())}:{int(episodes['episode_index'].max())}")
print(f"first_task={tasks.iloc[0].to_dict()}")
PY

echo
echo "Done. Dataset: $ROOT/$TARGET_REPO"
