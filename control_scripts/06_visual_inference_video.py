#!/usr/bin/env python
"""
pi0.5 推理可视化视频

对数据集每一帧跑推理，生成视频：左边是观测图像，右边是 action 对比柱状图。

用法:
    cd ~/Evo-RL
    PYTHONPATH=src python control_scripts/06_visual_inference_video.py
"""

import os
import time

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import torch
from matplotlib.backends.backend_agg import FigureCanvasAgg
from transformers import AutoTokenizer

from lerobot.datasets.lerobot_dataset import LeRobotDataset
from lerobot.policies.pi05.modeling_pi05 import PI05Policy, pad_vector


def fig_to_array(fig):
    canvas = FigureCanvasAgg(fig)
    canvas.draw()
    buf = canvas.buffer_rgba()
    arr = np.asarray(buf)[:, :, :3].copy()
    return arr


def main():
    output_dir = "outputs/visual_inference"
    os.makedirs(output_dir, exist_ok=True)
    device = "cuda" if torch.cuda.is_available() else "cpu"

    # ---- 加载 ----
    print("加载模型...")
    model = PI05Policy.from_pretrained("lerobot/pi05_base")
    model = model.to(device)
    model.eval()
    config = model.config
    print(f"  {sum(p.numel() for p in model.parameters())/1e9:.2f}B params")

    tokenizer = AutoTokenizer.from_pretrained("unsloth/gemma-2b")

    print("加载数据集...")
    ds = LeRobotDataset("lerobot/aloha_sim_transfer_cube_human", episodes=[0])
    n_frames = len(ds)
    task_text = ds[0]["task"]
    print(f"  {n_frames} frames, task: {task_text}")

    tokens = tokenizer(
        task_text,
        padding="max_length",
        max_length=config.tokenizer_max_length,
        truncation=True,
        return_tensors="pt",
    )

    # ---- 逐帧推理 ----
    all_pred = []
    all_gt = []

    print(f"逐帧推理 ({n_frames} frames)...")
    t_start = time.time()
    for idx in range(n_frames):
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

        all_pred.append(pred[0].cpu().numpy()[:14])
        all_gt.append(item["action"].numpy()[:14])

        if (idx + 1) % 50 == 0 or idx == 0:
            elapsed = time.time() - t_start
            fps = (idx + 1) / elapsed
            print(f"  {idx+1}/{n_frames}  ({fps:.1f} frames/s)")

    all_pred = np.array(all_pred)
    all_gt = np.array(all_gt)

    # 计算全局 y 轴范围
    y_min = min(all_pred.min(), all_gt.min()) - 0.1
    y_max = max(all_pred.max(), all_gt.max()) + 0.1

    # ---- 生成视频帧 ----
    print("生成视频帧...")
    import imageio

    video_path = os.path.join(output_dir, "pi05_inference.mp4")
    writer = imageio.get_writer(video_path, fps=10, codec="libx264", quality=8)

    for idx in range(n_frames):
        item = ds[idx]
        img_np = item["observation.images.top"].permute(1, 2, 0).numpy()
        if img_np.max() > 1.0:
            img_np = img_np / 255.0
        img_np = np.clip(img_np, 0, 1)

        fig, axes = plt.subplots(1, 3, figsize=(18, 5), gridspec_kw={"width_ratios": [1.2, 1.5, 1.5]})

        # 左: 图像
        axes[0].imshow(img_np)
        axes[0].set_title(f"Frame {idx}/{n_frames-1}", fontsize=13)
        axes[0].axis("off")

        # 中: action 柱状图对比
        gt = all_gt[idx]
        pred = all_pred[idx]
        x = np.arange(14)
        w = 0.35
        axes[1].bar(x - w / 2, gt, w, label="GT", color="steelblue", alpha=0.8)
        axes[1].bar(x + w / 2, pred, w, label="Pred", color="coral", alpha=0.8)
        axes[1].set_ylim(y_min, y_max)
        axes[1].set_xlabel("Action Dim")
        axes[1].set_ylabel("Value")
        axes[1].set_title("Action Comparison", fontsize=13)
        axes[1].legend(fontsize=9)
        axes[1].set_xticks(x)

        # 右: 历史轨迹 (到当前帧)
        history = min(idx + 1, n_frames)
        t = np.arange(history)
        dims = [0, 2, 6, 13]
        colors_gt = ["#1f77b4", "#2ca02c", "#9467bd", "#8c564b"]
        colors_pred = ["#ff7f0e", "#d62728", "#e377c2", "#bcbd22"]
        for i, d in enumerate(dims):
            axes[2].plot(t, all_gt[:history, d], color=colors_gt[i], linewidth=1.5, alpha=0.7)
            axes[2].plot(t, all_pred[:history, d], color=colors_pred[i], linewidth=1.5, linestyle="--", alpha=0.7)
        # 当前帧竖线
        axes[2].axvline(x=idx, color="red", linewidth=1, alpha=0.5)
        axes[2].set_xlim(0, n_frames)
        axes[2].set_ylim(y_min, y_max)
        axes[2].set_xlabel("Frame")
        axes[2].set_title("Trajectory (dim 0,2,6,13)", fontsize=13)
        axes[2].set_ylabel("Value")

        # 添加图例
        from matplotlib.lines import Line2D
        legend_elements = [
            Line2D([0], [0], color="gray", linewidth=1.5, label="GT (solid)"),
            Line2D([0], [0], color="gray", linewidth=1.5, linestyle="--", label="Pred (dashed)"),
        ]
        axes[2].legend(handles=legend_elements, fontsize=8, loc="upper right")

        fig.suptitle(f"pi0.5 Inference | Task: {task_text}", fontsize=12)
        plt.tight_layout()

        frame_arr = fig_to_array(fig)
        writer.append_data(frame_arr)
        plt.close(fig)

        if (idx + 1) % 50 == 0:
            print(f"  视频帧 {idx+1}/{n_frames}")

    writer.close()
    print(f"\n视频保存: {video_path}")

    # ---- 统计 ----
    mse = np.mean((all_pred - all_gt) ** 2)
    mae = np.mean(np.abs(all_pred - all_gt))
    print(f"MSE: {mse:.6f}, MAE: {mae:.6f}")
    print("完成!")


if __name__ == "__main__":
    main()
