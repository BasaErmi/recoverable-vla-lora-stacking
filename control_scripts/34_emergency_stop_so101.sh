#!/usr/bin/env bash
# ============================================================
# Emergency stop/cleanup for SO101 lab runs.
#
# This is a software stop helper, not a replacement for the physical
# power switch or estop. Use physical power cutoff immediately if the
# robot is unsafe or still stiff after this script.
#
# What it does:
#   1. Stop local robot clients, recording, teleop, and Rerun viewers.
#   2. Stop ACT/LeRobot and OpenPI policy servers.
#   3. Run the robust follower torque-off cleanup from 12_deploy_pick_letter.sh.
#
# Usage:
#   bash control_scripts/34_emergency_stop_so101.sh
#
# Optional:
#   FORCE_KILL=0 bash control_scripts/34_emergency_stop_so101.sh
# ============================================================

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FOLLOWER_PORT="${FOLLOWER_PORT:-/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B14032703-if00}"
FORCE_KILL="${FORCE_KILL:-1}"
STOP_OPENPI_SERVER="${STOP_OPENPI_SERVER:-1}"
STOP_ACT_SERVER="${STOP_ACT_SERVER:-1}"
STOP_RERUN="${STOP_RERUN:-1}"
LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/outputs/stop_logs}"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_ROOT/${RUN_STAMP}_emergency_stop_so101.log"

mkdir -p "$LOG_ROOT"

log() {
    printf '%s %s\n' "$(date -Is)" "$*"
}

list_matches() {
    local label="$1"
    local pattern="$2"
    log "--- $label ---"
    pgrep -af "$pattern" || true
}

stop_pattern() {
    local label="$1"
    local pattern="$2"
    log "Stopping $label with SIGINT..."
    pkill -INT -f "$pattern" 2>/dev/null || true
}

term_pattern() {
    local label="$1"
    local pattern="$2"
    log "Stopping $label with SIGTERM..."
    pkill -TERM -f "$pattern" 2>/dev/null || true
}

kill_pattern() {
    local label="$1"
    local pattern="$2"
    if [ "$FORCE_KILL" = "1" ]; then
        log "Force-killing remaining $label with SIGKILL..."
        pkill -KILL -f "$pattern" 2>/dev/null || true
    fi
}

