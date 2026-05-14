#!/bin/bash
##################################################################
# Script Name           : monitor_backup.sh
# Version               : v2.5
# Author                : Dengwenjian@gbase.cn
# Description           : Monitor gbpbackup execution status by checking lock file and processes
# Usage                 : ./monitor_backup.sh
# Version Description   : v2.5 (2026-05-12)
#   - Improved Lock Robustness: Added lock file existence re-check before flock probing to avoid race conditions
#   - Reduced False Alerts: Introduced STALE_LIMIT counter to confirm stale-lock status only after multiple checks
#   - Enhanced PID Validation: Added PID format validation and kill -0 probing for accurate process liveness detection
#   - Process Detection Upgrade: Switched from 'ps -ux' to 'pgrep/ps -ef' for cross-user process visibility (root/gbase consistent)
#   - Cleaner Error Handling: Suppressed transient "No such file" errors when lock file is removed during runtime
#   - Exit Behavior Optimized: Immediate OK exit when lock file disappears (main script finished or trap cleanup triggered)

trap 'echo -e "\n[INFO] Monitor interrupted by user (Ctrl+C)."; exit 130' INT

# Resolve script directory
if command -v realpath &>/dev/null; then
    SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Log configuration
LOG_DIR="${SCRIPT_DIR}/logs/monitor_backup"
LOG_DATE=$(date +%Y%m%d)
LOG_FILE="${LOG_DIR}/monitor_${LOG_DATE}.log"

mkdir -p "$LOG_DIR" || {
    echo "ERROR: Failed to create log directory: $LOG_DIR" >&2
    exit 1
}

exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo "gbpbackup Monitor Started"
echo "Run User: $(id -un) (UID=$(id -u), GID=$(id -g), GROUP=$(id -gn))"
echo "Start Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Log File: $LOG_FILE"
echo "========================================"

LOCK_FILE="${SCRIPT_DIR}/.gbpbackup.lock"
CHECK_INTERVAL=5
STALE_LIMIT=3

echo "Lock File: $LOCK_FILE"
echo "Check Interval: ${CHECK_INTERVAL}s"
echo "Status: Waiting for backup to complete..."
echo "Note: Press Ctrl+C to force quit"
echo "========================================"
echo ""

# Helper: check gs_probackup processes
get_gs_probackup_count() {
    # -f: match full cmdline
    # -c: count
    if command -v pgrep &>/dev/null; then
        pgrep -fc "gs_probackup"
    else
        ps -ef | grep -E "[g]s_probackup" | wc -l
    fi
}

# If lock file not exist, treat as not running
if [[ ! -e "$LOCK_FILE" ]]; then
    echo "[$(date '+%H:%M:%S')] Lock file not found, backup not running"
    echo "========================================"
    echo "OK"
    echo "Monitor finished at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    exit 0
fi

stale_count=0

while true; do
    # lock file missing -> treat as finished
    if [[ ! -e "$LOCK_FILE" ]]; then
        echo ""
        echo "[$(date '+%H:%M:%S')] Lock file disappeared, backup not running"
        echo "========================================"
        echo "OK"
        echo "Monitor finished at $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================"
        exit 0
    fi

    lock_pid=$(head -1 "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
    gs_count=$(get_gs_probackup_count)

    # flock free -> backup completed
    if (exec 200<>"$LOCK_FILE" && flock -n 200); then
        echo ""
        echo "[$(date '+%H:%M:%S')] Lock is free (backup completed)"
        echo "Info: gs_probackup process count: $gs_count"

        if [[ -n "$lock_pid" ]]; then
            echo "Info: last recorded PID in lock file: $lock_pid"
        fi

        echo "========================================"
        echo "OK"
        echo "Monitor finished at $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================"
        exit 0
    fi

    # flock busy -> backup maybe running
    if [[ -n "$lock_pid" && "$lock_pid" =~ ^[0-9]+$ ]]; then
        if kill -0 "$lock_pid" 2>/dev/null; then
            stale_count=0
            echo "[$(date '+%H:%M:%S')] Backup in progress... (lock held by PID=$lock_pid, gs_probackup=$gs_count)"
            sleep "$CHECK_INTERVAL"
            continue
        fi
    fi

    # PID invalid or not alive, but lock still busy
    # If gs_probackup exists -> still likely running (maybe wrapper PID changed)
    if [[ "$gs_count" -gt 0 ]]; then
        stale_count=0
        echo "[$(date '+%H:%M:%S')] Backup in progress... (lock busy, PID=${lock_pid:-unknown} not alive, but gs_probackup=$gs_count)"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # Now: lock busy + pid dead/invalid + no gs_probackup process
    stale_count=$((stale_count + 1))
    echo "[$(date '+%H:%M:%S')] Warning: lock busy but PID not alive and no gs_probackup found [${stale_count}/${STALE_LIMIT}]"
    echo "         PID read : ${lock_pid:-<empty>}"

    if [[ "$stale_count" -ge "$STALE_LIMIT" ]]; then
        echo ""
        echo "[$(date '+%H:%M:%S')] ERROR: Stale lock suspected!"
        echo "         Lock file exists and flock is busy, but PID is not running and gs_probackup is not found."
        echo "         Lock file: $LOCK_FILE"
        echo "         PID read : ${lock_pid:-<empty>}"
        echo "========================================"
        echo "FAILED (Stale lock detected)"
        echo "Monitor finished at $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================"
        exit 1
    fi

    sleep "$CHECK_INTERVAL"
done