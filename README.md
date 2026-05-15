# Recoverable VLA LoRA Stacking

Clean experiment code for prompted curriculum learning and LoRA stacking on the
SO101 CUHK letter-sorting benchmark. It includes scripts for SO101 teleoperation,
demonstration recording, dataset construction, pi0.5 LoRA training, LoRA
stacking, and real-robot deployment.

This repository accompanies the final project for **CUHKSZ CSC6052: Natural
Language Processing**, Spring 2026.

## Demo Videos

[![Demo preview](assets/demo_preview.gif)](https://doi.org/10.5281/zenodo.20058809)

Click the link to watch the full demo video: https://doi.org/10.5281/zenodo.20058809

## Layout

- `scripts/`: curated paper workflow scripts for SO101 teleoperation,
  demonstration recording, dataset aggregation, OpenPI pi0.5 LoRA training, and
  real-robot deployment.
- `openpi/`: OpenPI source snapshot used by the experiments.  The important
  project-specific files are:
  - `openpi/src/openpi/policies/so101_policy.py`
  - `openpi/src/openpi/training/config.py`
  - `openpi/src/openpi/training/data_loader.py`
  - `openpi/scripts/train.py`
  - `openpi/scripts/compute_norm_stats.py`
  - `openpi/scripts/serve_policy.py`
- `recoverable_vla_lora_stacking/`: project-specific Python package.  Its
  `lora_stacking.py` module implements the weight-space Curriculum LoRA
  Stacking exporter used in the report.
- `tests/`: lightweight tests for the stacking math.

## Main Workflow

All commands below assume the repository root is this cloned repository. The
original experiment scripts default to the lab paths used during data
collection; override the environment variables when running on a different
machine.

### 1. Teleoperate SO101

```bash
OPENPI_DIR="$PWD/openpi" \
bash scripts/teleoperate_so101.sh
```

### 2. Record Curriculum Demonstrations

Bootstrap grounding demonstrations:

```bash
bash scripts/record_bootstrap_grounding.sh all
```

Failure recovery and hard-state demonstrations:

```bash
bash scripts/record_swap_recovery.sh all
bash scripts/record_two_random_two_fixed.sh all
bash scripts/record_near_slot_alignment.sh all
```

### 3. Build Aggregated Datasets

```bash
bash scripts/build_stage3_recovery_dataset.sh
bash scripts/build_stage4_curriculum_dataset.sh
```

### 4. Train pi0.5 LoRA Policies

Stage 3 curated recovery:

```bash
OPENPI_DIR="$PWD/openpi" \
PYTHON_BIN="$PWD/openpi/.venv/bin/python" \
bash scripts/train_stage3_recovery_lora.sh
```

Stage 4 recovery/alignment continuation:

```bash
OPENPI_DIR="$PWD/openpi" \
PYTHON_BIN="$PWD/openpi/.venv/bin/python" \
bash scripts/train_stage4_curriculum_lora.sh
```

The configs used by these launchers live in
`openpi/src/openpi/training/config.py`.

### 5. Export LoRA Stacking Checkpoint

```bash
PYTHONPATH="$PWD/openpi/src:$PWD" python -m recoverable_vla_lora_stacking.lora_stacking \
  --adapter stage2=/path/to/stage2/50000/params \
  --adapter stage3=/path/to/stage3/49999/params \
  --adapter stage4=/path/to/stage4/49999/params \
  --alpha stage2=0.45 --alpha stage3=0.35 --alpha stage4=0.20 \
  --adapter-mode sequential-delta \
  --output-checkpoint /path/to/stacked_checkpoint \
  --overwrite
```

Use `sequential-delta` for this project's continuation checkpoints.  It
recovers the explicit stage updates as `stage2`, `stage3 - stage2`, and
`stage4 - stage3` before applying the simplex weights.

### 6. Deploy pi0.5 on SO101

```bash
OPENPI_DIR="$PWD/openpi" \
OPENPI_PYTHON="$PWD/openpi/.venv/bin/python" \
OPENPI_CONFIG=pi05_so101_cuhksz_stage4_s2_recovery_x1_stage4_x4_lora \
OPENPI_CHECKPOINT=/path/to/checkpoint \
bash scripts/deploy_openpi_so101.sh \
  "Sort the visible CUHK letter blocks into the lower target slots in left-to-right order C, U, H, K."
```

The same deployment script can serve a stacked checkpoint by setting
`OPENPI_CHECKPOINT=/path/to/stacked_checkpoint`.

## Quick Checks

```bash
python -m pytest tests -q
bash -n scripts/*.sh
python -m py_compile recoverable_vla_lora_stacking/*.py scripts/*.py
```

These checks validate syntax and the standalone LoRA stacking math.  Real
training and deployment require the robot hardware, datasets, OpenPI/LeRobot
runtime dependencies, and the external checkpoints described in the report.
