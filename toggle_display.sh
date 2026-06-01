#!/usr/bin/env bash
set -e

if [ -d /sys/class/backlight ] && [ -n "$(ls -A /sys/class/backlight 2>/dev/null)" ]; then
    B="$(ls /sys/class/backlight | head -n1)"
    CUR="$(cat /sys/class/backlight/$B/bl_power 2>/dev/null || echo "")"

    if [ "$CUR" = "1" ]; then
        echo 0 | sudo tee /sys/class/backlight/$B/bl_power >/dev/null
        echo "Backlight ON"
    else
        echo 1 | sudo tee /sys/class/backlight/$B/bl_power >/dev/null
        echo "Backlight OFF"
    fi
else
    STATE="$(vcgencmd display_power 2>/dev/null || true)"
    if echo "$STATE" | grep -q "display_power=1"; then
        vcgencmd display_power 0
        echo "HDMI OFF"
    else
        vcgencmd display_power 1
        echo "HDMI ON"
    fi
fi
