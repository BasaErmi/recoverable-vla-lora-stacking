#!/bin/bash
# ============================================================
# Policy Server (在 lab 服务器上运行)
# 加载 pi0.5 模型，等待 Mac robot client 连接
#
# 用法 (在 lab 上):
#   conda activate evo-rl
#   bash control_scripts/10_policy_server.sh
# ============================================================

set -e

HOST="0.0.0.0"
PORT=8080
FPS=30

# Deployment should not block on Hugging Face HEAD requests when the base
# model/tokenizer are already cached on lab.
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
export HF_DATASETS_OFFLINE="${HF_DATASETS_OFFLINE:-1}"

echo "=== pi0.5 Policy Server ==="
echo "监听: ${HOST}:${PORT}"
echo "FPS: ${FPS}"
echo "HF_HUB_OFFLINE: ${HF_HUB_OFFLINE}"
echo ""

cd ~/Evo-RL
PYTHONPATH=src python -m lerobot.async_inference.policy_server \
  --host=$HOST \
  --port=$PORT \
  --fps=$FPS
