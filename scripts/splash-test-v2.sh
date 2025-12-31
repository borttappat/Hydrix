#!/usr/bin/env bash
# Splash cover v2 - Uses xinput to block physical input while allowing xdotool
# This test:
# 1. Shows splash and makes it STICKY (appears on all workspaces)
# 2. Disables keyboard/mouse input
# 3. Simulates xdotool operations (opens a terminal on another workspace)
# 4. Re-enables input
# 5. Kills splash

SPLASH_DIR="/tmp/splash-test"
CONFIG_FILE="$HOME/Hydrix/configs/display-config.json"
INPUT_DEVICES_FILE="/tmp/disabled-input-devices.txt"

# Store device IDs before we start (for reliable re-enable)
store_input_devices() {
    xinput list | grep -E "slave\s+(keyboard|pointer)" | grep -v "XTEST" | grep -oP 'id=\K[0-9]+' > "$INPUT_DEVICES_FILE"
}

# Disable all input devices
disable_input() {
    echo "Disabling physical input devices..."
    while read -r id; do
        xinput disable "$id" 2>/dev/null && echo "  Disabled device $id"
    done < "$INPUT_DEVICES_FILE"
}

# Re-enable all input devices (reads from saved file)
enable_input() {
    echo "Re-enabling physical input devices..."
    if [ -f "$INPUT_DEVICES_FILE" ]; then
        while read -r id; do
            xinput enable "$id" 2>/dev/null && echo "  Enabled device $id"
        done < "$INPUT_DEVICES_FILE"
        rm -f "$INPUT_DEVICES_FILE"
    else
        # Fallback: enable ALL input devices
        echo "  Fallback: enabling all devices..."
        for id in $(xinput list | grep -E "slave\s+(keyboard|pointer)" | grep -oP 'id=\K[0-9]+'); do
            xinput enable "$id" 2>/dev/null
        done
    fi
}

# Cleanup function - ALWAYS runs
cleanup() {
    echo ""
    echo "=== CLEANUP ==="
    enable_input
    pkill -f "feh.*splash-test" 2>/dev/null || true
    rm -rf "$SPLASH_DIR" 2>/dev/null || true
    echo "Cleanup complete."
}

# Set trap FIRST before anything else
trap cleanup EXIT

mkdir -p "$SPLASH_DIR"

# Store input devices before anything else
store_input_devices

# Get font from display-config.json
if [ -f "$CONFIG_FILE" ]; then
    FONT_BASE=$(jq -r '.fonts.default // "cozette"' "$CONFIG_FILE")
    case "$FONT_BASE" in
        cozette|Cozette) FONT="CozetteVector" ;;
        *) FONT="$FONT_BASE" ;;
    esac
else
    FONT="CozetteVector"
fi

# Get colors
if [ -f ~/.cache/wal/colors.json ]; then
    BG_COLOR=$(jq -r '.special.background // .colors.color0' ~/.cache/wal/colors.json)
    FG_COLOR=$(jq -r '.special.foreground // .colors.color7' ~/.cache/wal/colors.json)
    ACCENT_COLOR=$(jq -r '.colors.color4' ~/.cache/wal/colors.json)
else
    BG_COLOR="#0B0E1B"
    FG_COLOR="#91ded4"
    ACCENT_COLOR="#1C7787"
fi

# Get resolution
RES=$(xrandr --query | grep " connected primary" | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
[ -z "$RES" ] && RES=$(xrandr --query | grep " connected" | head -1 | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
WIDTH=$(echo "$RES" | cut -d'x' -f1)
HEIGHT=$(echo "$RES" | cut -d'x' -f2)

# Generate splash image
SPLASH_IMG="$SPLASH_DIR/splash.png"
MAIN_FONT_SIZE=$((HEIGHT / 10))
SUB_FONT_SIZE=$((HEIGHT / 30))

echo "Generating splash image..."
magick -size "${WIDTH}x${HEIGHT}" "xc:${BG_COLOR}" \
    -gravity center \
    -font "$FONT" -pointsize "$MAIN_FONT_SIZE" -fill "$FG_COLOR" \
    -annotate +0-50 "HYDRIX" \
    -font "$FONT" -pointsize "$SUB_FONT_SIZE" -fill "$ACCENT_COLOR" \
    -annotate +0+80 "setting up workspaces..." \
    "$SPLASH_IMG"

echo "=== PHASE 1: Show splash ==="
feh --fullscreen --auto-zoom "$SPLASH_IMG" &
FEH_PID=$!
sleep 0.3

# Find the feh window and make it STICKY (appears on all workspaces)
echo "Making splash window sticky..."
SPLASH_WIN=$(xdotool search --pid $FEH_PID 2>/dev/null | head -1)
if [ -n "$SPLASH_WIN" ]; then
    # Use i3-msg to make window sticky and floating fullscreen
    i3-msg "[id=$SPLASH_WIN] floating enable, sticky enable, fullscreen enable" >/dev/null 2>&1
    echo "  Splash window $SPLASH_WIN is now sticky"
else
    echo "  WARNING: Could not find splash window"
fi

echo "=== PHASE 2: Disable physical input ==="
disable_input

echo "=== PHASE 3: Simulate xdotool operations ==="
echo "Input disabled. xdotool operations starting..."

# Store current workspace
CURRENT_WS=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused==true).name')
echo "Current workspace: $CURRENT_WS"

# Switch to workspace 3 and do something
echo "Switching to workspace 3..."
i3-msg "workspace 3" >/dev/null
echo "Now on WS3 - you should STILL only see the splash screen!"
echo "Pausing 3 seconds so you can verify..."
sleep 3

# Open a terminal using xdotool
echo "Opening terminal via i3-msg..."
i3-msg "exec alacritty" >/dev/null
echo "Terminal opened on WS3 - splash should still be covering it!"
sleep 1

# Type something in the terminal
echo "Typing in terminal..."
xdotool type --clearmodifiers "echo 'xdotool works while input disabled!'"
sleep 0.2
xdotool key Return
sleep 0.5

# Switch back to original workspace
echo "Switching back to workspace $CURRENT_WS..."
i3-msg "workspace $CURRENT_WS" >/dev/null
sleep 0.5

echo "=== PHASE 4: Complete ==="
echo "Test operations done. Splash will disappear in 2 seconds..."
sleep 2

# Kill splash (cleanup trap will handle the rest)
kill $FEH_PID 2>/dev/null || true

echo ""
echo "=== TEST COMPLETE ==="
echo "Check workspace 3 - there should be a terminal with the test message!"
