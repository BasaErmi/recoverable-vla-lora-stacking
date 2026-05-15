#!/bin/bash
# ============================================================
# Step 2: 下载 pi0.5 预训练权重 + LIBERO 数据集
# 目标: 准备推理所需的模型和数据
# ============================================================

set -e

# 可选: 设置 HuggingFace 镜像 (中国大陆加速)
# export HF_ENDPOINT=https://hf-mirror.com

echo "=== 下载 pi0.5 预训练模型 ==="
# 方式1: 使用 huggingface-cli (推荐，支持断点续传)
huggingface-cli download lerobot/pi05_base --local-dir ./models/pi05_base

echo "=== 下载 LIBERO 评估模型 (可选) ==="
# huggingface-cli download lerobot/pi05_libero_finetuned --local-dir ./models/pi05_libero_finetuned

echo "=== 下载 LIBERO 数据集 ==="
# 用于推理评估 (LIBERO 仿真环境)
python -c "
from lerobot.datasets.lerobot_dataset import LeRobotDataset
# 只下载一个小 episode 用于验证
ds = LeRobotDataset('lerobot/aloha_sim_transfer_cube_human', episodes=[0])
print(f'Dataset loaded: {len(ds)} frames')
print(f'Features: {list(ds.meta.features.keys())[:10]}')
print('=== 数据集验证成功 ===')
"

echo ""
echo "=== 全部下载完成 ==="
echo "模型路径: ./models/pi05_base"
echo ""
echo "下一步: 运行 03_test_inference.py"
