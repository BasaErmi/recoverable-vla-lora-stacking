#!/usr/bin/env python
"""
pi0.5 可视化推理验证

用真实数据集的图像和 state 输入模型，对比模型预测的 action 和数据集的 ground truth action。
生成可视化图片保存到 outputs/visual_inference/

用法:
    cd ~/Evo-RL
    PYTHONPATH=src python control_scripts/05_visual_inference.py
"""

import os
import time

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import torch
from transformers import AutoTokenizer

from lerobot.datasets.lerobot_dataset import LeRobotDataset
from lerobot.policies.pi05.modeling_pi05 import PI05Policy, pad_vector


def main():
    output_dir = "outputs/visual_inference"
    os.makedirs(output_dir, exist_ok=True)

    device = "cuda" if torch.cuda.is_available() else "cpu"

    # ---- 加载模型 ----
    print("加载模型...")
    model = PI05Policy.from_pretrained("lerobot/pi05_base")
    model = model.to(device)
    model.eval()
    config = model.config
    print(f"  模型: {sum(p.numel() for p in model.parameters())/1e9:.2f}B params, device={device}")

    # ---- 加载 tokenizer ----
    tokenizer = AutoTokenizer.from_pretrained("unsloth/gemma-2b")

    # ---- 加载数据集 ----
    print("加载数据集...")
    ds = LeRobotDataset("lerobot/aloha_sim_transfer_cube_human", episodes=[0])
    print(f"  数据集: {len(ds)} frames, task: {ds[0]['task']}")

    # ---- 选取若干帧进行推理 ----
    frame_indices = [0, 50, 100, 150, 200, 300]
    frame_indices = [i for i in frame_indices if i < len(ds)]

    all_pred_actions = []
    all_gt_actions = []
    all_images = []
    all_frame_ids = []

    task_text = ds[0]["task"]
    tokens = tokenizer(
        task_text,
        padding="max_length",
        max_length=config.tokenizer_max_length,
        truncation=True,
        return_tensors="pt",
    )

    print(f"对 {len(frame_indices)} 帧进行推理...")
    for idx in frame_indices:
        item = ds[idx]

        # 准备图像 (dataset: [3, H, W] -> model: [1, 3, 224, 224])
        img = item["observation.images.top"]  # [3, 480, 640]
        img_resized = torch.nn.functional.interpolate(
            img.unsqueeze(0), size=(224, 224), mode="bilinear", align_corners=False
        )

        # 准备 state
        state = pad_vector(item["observation.state"].unsqueeze(0), config.max_state_dim)

        batch = {
            "observation.images.base_0_rgb": img_resized.to(device),
            "observation.state": state.to(device),
            "observation.language.tokens": tokens["input_ids"].to(device),
            "observation.language.attention_mask": tokens["attention_mask"].to(device),
        }

        t0 = time.time()
        with torch.no_grad():
            pred_action = model.select_action(batch)  # [1, action_dim]
        dt = time.time() - t0

        gt_action = item["action"]  # [14]

        all_pred_actions.append(pred_action[0].cpu().numpy())
        all_gt_actions.append(gt_action.numpy())
        all_images.append(img.permute(1, 2, 0).numpy())  # [H, W, 3]
        all_frame_ids.append(idx)

        print(f"  frame {idx:>3d}: inference {dt:.2f}s")

    # ---- 可视化 1: 每帧图像 + action 对比 ----
    n = len(frame_indices)
    fig, axes = plt.subplots(n, 2, figsize=(16, 4 * n))
    if n == 1:
        axes = axes.reshape(1, -1)

    for i in range(n):
        # 左边: 图像
        ax_img = axes[i, 0]
        img_show = np.clip(all_images[i], 0, 1) if all_images[i].max() <= 1.0 else np.clip(all_images[i] / 255, 0, 1)
        ax_img.imshow(img_show)
        ax_img.set_title(f"Frame {all_frame_ids[i]}", fontsize=12)
        ax_img.axis("off")

        # 右边: action 对比 (只画前14维，即实际 action 维度)
        ax_act = axes[i, 1]
        gt = all_gt_actions[i][:14]
        pred = all_pred_actions[i][:14]
        x = np.arange(len(gt))
        width = 0.35
        ax_act.bar(x - width / 2, gt, width, label="Ground Truth", alpha=0.7, color="steelblue")
        ax_act.bar(x + width / 2, pred, width, label="Predicted", alpha=0.7, color="coral")
        ax_act.set_xlabel("Action Dimension")
        ax_act.set_ylabel("Value")
        ax_act.set_title(f"Frame {all_frame_ids[i]}: Action Comparison")
        ax_act.legend(fontsize=9)
        ax_act.set_xticks(x)

    plt.suptitle(f"pi0.5 Inference Visualization\nTask: {task_text}", fontsize=14, y=1.01)
    plt.tight_layout()
    path1 = os.path.join(output_dir, "per_frame_comparison.png")
    plt.savefig(path1, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"\n保存: {path1}")

    # ---- 可视化 2: 连续帧的 action 轨迹 ----
    # 对连续帧做推理，画出 action 随时间的变化
    print("\n对前 50 帧连续推理...")
    continuous_frames = min(50, len(ds))
    cont_pred = []
    cont_gt = []

    for idx in range(continuous_frames):
        item = ds[idx]
        img = item["observation.images.top"]
        img_resized = torch.nn.functional.interpolate(
            img.unsqueeze(0), size=(224, 224), mode="bilinear", align_corners=False
        )
        state = pad_vector(item["observation.state"].unsqueeze(0), config.max_state_dim)

        batch = {
            "observation.images.base_0_rgb": img_resized.to(device),
            "observation.state": state.to(device),
            "observation.language.tokens": tokens["input_ids"].to(device),
            "observation.language.attention_mask": tokens["attention_mask"].to(device),
        }

        with torch.no_grad():
            pred = model.select_action(batch)

        cont_pred.append(pred[0].cpu().numpy()[:14])
        cont_gt.append(item["action"].numpy()[:14])

        if (idx + 1) % 10 == 0:
            print(f"  {idx+1}/{continuous_frames}")

    cont_pred = np.array(cont_pred)  # [T, 14]
    cont_gt = np.array(cont_gt)  # [T, 14]

    # 画 4 个关键维度的轨迹对比
    dims_to_plot = [0, 1, 2, 6]  # 选几个有代表性的维度
    dim_names = [f"dim_{d}" for d in dims_to_plot]

    fig, axes = plt.subplots(len(dims_to_plot), 1, figsize=(14, 3 * len(dims_to_plot)), sharex=True)
    t = np.arange(continuous_frames)

    for i, d in enumerate(dims_to_plot):
        axes[i].plot(t, cont_gt[:, d], label="Ground Truth", color="steelblue", linewidth=2)
        axes[i].plot(t, cont_pred[:, d], label="Predicted", color="coral", linewidth=2, linestyle="--")
        axes[i].set_ylabel(f"Action[{d}]")
        axes[i].legend(loc="upper right", fontsize=9)
        axes[i].grid(True, alpha=0.3)

    axes[-1].set_xlabel("Frame")
    plt.suptitle(f"pi0.5 Action Trajectory (first {continuous_frames} frames)\nTask: {task_text}", fontsize=13)
    plt.tight_layout()
    path2 = os.path.join(output_dir, "action_trajectory.png")
    plt.savefig(path2, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"保存: {path2}")

    # ---- 统计 ----
    mse = np.mean((cont_pred - cont_gt) ** 2)
    mae = np.mean(np.abs(cont_pred - cont_gt))
    print(f"\n=== 统计 ===")
    print(f"MSE (pred vs gt): {mse:.6f}")
    print(f"MAE (pred vs gt): {mae:.6f}")
    print(f"注意: base 模型未在此数据集微调，误差大是正常的")
    print(f"\n图片保存在: {output_dir}/")
    print("完成!")


if __name__ == "__main__":
    main()
