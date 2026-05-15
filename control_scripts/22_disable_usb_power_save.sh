#!/usr/bin/env bash
set -euo pipefail

# Disable Linux runtime USB autosuspend for the SO101 hub, cameras, and serial adapters.
# This is a mitigation for intermittent UVC disconnects; it does not fix bad cables/hubs.

DEFAULT_FRONT_CAMERA_PATH="/dev/v4l/by-id/usb-icSpring_icspring_camera_202404160005-video-index0"
DEFAULT_WRIST_CAMERA_PATH="/dev/v4l/by-id/usb-CN02KX4NLG0004ABK00_USB_Camera_CN02KX4NLG0004ABK00-video-index0"
DEFAULT_FOLLOWER_PORT="/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00"
DEFAULT_LEADER_PORT="/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3E120040-if00"

FRONT_CAMERA_PATH="${FRONT_CAMERA_PATH:-$DEFAULT_FRONT_CAMERA_PATH}"
WRIST_CAMERA_PATH="${WRIST_CAMERA_PATH:-$DEFAULT_WRIST_CAMERA_PATH}"
FOLLOWER_PORT="${FOLLOWER_PORT:-$DEFAULT_FOLLOWER_PORT}"
LEADER_PORT="${LEADER_PORT:-$DEFAULT_LEADER_PORT}"

USB_HUB_PATH="${USB_HUB_PATH:-/sys/bus/usb/devices/1-3}"
USB_GLOBAL_AUTOSUSPEND_OFF="${USB_GLOBAL_AUTOSUSPEND_OFF:-0}"

declare -A SEEN=()
TARGETS=()

add_target() {
    local path="$1"
    [ -n "$path" ] || return 0
    [ -e "$path" ] || return 0
    path="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
    [ -n "${SEEN[$path]:-}" ] && return 0
    SEEN["$path"]=1
    TARGETS+=("$path")
}

add_usb_ancestors() {
    local path="$1"
    local cursor
    cursor="$(readlink -f "$path" 2>/dev/null || true)"
    while [ -n "$cursor" ] && [ "$cursor" != "/" ]; do
        if [ -e "$cursor/idVendor" ] && [ -e "$cursor/idProduct" ]; then
            add_target "$cursor"
        fi
        cursor="$(dirname "$cursor")"
    done
}

add_video_device() {
    local node="$1"
    [ -e "$node" ] || {
        echo "missing video node: $node"
        return 0
    }
    local resolved base sysfs_device
    resolved="$(readlink -f "$node" 2>/dev/null || printf '%s' "$node")"
    base="$(basename "$resolved")"
    sysfs_device="$(readlink -f "/sys/class/video4linux/$base/device" 2>/dev/null || true)"
    add_usb_ancestors "$sysfs_device"
}

add_serial_device() {
    local node="$1"
    [ -e "$node" ] || {
        echo "missing serial node: $node"
        return 0
    }
    local resolved base sysfs_device
    resolved="$(readlink -f "$node" 2>/dev/null || printf '%s' "$node")"
    base="$(basename "$resolved")"
    sysfs_device="$(readlink -f "/sys/class/tty/$base/device" 2>/dev/null || true)"
    add_usb_ancestors "$sysfs_device"
}

write_value() {
    local path="$1"
    local value="$2"
    if [ -w "$path" ]; then
        printf '%s\n' "$value" > "$path"
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        printf '%s\n' "$value" | sudo tee "$path" >/dev/null
        return 0
    fi
    echo "skip $path: need sudo (run: sudo $0)"
    return 1
}

add_target "$USB_HUB_PATH"
add_video_device "$FRONT_CAMERA_PATH"
add_video_device "$WRIST_CAMERA_PATH"
add_serial_device "$FOLLOWER_PORT"
add_serial_device "$LEADER_PORT"

if [ "$USB_GLOBAL_AUTOSUSPEND_OFF" = "1" ] && [ -e /sys/module/usbcore/parameters/autosuspend ]; then
    write_value /sys/module/usbcore/parameters/autosuspend -1 || true
fi

for dev in "${TARGETS[@]}"; do
    control="$dev/power/control"
    [ -e "$control" ] || continue
    write_value "$control" on || true
done

echo "--- USB power state ---"
for dev in "${TARGETS[@]}"; do
    [ -e "$dev/power/control" ] || continue
    vendor="$(cat "$dev/idVendor" 2>/dev/null || true)"
    product="$(cat "$dev/idProduct" 2>/dev/null || true)"
    speed="$(cat "$dev/speed" 2>/dev/null || true)"
    control="$(cat "$dev/power/control" 2>/dev/null || true)"
    runtime="$(cat "$dev/power/runtime_status" 2>/dev/null || true)"
    echo "$dev vendor=$vendor product=$product speed=$speed control=$control runtime=$runtime"
done

