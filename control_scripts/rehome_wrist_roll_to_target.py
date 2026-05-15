#!/usr/bin/env python3
"""Re-home only follower wrist_roll so the current physical orientation maps to a target value.

Use this when the wrist/hand is physically in the correct task-ready orientation,
but LeRobot normalized `wrist_roll` reads the opposite side of the range.

Default is dry-run. Add --apply to write the new Homing_Offset to the motor and
update the local follower calibration file.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import time
from pathlib import Path

import draccus

from lerobot.motors import Motor, MotorCalibration, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus


DEFAULT_PORT = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00"
DEFAULT_CALIBRATION = (
    Path.home() / ".cache/huggingface/lerobot/calibration/robots/so_follower/my_follower.json"
)


def normalized_to_raw(value: float, cal: MotorCalibration) -> int:
    value = min(100.0, max(-100.0, value))
    return int(round(((value + 100.0) / 200.0) * (cal.range_max - cal.range_min) + cal.range_min))


def load_typed_calibration(path: Path) -> dict[str, MotorCalibration]:
    with path.open() as f, draccus.config_type("json"):
        return draccus.load(dict[str, MotorCalibration], f)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default=os.environ.get("FOLLOWER_PORT", DEFAULT_PORT))
    parser.add_argument("--calibration", type=Path, default=DEFAULT_CALIBRATION)
    parser.add_argument("--target", type=float, default=58.082)
    parser.add_argument("--apply", action="store_true", help="write motor Homing_Offset and update calibration file")
    args = parser.parse_args()

    motor = "wrist_roll"
    if not args.calibration.exists():
        raise SystemExit(f"Calibration file not found: {args.calibration}")

    calibration = load_typed_calibration(args.calibration)
    if motor not in calibration:
        raise SystemExit(f"{motor!r} not found in calibration file: {args.calibration}")

    cal = calibration[motor]
    motors = {motor: Motor(5, "sts3215", MotorNormMode.RANGE_M100_100)}
    bus = FeetechMotorsBus(args.port, motors=motors, calibration={motor: cal})
    bus.connect(handshake=True)
    try:
        current_raw = int(bus.sync_read("Present_Position", [motor], normalize=False)[motor])
        current_norm = float(bus.sync_read("Present_Position", [motor], normalize=True)[motor])
        target_raw = normalized_to_raw(args.target, cal)
        delta_present = target_raw - current_raw
        new_homing_offset = int(cal.homing_offset - delta_present)

        print("=== wrist_roll re-home plan ===")
        print(f"Port:        {args.port}")
        print(f"Calibration: {args.calibration}")
        print(f"Current norm/raw: {current_norm:.3f} / {current_raw}")
        print(f"Target  norm/raw: {args.target:.3f} / {target_raw}")
        print(f"Current homing_offset: {cal.homing_offset}")
        print(f"New     homing_offset: {new_homing_offset}")
        print("")
        if not args.apply:
            print("Dry-run only. Add --apply if the current physical wrist direction is correct.")
            return

        backup = args.calibration.with_suffix(f".json.bak_wrist_roll_{time.strftime('%Y%m%d_%H%M%S')}")
        shutil.copy2(args.calibration, backup)

        print("Applying. Disabling wrist_roll torque before writing offset...")
        bus.disable_torque(motor)
        bus.write("Homing_Offset", motor, new_homing_offset, normalize=False)

        raw_json = json.loads(args.calibration.read_text())
        raw_json[motor]["homing_offset"] = new_homing_offset
        args.calibration.write_text(json.dumps(raw_json, indent=4) + "\n")

        # Update in-memory calibration for a post-write read.
        cal.homing_offset = new_homing_offset
        bus.calibration[motor] = cal
        new_raw = int(bus.sync_read("Present_Position", [motor], normalize=False)[motor])
        new_norm = float(bus.sync_read("Present_Position", [motor], normalize=True)[motor])
        print(f"Backup: {backup}")
        print(f"After write norm/raw: {new_norm:.3f} / {new_raw}")
        print("wrist_roll torque is left disabled; reconnecting teleop/deploy will configure motors again.")
    finally:
        if bus.is_connected:
            bus.disconnect(disable_torque=False)


if __name__ == "__main__":
    main()
