"""Re-calibrate only the gripper range without touching other joints.

Usage:
    PYTHONPATH=/home/ubuntu/Evo-RL/src \
    /home/ubuntu/anaconda3/envs/evo-rl/bin/python scripts/recalibrate_gripper.py

The script:
  1. Disables torque on the gripper motor (you can move it by hand).
  2. Prompts you to push the gripper fully CLOSED, reads the raw position.
  3. Prompts you to push the gripper fully OPEN, reads the raw position.
  4. Updates range_min / range_max in my_follower.json (other joints untouched).
"""
import json
import os
from pathlib import Path

from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

PORT = os.environ.get("FOLLOWER_PORT", "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00")
CALIB_PATH = Path.home() / ".cache/huggingface/lerobot/calibration/robots/so_follower/my_follower.json"

MOTORS = {"gripper": Motor(6, "sts3215", MotorNormMode.RANGE_0_100)}


def read_raw(bus: FeetechMotorsBus, motor: str) -> int:
    # Read raw present position without calibration transform
    val = bus.sync_read("Present_Position", [motor], normalize=False)
    return int(val[motor])


def main():
    if not CALIB_PATH.exists():
        raise SystemExit(f"Calibration file not found: {CALIB_PATH}")

    bus = FeetechMotorsBus(
        port=PORT,
        motors=MOTORS,
    )
    bus.connect(handshake=False)
    print("Connected. Disabling torque on gripper so you can move it by hand...")
    bus.disable_torque("gripper")

    try:
        input("\n[1/2] Push the gripper FULLY CLOSED by hand, then press Enter...")
        closed_raw = read_raw(bus, "gripper")
        print(f"    closed raw = {closed_raw}")

        input("\n[2/2] Push the gripper FULLY OPEN by hand, then press Enter...")
        open_raw = read_raw(bus, "gripper")
        print(f"    open   raw = {open_raw}")

        new_min = min(closed_raw, open_raw)
        new_max = max(closed_raw, open_raw)
        print(f"\nNew gripper range: min={new_min}, max={new_max}")

        # Backup + update JSON
        backup_path = CALIB_PATH.with_suffix(f".json.bak_{os.getpid()}")
        calib = json.loads(CALIB_PATH.read_text())
        old_min = calib["gripper"]["range_min"]
        old_max = calib["gripper"]["range_max"]

        CALIB_PATH.rename(backup_path)
        calib["gripper"]["range_min"] = new_min
        calib["gripper"]["range_max"] = new_max
        CALIB_PATH.write_text(json.dumps(calib, indent=4))

        print(f"\nBackup: {backup_path}")
        print(f"Updated {CALIB_PATH}")
        print(f"  gripper range_min: {old_min} -> {new_min}")
        print(f"  gripper range_max: {old_max} -> {new_max}")
    finally:
        # Re-enable torque cleanly
        try:
            bus.enable_torque("gripper")
        except Exception:
            pass
        bus.disconnect()


if __name__ == "__main__":
    main()
