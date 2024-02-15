#!/usr/bin/env bash

# vars
notify_title="Do some eye exercises"
notify_messasges="Watch video 1 or 2"
notify_icon="face-devilish"
notify_button1="Video for 1 min."
notify_button2="ВиVideo for 5 min."
pressed_button="$(notify-send "$notify_title" "$notify_messasges" -i "$notify_icon" --action "video1=$notify_button1" --action "video2=$notify_button2")"

# actions on click
if [[ "$pressed_button" == "video1" ]]; then
    firefox --new-window https://youtu.be/4ZHVYQX7tx0
elif [[ "$pressed_button" == "video2" ]]; then
    firefox --new-window https://youtu.be/SAU-Smg3tfg
fi
