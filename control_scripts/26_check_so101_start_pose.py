#!/usr/bin/env python3
"""Check or manually align the SO101 follower task-ready pose.

The default target is inferred from the successful ACT deployment at
2026-05-01 15:49:36. This is a task-ready / pre-grasp-like pose,
not a generic retracted home pose. Values are LeRobot-normalized joint
units, not degrees.

Usage:
    PYTHONPATH=/home/ubuntu/Evo-RL/src /home/ubuntu/anaconda3/envs/evo-rl/bin/python \
        control_scripts/26_check_so101_start_pose.py

    PYTHONPATH=/home/ubuntu/Evo-RL/src /home/ubuntu/anaconda3/envs/evo-rl/bin/python \
        control_scripts/26_check_so101_start_pose.py --manual --watch
"""

from __future__ import annotations

import argparse
import os
import time
from dataclasses import dataclass
from pathlib import Path

import draccus

from lerobot.motors import Motor, MotorCalibration, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus


DEFAULT_PORT = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00"
DEFAULT_CALIBRATION = (
    Path.home() / ".cache/huggingface/lerobot/calibration/robots/so_follower/my_follower.json"
)

MOTORS = {
    "shoulder_pan": Motor(1, "sts3215", MotorNormMode.RANGE_M100_100),
    "shoulder_lift": Motor(2, "sts3215", MotorNormMode.RANGE_M100_100),
    "elbow_flex": Motor(3, "sts3215", MotorNormMode.RANGE_M100_100),
    "wrist_flex": Motor(4, "sts3215", MotorNormMode.RANGE_M100_100),
    "wrist_roll": Motor(5, "sts3215", MotorNormMode.RANGE_M100_100),
    "gripper": Motor(6, "sts3215", MotorNormMode.RANGE_0_100),
}


@dataclass(frozen=True)
class Target:
    center: float
    tolerance: float
    note: str

    @property
    def low(self) -> float:
        return self.center - self.tolerance

    @property
    def high(self) -> float:
        return self.center + self.tolerance

    def delta(self, value: float) -> float:
        if self.low <= value <= self.high:
            return 0.0
        if value < self.low:
            return value - self.low
        return value - self.high


TARGETS: dict[str, dict[str, Target]] = {
    # For shoulder_pan and elbow_flex the initial present position is inferred
    # from max_relative_target=5 clamp in Action #0:
    #   shoulder_pan safe 6.301599 = present + 5
    #   elbow_flex   safe 89.479638 = present - 5
    # Other joints were not clamped at Action #0, so the exact initial position
    # is only known to be within +/-5 of the first target.
    "success_1549": {
        "shoulder_pan": Target(1.302, 2.0, "task-ready pose inferred from 15:49 clamp"),
        "shoulder_lift": Target(-67.945, 5.0, "task-ready first successful target window"),
        "elbow_flex": Target(94.480, 2.0, "task-ready pose inferred from 15:49 clamp"),
        "wrist_flex": Target(61.155, 5.0, "task-ready first successful target window"),
        "wrist_roll": Target(58.082, 5.0, "task-ready first successful target window"),
        "gripper": Target(33.862, 5.0, "task-ready first successful target window"),
    },
    # Median of the first observation.state across all 140 collected episodes in
    # guanlin8/cuhksz_pick_place_slots_ordered_20260430_all. This is useful as a
    # broad data-distribution reference, but less specific than the 15:49 run.
    "dataset_median": {
        "shoulder_pan": Target(0.372, 5.0, "dataset first-frame median"),
        "shoulder_lift": Target(-57.397, 10.0, "dataset first-frame median"),
        "elbow_flex": Target(50.769, 12.0, "dataset first-frame median"),
        "wrist_flex": Target(63.301, 6.0, "dataset first-frame median"),
        "wrist_roll": Target(51.111, 3.0, "dataset first-frame median"),
        "gripper": Target(31.693, 2.0, "dataset first-frame median"),
    },
}


def load_calibration(path: Path) -> dict[str, MotorCalibration]:
    if not path.exists():
        raise FileNotFoundError(f"Calibration file not found: {path}")
    with path.open() as f, draccus.config_type("json"):
        return draccus.load(dict[str, MotorCalibration], f)


def read_positions(bus: FeetechMotorsBus, raw: bool) -> tuple[dict[str, float], dict[str, int] | None]:
    normalized = bus.sync_read("Present_Position", normalize=True)
    raw_values = None
    if raw:
        raw_values = {k: int(v) for k, v in bus.sync_read("Present_Position", normalize=False).items()}
    return {k: float(v) for k, v in normalized.items()}, raw_values


def print_table(
    positions: dict[str, float],
    target: dict[str, Target],
    raw_values: dict[str, int] | None,
) -> bool:
    ok_all = True
    header = f"{'motor':<14} {'current':>9} {'target':>18} {'delta':>9} {'status':>8}"
    if raw_values is not None:
        header += f" {'raw':>6}"
    print(header)
    print("-" * len(header))
    for motor in MOTORS:
        value = positions[motor]
        spec = target[motor]
        delta = spec.delta(value)
        ok = abs(delta) < 1e-6
        ok_all = ok_all and ok
        if spec.tolerance > 0:
            target_text = f"{spec.center:.3f}+/-{spec.tolerance:.1f}"
        else:
            target_text = f"{spec.center:.3f}"
        line = f"{motor:<14} {value:9.3f} {target_text:>18} {delta:9.3f} {('OK' if ok else 'ADJUST'):>8}"
        if raw_values is not None:
            line += f" {raw_values[motor]:6d}"
        print(line)
    return ok_all


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default=os.environ.get("FOLLOWER_PORT", DEFAULT_PORT))
    parser.add_argument("--calibration", type=Path, default=DEFAULT_CALIBRATION)
    parser.add_argument("--target", choices=sorted(TARGETS), default="success_1549")
    parser.add_argument("--watch", action="store_true", help="continuously print current deltas")
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument(
        "--manual",
        action="store_true",
        help="disable torque after connecting so the arm can be moved by hand",
    )
    parser.add_argument("--raw", action="store_true", help="also print raw servo positions")
    args = parser.parse_args()

    calibration = load_calibration(args.calibration)
    bus = FeetechMotorsBus(args.port, MOTORS, calibration=calibration)
    bus.connect(handshake=True)
    try:
        if args.manual:
            print("Disabling torque for manual alignment. Keep one hand near power/estop.")
            bus.disable_torque()

        print(f"Target: {args.target}")
        print(f"Port: {args.port}")
        print(f"Calibration: {args.calibration}")
        print("Units: LeRobot-normalized joint units, not physical degrees.")
        print("")

        while True:
            positions, raw_values = read_positions(bus, args.raw)
            ok_all = print_table(positions, TARGETS[args.target], raw_values)
            print("\nResult:", "OK - start pose is within target window" if ok_all else "ADJUST - align marked joints")
            if not args.watch:
                break
            time.sleep(args.interval)
            print("\033[H\033[J", end="")
    finally:
        # In manual mode, leave torque disabled on exit. In read-only mode, avoid
        # changing motor torque state by passing disable_torque=False.
        bus.disconnect(disable_torque=args.manual)


if __name__ == "__main__":
    main()
