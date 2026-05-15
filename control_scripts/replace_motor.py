"""Replace a single motor: set the correct ID on a new (factory-default) motor.

Usage:
    # Only ONE motor connected to the controller board (daisy-chain disconnected)
    python scripts/replace_motor.py --motor elbow_flex
    python scripts/replace_motor.py --motor gripper

The script:
  1. Scans the bus and auto-detects the current baudrate + ID (usually 1000000 bps, ID=1).
  2. Writes the target ID (based on motor name) and re-writes the default baudrate to EEPROM.
  3. Verifies the new ID by pinging.
"""
import argparse

from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

PORT = "/dev/tty.usbmodem5B140327031"

MOTORS = {
    "shoulder_pan": 1,
    "shoulder_lift": 2,
    "elbow_flex": 3,
    "wrist_flex": 4,
    "wrist_roll": 5,
    "gripper": 6,
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--motor", required=True, choices=list(MOTORS.keys()))
    parser.add_argument("--port", default=PORT)
    args = parser.parse_args()

    target_id = MOTORS[args.motor]
    print(f"Target: {args.motor} -> ID={target_id}")
    print("Ensure ONLY this one new motor is connected to the controller board.")
    input("Press Enter to proceed...")

    bus = FeetechMotorsBus(
        port=args.port,
        motors={
            name: Motor(id_, "sts3215", MotorNormMode.RANGE_M100_100)
            for name, id_ in MOTORS.items()
        },
    )
    bus.connect(handshake=False)
    print("Connected. Configuring motor ID...")

    # setup_motor auto-scans current baudrate+ID, then writes target ID and default baudrate.
    bus.setup_motor(args.motor)
    print(f"'{args.motor}' motor id set to {target_id}")

    # Verify
    model = bus.ping(target_id, num_retry=2)
    bus.disconnect()

    if model is not None:
        print(f"Verified: motor at ID={target_id} responds with model={model}.")
        print("You can now reconnect the daisy-chain.")
    else:
        print(f"WARNING: motor at ID={target_id} did NOT respond. Check wiring.")


if __name__ == "__main__":
    main()
