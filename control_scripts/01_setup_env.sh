#!/bin/bash
# ============================================================
# Step 1: 环境安装 (在服务器上执行)
# 目标: 安装 Evo-RL + pi0.5 依赖
# 适用: lab (1x4090) 或 cluster (8x5090)
# ============================================================

set -e

echo "=== Step 1: 创建 conda 环境 ==="
conda create -y -n evo-rl python=3.10
conda activate evo-rl

echo "=== Step 2: 安装 Evo-RL ==="
cd Evo-RL
pip install -e ".[pi,dev,test]"

echo "=== Step 3: 验证安装 ==="
python -c "
import torch
print(f'PyTorch: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU: {torch.cuda.get_device_name(0)}')
    print(f'GPU count: {torch.cuda.device_count()}')
    print(f'CUDA version: {torch.version.cuda}')

import transformers
print(f'Transformers: {transformers.__version__}')

from lerobot.policies.pi05.configuration_pi05 import PI05Config
print(f'PI05Config loaded OK')
print('=== 环境安装成功 ===')
"
