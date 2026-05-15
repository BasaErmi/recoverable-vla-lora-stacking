#!/usr/bin/env python
"""
双摄像头实时预览 + 参数调节工具

用法:
    conda activate evo-rl
    python scripts/camera_preview.py

快捷键:
    q          — 退出
    s          — 截图保存到 /tmp/
    Tab        — 切换当前调节的摄像头 (front/wrist)
    w/e        — 亮度 -/+
    r/t        — 对比度 -/+
    a/d        — 曝光 -/+
    z/x        — 增益 -/+
    f          — 切换自动对焦 (如果支持)
    g          — 切换自动曝光
    1          — 只看 front
    2          — 只看 wrist
    0          — 两个都看
"""

import time

import cv2
import numpy as np

FRONT_IDX = 0
WRIST_IDX = 1

PROPS = {
    "brightness": cv2.CAP_PROP_BRIGHTNESS,
    "contrast": cv2.CAP_PROP_CONTRAST,
    "exposure": cv2.CAP_PROP_EXPOSURE,
    "gain": cv2.CAP_PROP_GAIN,
    "autofocus": cv2.CAP_PROP_AUTOFOCUS,
    "auto_exposure": cv2.CAP_PROP_AUTO_EXPOSURE,
    "focus": cv2.CAP_PROP_FOCUS,
    "saturation": cv2.CAP_PROP_SATURATION,
    "sharpness": cv2.CAP_PROP_SHARPNESS,
    "fps": cv2.CAP_PROP_FPS,
    "width": cv2.CAP_PROP_FRAME_WIDTH,
    "height": cv2.CAP_PROP_FRAME_HEIGHT,
}


def get_all_props(cap):
    result = {}
    for name, prop_id in PROPS.items():
        val = cap.get(prop_id)
        if val != 0.0 or name in ("brightness", "exposure", "focus"):
            result[name] = val
    return result


def draw_info(frame, props, cam_name, is_active, fps):
    h, w = frame.shape[:2]
    overlay = frame.copy()

    # 半透明背景
    cv2.rectangle(overlay, (0, 0), (280, 30 + 18 * (len(props) + 2)), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.6, frame, 0.4, 0, frame)

    color = (0, 255, 0) if is_active else (180, 180, 180)
    marker = " [ACTIVE]" if is_active else ""
    cv2.putText(frame, f"{cam_name}{marker}", (5, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2)

    y = 38
    cv2.putText(frame, f"FPS: {fps:.1f}", (5, y), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 0), 1)
    y += 18

    for name, val in props.items():
        cv2.putText(frame, f"{name}: {val:.1f}", (5, y), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (200, 200, 200), 1)
        y += 18

    return frame


def draw_help(frame):
    h, w = frame.shape[:2]
    lines = [
        "Tab: switch cam  |  s: screenshot  |  q: quit",
        "w/e: brightness  |  r/t: contrast",
        "a/d: exposure    |  z/x: gain",
        "f: autofocus     |  g: auto_exposure",
        "0: both  |  1: front  |  2: wrist",
    ]
    for i, line in enumerate(lines):
        cv2.putText(frame, line, (5, h - 12 - (len(lines) - 1 - i) * 18),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.38, (150, 150, 150), 1)
    return frame


