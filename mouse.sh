#!/usr/bin/env bash

# First run enables mouse movement (in background)
# Second run kills any already running instance

# Interval between mouse movements (in seconds)
INTERVAL=5
# Name of the current script (used to detect other copies)
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Count how many copies of this script are already running
PROC_COUNT="$(pgrep -fc "bash.*$SCRIPT_NAME")"

# When terminated, send "Mouse OFF" notification and exit cleanly
trap 'notify-send "Mouse OFF"; exit 0' SIGTERM SIGINT SIGHUP

# Function: move the mouse by 1 pixel back and forth
move_mouse() {
    xdotool mousemove_relative --sync 1 1
    sleep 0.1
    xdotool mousemove_relative --sync -- -1 -1
}

# If the script is already running — kill all instances
if (( PROC_COUNT > 1 )); then
    pkill -f "bash.*$SCRIPT_NAME"
fi

# Send a notification that the script has started
notify-send "Mouse ON"

# Background loop
(
    while true; do
        move_mouse        # simulate mouse movement
        sleep "$INTERVAL" # wait before next move
    done
) &

# Detach the background process from the shell
disown
