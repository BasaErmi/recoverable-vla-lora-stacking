#!/bin/bash
# ============================================================
# Step 4: LIBERO 仿真环境评估
# 目标: 在 LIBERO benchmark 上验证 pi0.5 推理效果
# 前提: 已完成 step 1-3
# ============================================================

set -e
cd Evo-RL

# ----------------------------------------------------------
# 方式 A: 使用预训练 LIBERO 微调模型 (推荐先跑这个)
# 预期结果: ~97% 成功率 (官方 benchmark)
# ----------------------------------------------------------
echo "=== 评估 pi0.5 LIBERO finetuned 模型 ==="

PYTHONPATH=src lerobot-eval \
  --policy.path=lerobot/pi05_libero_finetuned \
  --env.type=libero \
  --env.task=libero_spatial \
  --eval.batch_size=1 \
  --eval.n_episodes=10 \
  --output_dir=../outputs/eval/pi05_libero_spatial

# ----------------------------------------------------------
# 方式 B: 评估 base 模型 (zero-shot，预期效果差)
# ----------------------------------------------------------
# PYTHONPATH=src lerobot-eval \
#   --policy.path=lerobot/pi05_base \
#   --env.type=libero \
#   --env.task=libero_spatial \
#   --eval.batch_size=1 \
#   --eval.n_episodes=10 \
#   --output_dir=../outputs/eval/pi05_base_libero_spatial

# ----------------------------------------------------------
# 方式 C: 本地模型路径
# ----------------------------------------------------------
# PYTHONPATH=src lerobot-eval \
#   --policy.path=../models/pi05_libero_finetuned \
#   --env.type=libero \
#   --env.task=libero_spatial \
#   --eval.batch_size=1 \
#   --eval.n_episodes=10 \
#   --output_dir=../outputs/eval/pi05_local_libero_spatial

echo ""
echo "=== 评估完成 ==="
echo "结果保存在: ../outputs/eval/"
echo "下一步: 查看评估结果，确认推理流程正确后开始 SFT 训练"
