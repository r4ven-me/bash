#!/usr/bin/env bash

# Script security parameters
set -Eeuo pipefail

# =============================================================
# ========== BEGINNING OF USER CONFIGURATION SECTION ==========

# Explicit PATH definition
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# Run script using Systemd
SYSTEMD_USAGE=true

# Logging parameters
LOG_TO_STDOUT=true    # simple stdout output
LOG_TO_FILE=false     # log to file (<script_name>.log)
LOG_TO_SYSLOG=false   # log to syslog (tag=<script_name>)

# Check parameters
CHECK_INTERVAL=5     # delay between checks
CHECK_THRESHOLD=3    # number of failed attempts
CHECK_HOSTS=(        # list of hosts to check
    "r4ven.me"
    "arena.r4ven.me"
    "192.168.122.1"
    "1.1.1.1"
    "8.8.8.8"
)
CHECK_UTILS=("ping" "mtr") # utilities to use (checks their availability)

# Check command
check_cmd() { timeout 6 ping -c 1 -W 5 "${1-}" &> /dev/null; }
# Command to run after $CHECK_THRESHOLD failed attempts
fail_cmd() { 
    fail_cmd_result=$(mtr --report-wide --show-ips "${1-}")

    echo "[${1-}]: Fail command output:"
    echo "----------------------------------"
    echo "$fail_cmd_result"
    echo "----------------------------------"
}
# Command to run after availability is restored
restore_cmd() { echo "Example restore command for ${1-}"; }

# ========== END OF USER CONFIGURATION SECTION ==========
# ======================================================

# Basic variables
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd -P)
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_LOG="${SCRIPT_DIR}/${SCRIPT_NAME%.*}.log"
SCRIPT_LOG_PREFIX='[%Y-%m-%d %H:%M:%S.%3N]'
SCRIPT_LOCK="${SCRIPT_DIR}/${SCRIPT_NAME%.*}.lock"
SYSTEMD_SERVICE="${SCRIPT_NAME%.*}.service"


# Cleanup when traps are triggered
cleanup() {
    trap - SIGINT SIGTERM ERR EXIT

    [[ -n "${fd_lock:-}" ]] && exec {fd_lock}>&-

    if [[ -f "$SCRIPT_LOCK" && $(< "$SCRIPT_LOCK") == "$$" ]]; then
        rm -f "$SCRIPT_LOCK"
    fi
}

trap cleanup SIGINT SIGTERM ERR EXIT


# Preventing script instance from running again
exec {fd_lock}>> "${SCRIPT_LOCK}"

if ! flock -n "$fd_lock"; then
    echo "Script instance is already running, exiting..."
    exit 1
fi

echo "$$" > "$SCRIPT_LOCK"


# Output logging
log_pipe() {
    while IFS= read -r line; do
        log_line="$(date +"${SCRIPT_LOG_PREFIX}") - $line"
        if [[ "${LOG_TO_STDOUT}" == "true" ]]; then echo "$log_line"; fi
        if [[ "${LOG_TO_FILE}" == "true" ]]; then echo "$log_line" >> "$SCRIPT_LOG"; fi
        if [[ "${LOG_TO_SYSLOG}" == "true" ]]; then logger -t "${SCRIPT_NAME}" -- "$line"; fi
    done
}

exec > >(log_pipe) 2>&1


# Checking for required utilities
for util in "${CHECK_UTILS[@]}"; do
    if ! which "$util" &> /dev/null; then
        echo "Error: utility $util is not installed"
        exit 1
    fi
done


# Configuring script to run with Systemd
if [[ "$SYSTEMD_USAGE" == "true" ]]; then
    # check for root privileges
    if [[ $EUID -ne 0 ]]; then
      echo "Please run as root"
      exit 1
    fi
    
    # check if script was launched via Systemd
    if [[ $PPID -ne 1 ]]; then
      if [[ ! -f /etc/systemd/system/"$SYSTEMD_SERVICE" ]]; then
        cat << EOF > /etc/systemd/system/"${SYSTEMD_SERVICE}"
[Unit]
Description=$SCRIPT_NAME
After=network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=5
ExecStart=$SCRIPT_DIR/$SCRIPT_NAME

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SYSTEMD_SERVICE"
        systemctl start "$SYSTEMD_SERVICE"
        exit 0
      else
        systemctl start "$SYSTEMD_SERVICE"
        exit 0
      fi
    fi
fi


# Host availability monitoring function
monitor_host() {
    local host="${1-}"
    local check_count=0
    local is_failed=0  # 0 - host available, 1 - host unavailable
    
    echo "Starting availability check for $host"
    
    while true; do  # infinite loop
        if check_cmd "$host"; then  # running availability check command
            if [[ "$is_failed" -eq 1 ]]; then  # actions when recovering from unavailability
                echo "[$host]: Availability restored"
                echo "[$host]: Running restore command..."

                restore_cmd "$host" || true

                is_failed=0  # reset unavailable flag
                check_count=0  # reset counter
                
            else
                check_count=0   # host is available, reset counter
            fi
        else  # actions when unavailable
            ((++check_count))  # increment counter

            echo "[$host]: Failed availability check ($check_count/$CHECK_THRESHOLD)"
            
            if [[ "$check_count" -ge "$CHECK_THRESHOLD" && "$is_failed" -eq 0 ]]; then  # threshold actions
                echo "[$host]: Running fail command..."
                
                fail_cmd "$host" || true  # running fail command
                
                is_failed=1  # set unavailable flag

                sleep $CHECK_INTERVAL  # delay before next check
            fi
        fi
        
        sleep $CHECK_INTERVAL  # wait before next loop iteration
    done
}


# Displaying list of hosts to check
echo "Availability monitoring started for the following hosts:"
echo "${CHECK_HOSTS[@]}"

# Starting monitoring for each host in separate process
for host in "${CHECK_HOSTS[@]}"; do
    monitor_host "$host" &
    trap 'kill "$!"' SIGINT SIGTERM ERR EXIT
done

# Waiting for all background processes to complete (effectively infinite)
wait

