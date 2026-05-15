#!/bin/bash
# Tail the current deploy diagnostics from the robot client and policy server.
#
# Usage:
#   bash control_scripts/16_monitor_deploy_diagnostics.sh
#   bash control_scripts/16_monitor_deploy_diagnostics.sh outputs/deploy_logs/20260429_034047_pick_up_the_letter_c

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LAB_HOST="${LAB_HOST:-local}"
LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/outputs/deploy_logs}"
RUN_DIR="${1:-}"

is_local_lab() {
    case "$LAB_HOST" in
        local|localhost|127.0.0.1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

if [ -z "$RUN_DIR" ]; then
    RUN_DIR="$(ls -td "$LOG_ROOT"/* 2>/dev/null | head -1 || true)"
fi

if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
    echo "ERROR: deploy run directory not found. Pass one explicitly." >&2
    exit 1
fi

CLIENT_LOG="$RUN_DIR/robot_client.log"
RUN_INFO="$RUN_DIR/run_info.txt"

if [ ! -f "$CLIENT_LOG" ]; then
    echo "ERROR: client log not found: $CLIENT_LOG" >&2
    exit 1
fi

SERVER_LOG=""
if [ -f "$RUN_INFO" ]; then
    SERVER_LOG="$(awk -F= '$1 == "server_log" {print substr($0, index($0, "=") + 1)}' "$RUN_INFO")"
fi

PATTERN='DIAG|OVERRUN|transport jpeg|read failed|latest frame is too old|Error reading frame|ERROR|WARNING|Traceback'

echo "Run dir: $RUN_DIR"
echo "Client log: $CLIENT_LOG"
if [ -n "$SERVER_LOG" ]; then
    echo "Server log: $LAB_HOST:$SERVER_LOG"
else
    echo "Server log: not recorded in $RUN_INFO"
fi
echo "Filtering pattern: $PATTERN"
if [ -f "$RUN_INFO" ] && grep -q '^finished_at=' "$RUN_INFO"; then
    echo "WARNING: this run_info records a finished deployment. The monitor will only show old log lines."
fi
if ! pgrep -f "lerobot.async_inference.robot_client" >/dev/null; then
    echo "WARNING: no local robot_client is currently running."
    echo "Start a deployment first, then rerun this monitor so it follows the new run directory:"
    echo "  bash control_scripts/15_deploy_act_pick_letter.sh C"
fi
echo ""

tail -F "$CLIENT_LOG" | awk -v pattern="$PATTERN" '
    $0 ~ pattern {
        print "[CLIENT] " $0
        fflush()
    }
' &
CLIENT_TAIL_PID=$!

cleanup() {
    kill "$CLIENT_TAIL_PID" 2>/dev/null || true
    if [ -n "${SERVER_TAIL_PID:-}" ]; then
        kill "$SERVER_TAIL_PID" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

if [ -n "$SERVER_LOG" ]; then
    if is_local_lab; then
        tail -F "$SERVER_LOG" | awk -v pattern="$PATTERN" '
            $0 ~ pattern {
                print "[SERVER] " $0
                fflush()
            }
        ' &
    else
        ssh "$LAB_HOST" "tail -F '$SERVER_LOG'" | awk -v pattern="$PATTERN" '
            $0 ~ pattern {
                print "[SERVER] " $0
                fflush()
            }
        ' &
    fi
    SERVER_TAIL_PID=$!
fi

wait
