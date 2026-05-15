# Phase 1: pi0.5 复现操作手册

## 目标

在服务器上加载 pi0.5 预训练权重，跑通推理验证，确认模型能正确工作。

## 服务器信息

| 服务器 | GPU | 用途 |
|--------|-----|------|
| `ssh cluster` | 8x RTX 5090 | 后续 SFT 训练 |
| `ssh lab` | 1x RTX 4090 | 推理验证、小规模实验 |

## 执行步骤

**建议先在 lab (4090) 上验证推理，再到 cluster 上训练。**

### Step 1: 环境安装

```bash
ssh lab  # 或 ssh cluster
git clone <this-repo>
cd Evo-RL
bash control_scripts/01_setup_env.sh
```

如果 `pip install -e ".[pi]"` 失败（自定义 transformers 分支问题），尝试：
```bash
pip install -e .
pip install "transformers @ git+https://github.com/huggingface/transformers.git@fix/lerobot_openpi"
pip install "scipy>=1.10.1,<1.15"
```

### Step 2: 下载模型和数据

```bash
conda activate evo-rl
bash control_scripts/02_download_model_and_data.sh
```

国内加速：
```bash
export HF_ENDPOINT=https://hf-mirror.com
```

### Step 3: 推理验证

```bash
cd Evo-RL
PYTHONPATH=src python ../control_scripts/03_test_inference.py --model_path lerobot/pi05_base

# 或使用本地模型
PYTHONPATH=src python ../control_scripts/03_test_inference.py --model_path ../models/pi05_base
```

预期输出：
- 模型加载成功 (~3B 参数)
- GPU 显存占用 ~6-8GB (float32) 或 ~3-4GB (bfloat16)
- 4090 (24GB) 和 5090 都足够

### Step 4: LIBERO 评估 (可选)

```bash
# 需要安装 libero 环境
pip install -e ".[libero]"
bash control_scripts/04_eval_libero.sh
```

注意：LIBERO 需要 MuJoCo 和 dm_control，服务器上可能需要额外配置。
如果 LIBERO 环境装不上，可以跳过这步，直接在 Step 3 确认模型能加载即可。

## 预期问题及解决

| 问题 | 原因 | 解决 |
|------|------|------|
| `transformers` 安装失败 | 自定义分支需要 git | 确保服务器有 git，或手动 clone 安装 |
| `siglip check` 报错 | Evo-RL 版本检查特定 transformers 补丁 | 确认用 `fix/lerobot_openpi` 分支 |
| CUDA OOM | float32 模型太大 | 使用 `--policy.dtype=bfloat16` |
| LIBERO 环境失败 | MuJoCo/渲染依赖 | 跳过 Step 4，推理验证在 Step 3 完成 |

## 完成标准

- [x] 环境安装成功，能 import PI05Config
- [x] pi0.5 模型加载成功，参数量 ~3B
- [x] GPU 显存占用合理
- [ ] (可选) LIBERO 评估跑通

## ACT baseline

当前 C corrective 数据的非 VLM baseline 使用 ACT：

```bash
# Mac 上启动 lab 训练
bash control_scripts/14_train_act_pick_letter.sh

# 查看训练状态
bash control_scripts/14_train_act_pick_letter.sh --status

# 训练完成后部署最新 ACT checkpoint
bash control_scripts/15_deploy_act_pick_letter.sh C
```

ACT 训练默认使用 `/home/ubuntu/data/guanlin8/cuhksz_pick_C_corrective_20260426`，输出到 `/home/ubuntu/outputs/train/act_cuhksz_pick_C_corrective_*`。
`--status` 会输出精确的 `current_step/total_steps`、`remaining_steps`、ETA 和下一 checkpoint step，不依赖 LeRobot 原始日志里的 `1K/2K` 压缩显示。

ACT 部署 wrapper 默认使用旧版较稳定的主体限幅，并单独放宽夹爪限幅：

```bash
bash control_scripts/15_deploy_act_pick_letter.sh C
```

关键默认值：`MAX_RELATIVE_TARGET=4`、`GRIPPER_MAX_RELATIVE_TARGET=100`、`ACTIONS_PER_CHUNK=10`、`LOG_ACTIONS=1`、`DIAGNOSTIC_LOGS=1`、`OBS_IMAGE_JPEG_QUALITY=85`、`ASYNC_OBSERVATION_SEND=1`、`OBSERVATION_SEND_QUEUE_SIZE=1`、`OBSERVATION_SEND_TIMEOUT_MS=800`、`REBASE_ACTION_TIMESTAMPS_ON_RECEIVE=1`、`MAX_ACTION_AGE_MS=500`。

当前两路相机实拍 JPEG q85 传输大小约 `0.106MB/obs`，10Hz 约 `1.06MB/s`，低于 `3MB/s` 目标。如需关闭图像传输压缩：

```bash
OBS_IMAGE_JPEG_QUALITY=0 bash control_scripts/15_deploy_act_pick_letter.sh C
```

如需记录每次 observation 的压缩统计：

```bash
LOG_OBSERVATION_TRANSPORT=1 bash control_scripts/15_deploy_act_pick_letter.sh C
```

实时监控部署诊断日志：

```bash
bash control_scripts/16_monitor_deploy_diagnostics.sh
```

如果当前没有本地 `robot_client`，监控脚本会提示正在查看旧 run 日志。先启动部署，再重新运行监控脚本，才能自动跟随新的 `outputs/deploy_logs/<run_id>/`。

