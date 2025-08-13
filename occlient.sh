#!/usr/bin/env bash

# Script security parameters
set -Eeuo pipefail

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root"
    exit 1
fi

# =============================================================
# ========== BEGINNING OF USER CONFIGURATION SECTION ==========

# Explicit PATH definition
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# Run script using Systemd
SYSTEMD_USAGE=0

# Logging parameters
LOG_TO_STDOUT=1       # simple stdout output
LOG_TO_FILE=0         # log to file (<script_name>.log)
LOG_TO_SYSLOG=0       # log to syslog (tag=<script_name>)

## VPN vars
VPN_IFACE="tun0"
VPN_SSL_FLAG=1
VPN_ADDRESS="vpn.example.com"
VPN_PORT="44444"
VPN_CERT_FILE="/path/to/exampleuser.p12"
VPN_CERT_PASS="base64password"
VPN_BIN=$(command -v openconnect)

# Connection check parameters
CHECK_INTERVAL=5       # delay between checks
CHECK_THRESHOLD=3      # number of failed attempts
CHECK_HOST="10.7.7.1"  # host to check
CHECK_UTILS=("$VPN_BIN" "ping" "timeout") # utilities to use (checks their availability)

# VPN connection command
connect_cmd(){
    echo "Connecting to VPN..."
    echo "Main PID: $$"
    if (( "$VPN_SSL_FLAG" )); then
        echo "${VPN_CERT_PASS}" | base64 -d | "$VPN_BIN" -c "$VPN_CERT_FILE" "${VPN_ADDRESS}:${VPN_PORT}" &

    else
        echo -e "$(echo "${VPN_CERT_PASS}" | base64 -d)\nyes" | "$VPN_BIN" -c "$VPN_CERT_FILE" "${VPN_ADDRESS}:${VPN_PORT}" &
    fi

    VPN_PID=$!
    echo "VPN process started, PID: $VPN_PID"

    for _ in {1..10}; do
        if ip link show $VPN_IFACE &> /dev/null; then
            echo "VPN interface $VPN_IFACE is up"
            return 0
        fi
        sleep 1
    done

    echo "VPN interface $VPN_IFACE did not appear, killing VPN process..."
    kill "$VPN_PID"
    wait "$VPN_PID" 2> /dev/null || true
    return 1
}


connect_post_up_cmd() {
    echo "Example connect_post_up_cmd"
}

connect_post_down_cmd() {
    echo "Example connect_post_down_cmd"
}


check_cmd() {
    local host="${1-}"
    timeout 6 ping -c 1 -W 5 "$host" &> /dev/null
}

# Command to run after $CHECK_THRESHOLD failed attempts
reconnect_cmd() {
    local host="${1-}"
    local old_vpn_pid="${2-}"

    if kill -0 "$old_vpn_pid" 2> /dev/null; then
        kill "$old_vpn_pid"
        wait "$old_vpn_pid" 2> /dev/null || true
    fi

    echo "Reconnecting to VPN..."
    connect_cmd || { echo "Failed to reconnect to VPN"; return 1; }

    connect_post_up_cmd
    VPN_PID=$!

    echo "VPN reconnected with new PID: $VPN_PID"
}


# Command to run after availability is restored
restore_cmd() {
    echo "Reconnected to VPN server"
}

# ========== END OF USER CONFIGURATION SECTION ==========
# =======================================================

# Basic variables
SCRIPT_PID=$$
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd -P)
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_LOG="${SCRIPT_DIR}/${SCRIPT_NAME%.*}.log"
SCRIPT_LOG_PREFIX='[%Y-%m-%d %H:%M:%S.%3N]'
SCRIPT_LOCK="${SCRIPT_DIR}/${SCRIPT_NAME%.*}.lock"
SYSTEMD_SERVICE="${SCRIPT_NAME%.*}.service"


# Cleanup when traps are triggered
cleanup() {
    trap - SIGINT SIGTERM SIGHUP SIGQUIT ERR EXIT

    [[ -n "${fd_lock-}" ]] && exec {fd_lock}>&-

    if [[ -f "$SCRIPT_LOCK" && $(< "$SCRIPT_LOCK") -eq $SCRIPT_PID ]]; then
        rm -f "$SCRIPT_LOCK"
    fi

    connect_post_down_cmd || true

    echo "Terminating child processes..."
    { pkill -TERM -P "$$" &> /dev/null && exit 0; } || true
    sleep 5
    pkill -9 -P "$$" &> /dev/null || true
}

trap cleanup SIGINT SIGTERM SIGHUP SIGQUIT ERR EXIT


# Preventing script instance from running again
exec {fd_lock}>> "${SCRIPT_LOCK}"

if ! flock -n "$fd_lock"; then
    echo "Another script instance is already running, exiting..."
    exit 1
fi

echo "$SCRIPT_PID" > "$SCRIPT_LOCK"


# Output logging
log_pipe() {
    while IFS= read -r line; do
        log_line="$(date +"${SCRIPT_LOG_PREFIX}") - $line"

        if (( "$SYSTEMD_USAGE" )); then
            if (( "$LOG_TO_STDOUT" )); then echo "$line"; fi
        else
            if (( "$LOG_TO_STDOUT" )); then echo "$log_line"; fi
        fi

        if (( "$LOG_TO_FILE" )); then echo "$log_line" >> "$SCRIPT_LOG"; fi

        if (( "$LOG_TO_SYSLOG" )); then logger -t "$SCRIPT_NAME" -- "$line"; fi
    done
}

exec > >(log_pipe) 2>&1


# Checking for required utilities
for util in "${CHECK_UTILS[@]}"; do
    if ! command -v "$util" &> /dev/null; then
        echo "Error: utility $util is not installed"
        exit 1
    fi
done


# Configuring script to run with Systemd
if (( "$SYSTEMD_USAGE" )); then
    # check if script was launched via Systemd
    if [[ $PPID -ne 1 ]]; then
      if [[ ! -f /etc/systemd/system/"${SYSTEMD_SERVICE}" ]]; then
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
        echo "To get service status use:"
        echo "systemctl status $SYSTEMD_SERVICE and journalctl -fu $SYSTEMD_SERVICE"
        exit 0
      else
        systemctl start "$SYSTEMD_SERVICE"
        echo "To get service status use:"
        echo "systemctl status $SYSTEMD_SERVICE and journalctl -fu $SYSTEMD_SERVICE"
        exit 0
      fi
    fi
fi


# Host availability monitoring function
monitor_host() {
    local host="${1-}"
    local pid="${2-}"
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

            if [[ "$check_count" -ge "$CHECK_THRESHOLD" ]]; then  # threshold actions
                is_failed=1  # set unavailable flag
                check_count=0  # reset counter

                echo "[$host]: Running reconnect command..."

                reconnect_cmd "$host" "$pid" || true  # running fail command
                pid=$VPN_PID

                sleep $CHECK_INTERVAL  # delay before next check
            fi
        fi

        sleep $CHECK_INTERVAL  # wait before next loop iteration
    done
}

# ====================
# Main execution flow
# ====================
if ! connect_cmd; then
    echo "VPN failed to start, exiting..."
    exit 1
fi

connect_post_up_cmd

sleep 5

monitor_host "$CHECK_HOST" "$VPN_PID"