wait_for_no_match() {
    local pattern="$1"
    local timeout_s="${2:-5}"
    local waited=0
    while [ "$waited" -lt "$timeout_s" ]; do
        if ! pgrep -f "$pattern" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

wait_for_port_free() {
    local timeout_s="${1:-5}"
    local waited=0
    while [ "$waited" -lt "$timeout_s" ]; do
        if ! lsof "$FOLLOWER_PORT" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

main() {
    exec > >(tee -a "$LOG_FILE") 2>&1

    log "=== SO101 emergency software stop ==="
    log "Log: $LOG_FILE"
    log "Follower port: $FOLLOWER_PORT"
    log "FORCE_KILL=$FORCE_KILL STOP_OPENPI_SERVER=$STOP_OPENPI_SERVER STOP_ACT_SERVER=$STOP_ACT_SERVER STOP_RERUN=$STOP_RERUN"

    log "Current relevant processes before stop:"
    list_matches "OpenPI SO101 client" "openpi_so101_client.py"
    list_matches "LeRobot async robot client" "lerobot.async_inference.robot_client"
    list_matches "LeRobot record/teleop" "lerobot-record|lerobot_teleoperate|lerobot-teleoperate"
    list_matches "record wrapper scripts" "scripts/(09_record_data|27_record_cuhk|28_record_cuhk|29_record_cuhk|33_record_cuhk)"
    list_matches "OpenPI policy server" "scripts/serve_policy.py"
    list_matches "ACT/LeRobot policy server" "lerobot.async_inference.policy_server"
    list_matches "Rerun viewer/server" "rerun_cli/rerun|/bin/rerun|rerun --port"
    log "--- serial port users ---"
    lsof "$FOLLOWER_PORT" 2>/dev/null || true

    stop_pattern "OpenPI SO101 client" "openpi_so101_client.py"
    stop_pattern "LeRobot async robot client" "lerobot.async_inference.robot_client"
    stop_pattern "LeRobot record/teleop" "lerobot-record|lerobot_teleoperate|lerobot-teleoperate"
    stop_pattern "record wrapper scripts" "scripts/(09_record_data|27_record_cuhk|28_record_cuhk|29_record_cuhk|33_record_cuhk)"
    sleep 2

    term_pattern "OpenPI SO101 client" "openpi_so101_client.py"
    term_pattern "LeRobot async robot client" "lerobot.async_inference.robot_client"
    term_pattern "LeRobot record/teleop" "lerobot-record|lerobot_teleoperate|lerobot-teleoperate"
    term_pattern "record wrapper scripts" "scripts/(09_record_data|27_record_cuhk|28_record_cuhk|29_record_cuhk|33_record_cuhk)"

    wait_for_no_match "openpi_so101_client.py|lerobot.async_inference.robot_client|lerobot-record|lerobot_teleoperate|lerobot-teleoperate|scripts/(09_record_data|27_record_cuhk|28_record_cuhk|29_record_cuhk|33_record_cuhk)" 5 || true

    kill_pattern "OpenPI SO101 client" "openpi_so101_client.py"
    kill_pattern "LeRobot async robot client" "lerobot.async_inference.robot_client"
    kill_pattern "LeRobot record/teleop" "lerobot-record|lerobot_teleoperate|lerobot-teleoperate"
    kill_pattern "record wrapper scripts" "scripts/(09_record_data|27_record_cuhk|28_record_cuhk|29_record_cuhk|33_record_cuhk)"

    if [ "$STOP_OPENPI_SERVER" = "1" ]; then
        term_pattern "OpenPI policy server" "scripts/serve_policy.py"
    fi
    if [ "$STOP_ACT_SERVER" = "1" ]; then
        term_pattern "ACT/LeRobot policy server" "lerobot.async_inference.policy_server"
    fi
    if [ "$STOP_RERUN" = "1" ]; then
        term_pattern "Rerun viewer/server" "rerun_cli/rerun|/bin/rerun|rerun --port"
    fi

    sleep 2
    if [ "$STOP_OPENPI_SERVER" = "1" ]; then
        kill_pattern "OpenPI policy server" "scripts/serve_policy.py"
    fi
    if [ "$STOP_ACT_SERVER" = "1" ]; then
        kill_pattern "ACT/LeRobot policy server" "lerobot.async_inference.policy_server"
    fi
    if [ "$STOP_RERUN" = "1" ]; then
        kill_pattern "Rerun viewer/server" "rerun_cli/rerun|/bin/rerun|rerun --port"
    fi

    if ! wait_for_port_free 5; then
        log "WARNING: follower port is still in use before torque-off:"
        lsof "$FOLLOWER_PORT" 2>/dev/null || true
    fi

    log "Running follower torque-off cleanup..."
    FOLLOWER_PORT="$FOLLOWER_PORT" bash "$SCRIPT_DIR/12_deploy_pick_letter.sh" --stop || true

    log "Current relevant processes after stop:"
    list_matches "OpenPI SO101 client" "openpi_so101_client.py"
    list_matches "LeRobot async robot client" "lerobot.async_inference.robot_client"
    list_matches "LeRobot record/teleop" "lerobot-record|lerobot_teleoperate|lerobot-teleoperate"
    list_matches "record wrapper scripts" "scripts/(09_record_data|27_record_cuhk|28_record_cuhk|29_record_cuhk|33_record_cuhk)"
    list_matches "OpenPI policy server" "scripts/serve_policy.py"
    list_matches "ACT/LeRobot policy server" "lerobot.async_inference.policy_server"
    log "--- serial port users after stop ---"
    lsof "$FOLLOWER_PORT" 2>/dev/null || true

    log "=== stop complete ==="
    log "If any joint is still stiff or unsafe, use physical power cutoff."
}

main "$@"