只测试 front/wrist 摄像头稳定性，不连接机械臂电机或启动 policy：

```bash
bash control_scripts/17_so101_camera_soak_test.sh
```

可视化实际调用的 front/wrist 摄像头，窗口会标注 index 和设备名：

```bash
bash control_scripts/18_preview_so101_cameras.sh
```

直接可视化当前 `0/1/2/3` 号 OpenCV camera index 的画面；默认 2x2 网格，每个格子都会标注真实 `OPENCV ID` 和可选 `USER LABEL`。macOS 上名称顺序可能和 OpenCV index 顺序不一致，所以不再把 AVFoundation 名称贴到画面上；打不开的 index 会显示红色错误格：

```bash
bash control_scripts/19_preview_camera_indices.sh
```

确认画面后可以手动标注：

```bash
CAMERA_LABEL_0=front CAMERA_LABEL_1=wrist \
  bash control_scripts/19_preview_camera_indices.sh
```

该脚本会同时 tail 最近一次部署的 `robot_client.log` 和 `run_info.txt` 记录的 lab `policy_server` log，并只显示 `*_DIAG`、`CONTROL_LOOP_OVERRUN`、camera read/stale、warning/error 等关键行。

诊断日志默认覆盖：

- Mac observation capture：`OBS_CAPTURE_DIAG`，包括 front/wrist frame age、shape、capture time 和 action queue。
- Mac transport：`OBS_SEND_DIAG`，包括 JPEG encode、pickle serialize 和 gRPC upload time。
- Mac async transport：`OBS_ENQUEUE_DIAG` / `OBS_ASYNC_SEND_DIAG`，包括旧 observation 是否被替换、后台发送耗时、发送成功数和丢帧数。
- Lab transport/inference：`SERVER_OBS_DIAG`、`SERVER_PREDICT_DIAG`、`SERVER_ACTION_DIAG`，包括 receive/decode、preprocess、policy inference、postprocess、serialize 和 action payload size。
- Mac action execution：`ACTION_RECV_DIAG`、`ACTION_EXEC_DIAG`、`STALE_ACTION_DROP_DIAG`，包括 GetActions RPC、queue update、action age、过期 action 丢弃、serial send time、raw-to-sent smoothing/clamp delta 和 sent-to-performed error。

如需降低日志量：

```bash
DIAGNOSTIC_EVERY_N=5 LOG_ACTIONS=0 bash control_scripts/15_deploy_act_pick_letter.sh C
```

部署时默认启用 observation fail-safe：如果 camera/observation 连续失败 `OBSERVATION_ERROR_LIMIT=3` 次，client 会清空 action queue 并停机，避免 wrist camera 掉线后继续执行旧 action。OpenCV camera 读线程在连续 read failure 后会按 `CAMERA_MAX_CONSECUTIVE_READ_FAILURES=10` 尝试重新打开 `VideoCapture`；如需对比 camera 参数，可先运行 `control_scripts/17_so101_camera_soak_test.sh`，再用 `FRONT_CAMERA_*` / `WRIST_CAMERA_*` 覆盖部署脚本。

在 macOS 上，camera soak test、preview 和部署脚本都会先打印 AVFoundation 设备表。但本机已观察到 AVFoundation 名称顺序和 OpenCV index 顺序不一致，所以部署/soak 只把内置或虚拟摄像头名称作为 warning；实际映射必须以 `control_scripts/19_preview_camera_indices.sh` 的画面为准。如需严格按名称拒绝，可设置 `STRICT_CAMERA_NAME_GUARD=1`。

如果只是为了可视化当前 front/wrist 选择，可运行：

```bash
ALLOW_BUILTIN_CAMERA=1 DURATION_S=10 bash control_scripts/18_preview_so101_cameras.sh
```

`control_scripts/19_preview_camera_indices.sh` 是 raw index preview，不做 built-in camera 拦截；它用于确认当前 0/1/2/3 号到底是什么画面。部署使用 OpenCV index，所以以这个脚本看到的画面为准。

## Data collection camera timeout

当前 fixed C simple 数据采集命令：

```bash
bash control_scripts/09_record_data.sh guanlin8/cuhksz_pick_C_simple_20260429 "pick up the letter C" 50 12 4 false
```

`OpenCVCamera(1) latest frame is too old` 表示 wrist 摄像头缓存超过 stale-frame 阈值。`control_scripts/09_record_data.sh` 默认设置 `CAMERA_MAX_AGE_MS=2000`；如果仍偶发中断，可临时用：

```bash
CAMERA_MAX_AGE_MS=3000 \
  bash control_scripts/09_record_data.sh guanlin8/cuhksz_pick_C_simple_20260429 "pick up the letter C" 50 12 4 false
```

`SOFollower` 默认仍是 `1000ms`，只有设置 `LEROBOT_CAMERA_MAX_AGE_MS` 或通过录制脚本启动时才会放宽。

## Deployment stop behavior

```bash
bash control_scripts/12_deploy_pick_letter.sh --stop
```

`--stop` 会先停止本地 `lerobot.async_inference.robot_client`，再关闭 follower torque。夹爪 6 号如果在夹紧或保护状态下不回 ping，脚本会对 ID 6 发送不依赖状态包的 blind `Torque_Enable=0` / `Lock=0`，然后尽量读回验证。
