#!/usr/bin/env python
"""Run a SO101 follower against an official OpenPI websocket policy server."""

from __future__ import annotations

import argparse
import concurrent.futures
import logging
import math
import os
import signal
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
from openpi_client import websocket_client_policy

from lerobot.cameras.opencv.configuration_opencv import OpenCVCameraConfig
from lerobot.robots import make_robot_from_config
from lerobot.robots.so_follower.config_so_follower import SOFollowerRobotConfig
from lerobot.utils.visualization_utils import init_rerun, log_rerun_data


MOTOR_ACTION_KEYS = [
    "shoulder_pan.pos",
    "shoulder_lift.pos",
    "elbow_flex.pos",
    "wrist_flex.pos",
    "wrist_roll.pos",
    "gripper.pos",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--task", required=True)
    parser.add_argument("--follower-port", required=True)
    parser.add_argument("--follower-id", default="my_follower")
    parser.add_argument("--fps", type=float, default=30.0)
    parser.add_argument("--open-loop-horizon", type=int, default=12)
    parser.add_argument(
        "--chunk-start-index",
        type=int,
        default=0,
        help="Start executing each OpenPI action chunk from this index.",
    )
    parser.add_argument(
        "--chunk-ramp-steps",
        type=int,
        default=8,
        help="Blend this many incoming actions from the previous target to avoid a hard jump.",
    )
    parser.add_argument(
        "--auto-skip-delay-actions",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Skip action indices that are already stale by the time async inference returns.",
    )
    parser.add_argument("--max-delay-skip-steps", type=int, default=6)
    parser.add_argument("--refill-threshold", type=int, default=7)
    parser.add_argument("--commit-horizon", type=int, default=4)
    parser.add_argument("--max-steps", type=int, default=0, help="0 means run until Ctrl-C")
    parser.add_argument("--max-relative-target", type=float, default=5.0)
    parser.add_argument("--gripper-max-relative-target", type=float, default=100.0)
    parser.add_argument("--action-ema-alpha", type=float, default=0.5)
    parser.add_argument("--action-max-delta", type=float, default=2.0)
    parser.add_argument("--gripper-action-max-delta", type=float, default=4.0)
    parser.add_argument("--log-actions", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--diagnostic-every-n", type=int, default=1)
    parser.add_argument("--camera-max-age-ms", type=int, default=2000)
    parser.add_argument("--front-index", default="0")
    parser.add_argument("--front-width", type=int, default=640)
    parser.add_argument("--front-height", type=int, default=480)
    parser.add_argument("--front-fps", type=int, default=30)
    parser.add_argument("--front-fourcc", default=None)
    parser.add_argument("--front-warmup-s", type=int, default=1)
    parser.add_argument("--wrist-index", default="2")
    parser.add_argument("--wrist-width", type=int, default=1280)
    parser.add_argument("--wrist-height", type=int, default=720)
    parser.add_argument("--wrist-fps", type=int, default=30)
    parser.add_argument("--wrist-fourcc", default="MJPG")
    parser.add_argument("--wrist-warmup-s", type=int, default=3)
    parser.add_argument("--display-data", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--display-compressed-images", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument(
        "--display-every-n",
        type=int,
        default=1,
        help="Log one Rerun frame every N control-loop steps when --display-data is enabled.",
    )
    parser.add_argument("--display-ip", default=None)
    parser.add_argument("--display-port", type=int, default=None)
    args = parser.parse_args()
    args.front_fourcc = args.front_fourcc or None
    args.wrist_fourcc = args.wrist_fourcc or None
    return args


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(asctime)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        force=True,
    )


def make_robot(args: argparse.Namespace):
    os.environ["LEROBOT_CAMERA_MAX_AGE_MS"] = str(args.camera_max_age_ms)
    os.environ["LEROBOT_GRIPPER_MAX_RELATIVE_TARGET"] = str(args.gripper_max_relative_target)

    def camera_index_or_path(value: str) -> int | Path:
        return int(value) if value.isdigit() else Path(value)

    cameras = {
        "front": OpenCVCameraConfig(
            index_or_path=camera_index_or_path(args.front_index),
            width=args.front_width,
            height=args.front_height,
            fps=args.front_fps,
            warmup_s=args.front_warmup_s,
            fourcc=args.front_fourcc,
        ),
        "wrist": OpenCVCameraConfig(
            index_or_path=camera_index_or_path(args.wrist_index),
            width=args.wrist_width,
            height=args.wrist_height,
            fps=args.wrist_fps,
            warmup_s=args.wrist_warmup_s,
            fourcc=args.wrist_fourcc,
        ),
    }
    cfg = SOFollowerRobotConfig(
        id=args.follower_id,
        port=args.follower_port,
        cameras=cameras,
        max_relative_target=args.max_relative_target,
        disable_torque_on_disconnect=True,
        use_degrees=False,
    )
    return make_robot_from_config(cfg)


def action_array_from_mapping(values: dict[str, Any]) -> np.ndarray:
    return np.asarray([float(values[key]) for key in MOTOR_ACTION_KEYS], dtype=np.float32)


def state_from_observation(obs: dict[str, Any]) -> np.ndarray:
    return action_array_from_mapping(obs)


def make_policy_request(obs: dict[str, Any], task: str) -> dict[str, Any]:
    return {
        "observation/state": state_from_observation(obs),
        "observation/image": np.asarray(obs["front"]),
        "observation/wrist_image": np.asarray(obs["wrist"]),
        "prompt": task,
    }


def make_rerun_observation(obs: dict[str, Any]) -> dict[str, Any]:
    return {
        "observation.images.front": np.asarray(obs["front"]),
        "observation.images.wrist": np.asarray(obs["wrist"]),
        "observation.state": state_from_observation(obs),
    }


class ActionFilter:
    def __init__(self, args: argparse.Namespace):
        self.alpha = float(args.action_ema_alpha)
        self.body_delta = float(args.action_max_delta)
        self.gripper_delta = float(args.gripper_action_max_delta)
        self.previous: np.ndarray | None = None

    def __call__(self, raw: np.ndarray) -> np.ndarray:
        raw = np.asarray(raw[: len(MOTOR_ACTION_KEYS)], dtype=np.float32)
        if self.previous is None:
            self.previous = raw.copy()
            return raw

        action = raw
        if self.alpha > 0:
            action = self.alpha * self.previous + (1.0 - self.alpha) * action

        limits = np.full_like(action, self.body_delta if self.body_delta > 0 else np.inf)
        if self.gripper_delta > 0:
            limits[-1] = self.gripper_delta
        delta = np.clip(action - self.previous, -limits, limits)
        action = self.previous + delta
        self.previous = action.copy()
        return action

    def sync_to_performed(self, performed: dict[str, float]) -> None:
        self.previous = action_array_from_mapping(performed)


def action_to_robot_dict(action: np.ndarray) -> dict[str, float]:
    return {key: float(action[index]) for index, key in enumerate(MOTOR_ACTION_KEYS)}


def short_action(action: np.ndarray) -> list[float]:
    return [round(float(x), 3) for x in action[: len(MOTOR_ACTION_KEYS)]]


def select_actions(actions: np.ndarray, chunk_start_index: int, open_loop_horizon: int) -> np.ndarray:
    start = min(max(0, chunk_start_index), max(0, len(actions) - 1))
    end = min(len(actions), start + open_loop_horizon)
    return actions[start:end].copy()


def ramp_action_prefix(actions: np.ndarray, anchor: np.ndarray | None, ramp_steps: int) -> np.ndarray:
    if anchor is None or ramp_steps <= 0 or len(actions) == 0:
        return actions

    ramped = actions.copy()
    anchor = np.asarray(anchor[: len(MOTOR_ACTION_KEYS)], dtype=np.float32)
    count = min(ramp_steps, len(ramped))
    for index in range(count):
        weight = float(index + 1) / float(count + 1)
        ramped[index, : len(MOTOR_ACTION_KEYS)] = (1.0 - weight) * anchor + weight * ramped[index, : len(MOTOR_ACTION_KEYS)]
    return ramped


def prepare_incoming_actions(
    actions: np.ndarray,
    chunk_start_index: int,
    open_loop_horizon: int,
    anchor: np.ndarray | None,
    ramp_steps: int,
) -> np.ndarray:
    selected = select_actions(actions, chunk_start_index, open_loop_horizon)
    return ramp_action_prefix(selected, anchor, ramp_steps)


def effective_chunk_start(args: argparse.Namespace, step: int, request_step: int | None) -> tuple[int, int]:
    delay_steps = 0
    if args.auto_skip_delay_actions and request_step is not None:
        delay_steps = min(max(0, step - request_step), args.max_delay_skip_steps)
    return args.chunk_start_index + delay_steps, delay_steps


def chunk_summary(actions: np.ndarray, chunk_start_index: int, open_loop_horizon: int) -> dict[str, Any]:
    start = min(max(0, chunk_start_index), max(0, len(actions) - 1))
    end = min(len(actions), start + open_loop_horizon)
    selected = select_actions(actions, chunk_start_index, open_loop_horizon)[:, : len(MOTOR_ACTION_KEYS)]
    prefix = actions[: min(open_loop_horizon, len(actions)), : len(MOTOR_ACTION_KEYS)]
    full = actions[:, : len(MOTOR_ACTION_KEYS)]
    if len(selected) == 0:
        return {"empty": True}
    return {
        "selected_range": [int(start), int(end - 1)],
        "selected_first": short_action(selected[0]),
        "selected_last": short_action(selected[-1]),
        "prefix_first": short_action(prefix[0]) if len(prefix) else None,
        "prefix_last": short_action(prefix[-1]) if len(prefix) else None,
        "last_full": short_action(full[-1]),
        "selected_span": [round(float(x), 3) for x in np.max(selected, axis=0) - np.min(selected, axis=0)],
        "prefix_span": [round(float(x), 3) for x in np.max(prefix, axis=0) - np.min(prefix, axis=0)] if len(prefix) else None,
        "full_span": [round(float(x), 3) for x in np.max(full, axis=0) - np.min(full, axis=0)],
    }


def infer_chunk(policy: websocket_client_policy.WebsocketClientPolicy, request: dict[str, Any]) -> dict[str, Any]:
    start = time.perf_counter()
    result = policy.infer(request)
    result["_client_infer_ms"] = (time.perf_counter() - start) * 1000
    return result


def validate_args(args: argparse.Namespace) -> None:
    if args.fps <= 0:
        raise ValueError("--fps must be positive")
    if args.open_loop_horizon <= 0:
        raise ValueError("--open-loop-horizon must be positive")
    if args.chunk_start_index < 0:
        raise ValueError("--chunk-start-index must be non-negative")
    if args.chunk_ramp_steps < 0:
        raise ValueError("--chunk-ramp-steps must be non-negative")
    if args.max_delay_skip_steps < 0:
        raise ValueError("--max-delay-skip-steps must be non-negative")
    if args.refill_threshold < 0:
        raise ValueError("--refill-threshold must be non-negative")
    if args.commit_horizon < 0:
        raise ValueError("--commit-horizon must be non-negative")
    if not 0 <= args.action_ema_alpha < 1:
        raise ValueError("--action-ema-alpha must be in [0, 1)")
    if args.display_every_n <= 0:
        raise ValueError("--display-every-n must be positive")


def main() -> int:
    configure_logging()
    args = parse_args()
    validate_args(args)

    stop = False

    def handle_signal(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    logging.info("Connecting to OpenPI websocket policy at %s:%s", args.host, args.port)
    policy = websocket_client_policy.WebsocketClientPolicy(args.host, args.port)
    logging.info("OpenPI server metadata: %s", policy.get_server_metadata())

    display_active = False
    if args.display_data:
        logging.info(
            "Starting Rerun display every %s control steps compressed_images=%s",
            args.display_every_n,
            args.display_compressed_images,
        )
        try:
            init_rerun(session_name="openpi_so101_inference", ip=args.display_ip, port=args.display_port)
            display_active = True
        except Exception:
            logging.exception("RERUN_DISPLAY_STARTUP_ERROR; continuing with display disabled")

    robot = make_robot(args)
    robot.connect()
    logging.info("SO101 follower connected with front=cv%s wrist=cv%s", args.front_index, args.wrist_index)

    action_filter = ActionFilter(args)
    action_queue: list[np.ndarray] = []
    pending: concurrent.futures.Future | None = None
    last_request_step: int | None = None
    latest_state: np.ndarray | None = None
    dt = 1.0 / args.fps
    step = 0

    logging.info(
        "Rollout params: fps=%.1f chunk_start_index=%s auto_skip_delay_actions=%s max_delay_skip_steps=%s "
        "chunk_ramp_steps=%s open_loop_horizon=%s refill_threshold=%s commit_horizon=%s "
        "ema=%.2f action_max_delta=%.2f gripper_action_max_delta=%.2f max_relative_target=%.2f",
        args.fps,
        args.chunk_start_index,
        args.auto_skip_delay_actions,
        args.max_delay_skip_steps,
        args.chunk_ramp_steps,
        args.open_loop_horizon,
        args.refill_threshold,
        args.commit_horizon,
        args.action_ema_alpha,
        args.action_max_delta,
        args.gripper_action_max_delta,
        args.max_relative_target,
    )
    logging.info("Task prompt: %s", args.task)

    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        try:
            while not stop and (args.max_steps <= 0 or step < args.max_steps):
                loop_start = time.perf_counter()
                obs: dict[str, Any] | None = None
                obs_ms: float | None = None
                sent_action: np.ndarray | None = None

                if pending is not None and pending.done():
                    result = pending.result()
                    pending = None
                    actions = np.asarray(result["actions"], dtype=np.float32)
                    if actions.ndim != 2 or actions.shape[1] < len(MOTOR_ACTION_KEYS):
                        raise RuntimeError(f"Unexpected OpenPI action shape: {actions.shape}")
                    preserved = action_queue[: args.commit_horizon]
                    anchor = preserved[-1] if preserved else action_filter.previous if action_filter.previous is not None else latest_state
                    start_index, skipped_delay_steps = effective_chunk_start(args, step, last_request_step)
                    incoming_actions = prepare_incoming_actions(
                        actions,
                        start_index,
                        args.open_loop_horizon,
                        anchor,
                        args.chunk_ramp_steps,
                    )
                    incoming = [a.copy() for a in incoming_actions]
                    action_queue = preserved + incoming
                    timing = {**result.get("server_timing", {}), **result.get("policy_timing", {})}
                    logging.info(
                        "CHUNK_RECV step=%s request_step=%s shape=%s queue=%s preserved=%s skipped_delay_steps=%s "
                        "effective_start=%s client_infer_ms=%.1f timing=%s summary=%s",
                        step,
                        last_request_step,
                        tuple(actions.shape),
                        len(action_queue),
                        len(preserved),
                        skipped_delay_steps,
                        start_index,
                        result.get("_client_infer_ms", math.nan),
                        {k: round(float(v), 1) for k, v in timing.items()},
                        chunk_summary(actions, start_index, args.open_loop_horizon),
                    )

                need_policy_request = pending is None and len(action_queue) <= args.refill_threshold
                need_display_frame = display_active and step % args.display_every_n == 0

                if need_policy_request or need_display_frame:
                    obs_start = time.perf_counter()
                    obs = robot.get_observation()
                    obs_ms = (time.perf_counter() - obs_start) * 1000

                if need_policy_request:
                    assert obs is not None
                    request = make_policy_request(obs, args.task)
                    latest_state = request["observation/state"]
                    pending = executor.submit(infer_chunk, policy, request)
                    last_request_step = step
                    if step % args.diagnostic_every_n == 0:
                        logging.info(
                            "CHUNK_REQUEST step=%s queue=%s obs_ms=%.1f state=%s front=%s wrist=%s",
                            step,
                            len(action_queue),
                            obs_ms,
                            short_action(request["observation/state"]),
                            tuple(request["observation/image"].shape),
                            tuple(request["observation/wrist_image"].shape),
                        )

                if not action_queue and pending is not None:
                    result = pending.result()
                    pending = None
                    actions = np.asarray(result["actions"], dtype=np.float32)
                    start_index, skipped_delay_steps = effective_chunk_start(args, step, last_request_step)
                    incoming_actions = prepare_incoming_actions(
                        actions,
                        start_index,
                        args.open_loop_horizon,
                        action_filter.previous if action_filter.previous is not None else latest_state,
                        args.chunk_ramp_steps,
                    )
                    action_queue = [a.copy() for a in incoming_actions]
                    logging.info(
                        "CHUNK_RECV_BLOCKING step=%s shape=%s queue=%s skipped_delay_steps=%s effective_start=%s "
                        "client_infer_ms=%.1f summary=%s",
                        step,
                        tuple(actions.shape),
                        len(action_queue),
                        skipped_delay_steps,
                        start_index,
                        result.get("_client_infer_ms", math.nan),
                        chunk_summary(actions, start_index, args.open_loop_horizon),
                    )

                if action_queue:
                    raw_action = action_queue.pop(0)
                    sent_action = action_filter(raw_action)
                    send_start = time.perf_counter()
                    performed = robot.send_action(action_to_robot_dict(sent_action))
                    action_filter.sync_to_performed(performed)
                    send_ms = (time.perf_counter() - send_start) * 1000
                    if args.log_actions or step % args.diagnostic_every_n == 0:
                        logging.info(
                            "ACTION step=%s queue_after=%s raw=%s sent=%s performed=%s send_ms=%.1f",
                            step,
                            len(action_queue),
                            short_action(raw_action),
                            short_action(sent_action),
                            {k: round(float(v), 3) for k, v in performed.items()},
                            send_ms,
                        )
                elif step % args.diagnostic_every_n == 0:
                    logging.info("NO_ACTION step=%s waiting_for_policy=%s", step, pending is not None)

                if need_display_frame and obs is not None:
                    try:
                        log_rerun_data(
                            observation=make_rerun_observation(obs),
                            action=action_to_robot_dict(sent_action) if sent_action is not None else None,
                            compress_images=args.display_compressed_images,
                        )
                    except Exception:
                        logging.exception("RERUN_DISPLAY_ERROR step=%s; disabling display for this run", step)
                        display_active = False

                elapsed = time.perf_counter() - loop_start
                if elapsed > dt and step % args.diagnostic_every_n == 0:
                    logging.info("LOOP_OVERRUN step=%s elapsed_ms=%.1f target_ms=%.1f", step, elapsed * 1000, dt * 1000)
                time.sleep(max(0.0, dt - elapsed))
                step += 1
        finally:
            logging.info("Stopping SO101 OpenPI client")
            if pending is not None:
                pending.cancel()
            robot.disconnect()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
