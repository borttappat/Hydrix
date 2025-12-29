#!/usr/bin/env bash
# Trigger virt-manager's internal fullscreen mode (hides menubar)
# Usage: vm-fullscreen-hack.sh <vm-name>
#
# This script works around virt-manager not exposing fullscreen via CLI/dbus
# by simulating the exact keyboard sequence needed to trigger View > Fullscreen

# Don't use set -e so we can handle failures gracefully
set -uo pipefail

VM_NAME="${1:-}"

if [ -z "$VM_NAME" ]; then
    echo "Usage: vm-fullscreen-hack.sh <vm-name>"
    echo ""
    echo "Available VMs:"
    xdotool search --name "on QEMU" 2>/dev/null | while read wid; do
        xprop -id "$wid" WM_NAME 2>/dev/null | sed 's/WM_NAME(STRING) = "/  /' | sed 's/ on QEMU.*//'
    done
    exit 1
fi

# Find the window
WINDOW_ID=$(xdotool search --name "$VM_NAME on QEMU" 2>/dev/null | head -1)

if [ -z "$WINDOW_ID" ]; then
    echo "Error: Could not find window for VM '$VM_NAME'"
    exit 1
fi

# Get window geometry (with timeout)
if ! eval $(timeout 3 xdotool getwindowgeometry --shell "$WINDOW_ID" 2>/dev/null); then
    echo "Error: Could not get window geometry"
    exit 1
fi

# Step 1: Activate window (with timeout to prevent hang)
timeout 3 xdotool windowactivate --sync "$WINDOW_ID" 2>/dev/null || echo "Window activate timed out, continuing..."
sleep 0.3

# Step 2: Click on window border/menubar area to ensure GTK has focus (not VM console)
BORDER_X=$((X + WIDTH/2))
BORDER_Y=$((Y + 2))
xdotool mousemove "$BORDER_X" "$BORDER_Y"
xdotool click 1
sleep 0.2

# Step 3: Release any VM keyboard grab with Ctrl+Alt
xdotool keydown ctrl+alt
sleep 0.1
xdotool keyup ctrl+alt
sleep 0.3

# Step 4: Hold Alt for ~1 second, then press V while holding (opens View menu)
xdotool keydown alt
sleep 1.0
xdotool key v
sleep 0.1
xdotool keyup alt
sleep 0.3

# Step 5: Press F to activate Fullscreen
xdotool key f
sleep 0.3

# Step 6: Move cursor to center of screen
SCREEN_WIDTH=$(xdotool getdisplaygeometry | cut -d' ' -f1)
SCREEN_HEIGHT=$(xdotool getdisplaygeometry | cut -d' ' -f2)
CENTER_X=$((SCREEN_WIDTH / 2))
CENTER_Y=$((SCREEN_HEIGHT / 2))
xdotool mousemove "$CENTER_X" "$CENTER_Y"