def main():
    caps = {}

    # 打开摄像头
    for name, idx in [("front", FRONT_IDX), ("wrist", WRIST_IDX)]:
        cap = cv2.VideoCapture(idx)
        if cap.isOpened():
            # 跳过初始化帧
            for _ in range(5):
                cap.read()
            caps[name] = cap
            w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            print(f"{name} (index {idx}): {w}x{h}")
        else:
            print(f"{name} (index {idx}): 无法打开!")

    if not caps:
        print("没有可用的摄像头")
        return

    active_cam = "wrist"  # 默认先调节腕部
    show_mode = 0  # 0=both, 1=front, 2=wrist
    frame_count = 0
    t0 = time.time()
    fps = 0.0

    print("\n实时预览已启动，按 q 退出")
    print(        "Tab: switch cam  |  s: screenshot  |  q: quit",
        "w/e: brightness  |  r/t: contrast",
        "a/d: exposure    |  z/x: gain",
        "f: autofocus     |  g: auto_exposure",
        "0: both  |  1: front  |  2: wrist",)
    print(f"当前调节: {active_cam}")

    while True:
        frames = {}
        for name, cap in caps.items():
            ret, frame = cap.read()
            if ret:
                frames[name] = frame

        if not frames:
            break

        frame_count += 1
        elapsed = time.time() - t0
        if elapsed > 0.5:
            fps = frame_count / elapsed
            frame_count = 0
            t0 = time.time()

        # 绘制信息
        display = {}
        for name in frames:
            props = get_all_props(caps[name])
            is_active = (name == active_cam)
            display[name] = draw_info(frames[name].copy(), props, name, is_active, fps)

        # 拼接显示
        show_frames = []
        target_h = 480

        if show_mode == 0 or show_mode == 1:
            if "front" in display:
                f = display["front"]
                h, w = f.shape[:2]
                scale = target_h / h
                show_frames.append(cv2.resize(f, (int(w * scale), target_h)))

        if show_mode == 0 or show_mode == 2:
            if "wrist" in display:
                f = display["wrist"]
                h, w = f.shape[:2]
                scale = target_h / h
                show_frames.append(cv2.resize(f, (int(w * scale), target_h)))

        if show_frames:
            combined = cv2.hconcat(show_frames)
            combined = draw_help(combined)
            cv2.imshow("Camera Tuning (q=quit)", combined)

        key = cv2.waitKey(1) & 0xFF

        if key == ord("q"):
            break

        elif key == 9:  # Tab
            names = list(caps.keys())
            idx = names.index(active_cam)
            active_cam = names[(idx + 1) % len(names)]
            print(f"切换到: {active_cam}")

        elif key == ord("s"):
            ts = int(time.time())
            for name, f in frames.items():
                path = f"/tmp/{name}_{ts}.jpg"
                cv2.imwrite(path, f)
                print(f"保存: {path}")

        elif key == ord("0"):
            show_mode = 0
        elif key == ord("1"):
            show_mode = 1
        elif key == ord("2"):
            show_mode = 2

        # 参数调节
        elif active_cam in caps:
            cap = caps[active_cam]
            step = 5.0

            if key == ord("w"):
                cap.set(cv2.CAP_PROP_BRIGHTNESS, cap.get(cv2.CAP_PROP_BRIGHTNESS) - step)
            elif key == ord("e"):
                cap.set(cv2.CAP_PROP_BRIGHTNESS, cap.get(cv2.CAP_PROP_BRIGHTNESS) + step)
            elif key == ord("r"):
                cap.set(cv2.CAP_PROP_CONTRAST, cap.get(cv2.CAP_PROP_CONTRAST) - step)
            elif key == ord("t"):
                cap.set(cv2.CAP_PROP_CONTRAST, cap.get(cv2.CAP_PROP_CONTRAST) + step)
            elif key == ord("a"):
                cap.set(cv2.CAP_PROP_EXPOSURE, cap.get(cv2.CAP_PROP_EXPOSURE) - 1)
            elif key == ord("d"):
                cap.set(cv2.CAP_PROP_EXPOSURE, cap.get(cv2.CAP_PROP_EXPOSURE) + 1)
            elif key == ord("z"):
                cap.set(cv2.CAP_PROP_GAIN, cap.get(cv2.CAP_PROP_GAIN) - step)
            elif key == ord("x"):
                cap.set(cv2.CAP_PROP_GAIN, cap.get(cv2.CAP_PROP_GAIN) + step)
            elif key == ord("f"):
                cur = cap.get(cv2.CAP_PROP_AUTOFOCUS)
                cap.set(cv2.CAP_PROP_AUTOFOCUS, 0 if cur else 1)
                print(f"autofocus: {0 if cur else 1}")
            elif key == ord("g"):
                cur = cap.get(cv2.CAP_PROP_AUTO_EXPOSURE)
                new_val = 1.0 if cur == 3.0 else 3.0
                cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, new_val)
                print(f"auto_exposure: {new_val} (3=auto, 1=manual)")

    for cap in caps.values():
        cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
