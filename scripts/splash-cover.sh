#!/usr/bin/env bash
# Splash cover for X session startup
# Shows fullscreen splash on all workspaces and disables physical input
# xdotool/i3-msg synthetic events still work while input is disabled
#
# Usage: splash-cover.sh [--kill]
#   --kill: Re-enable input and kill splash (called by vm-autostart.sh when done)
#
# Files created:
#   /tmp/splash-cover.pid - PID of this script
#   /tmp/splash-cover-feh.pid - PID of feh process
#   /tmp/splash-cover-devices.txt - Input device IDs to re-enable

SPLASH_DIR="/tmp/splash-cover"
SPLASH_PID_FILE="/tmp/splash-cover.pid"
FEH_PID_FILE="/tmp/splash-cover-feh.pid"
INPUT_DEVICES_FILE="/tmp/splash-cover-devices.txt"
SPLASH_LOG="/tmp/splash-cover.log"
CONFIG_FILE="$HOME/Hydrix/configs/display-config.json"

log() {
    echo "$(date '+%H:%M:%S') $*" >> "$SPLASH_LOG"
    echo "$*"
}

# Kill mode - re-enable input and kill splash
if [ "$1" = "--kill" ]; then
    log "=== Splash cover kill requested ==="

    # Re-enable input devices
    if [ -f "$INPUT_DEVICES_FILE" ]; then
        log "Re-enabling input devices..."
        while read -r id; do
            xinput enable "$id" 2>/dev/null && log "  Enabled device $id"
        done < "$INPUT_DEVICES_FILE"
        rm -f "$INPUT_DEVICES_FILE"
    fi

    # Kill feh
    if [ -f "$FEH_PID_FILE" ]; then
        FEH_PID=$(cat "$FEH_PID_FILE")
        kill "$FEH_PID" 2>/dev/null && log "Killed feh (PID: $FEH_PID)"
        rm -f "$FEH_PID_FILE"
    fi

    # Kill main process
    if [ -f "$SPLASH_PID_FILE" ]; then
        SPLASH_PID=$(cat "$SPLASH_PID_FILE")
        kill "$SPLASH_PID" 2>/dev/null
        rm -f "$SPLASH_PID_FILE"
    fi

    # Cleanup
    rm -rf "$SPLASH_DIR" 2>/dev/null
    pkill -f "feh.*splash-cover" 2>/dev/null

    log "Splash cover terminated"
    exit 0
fi

# Normal mode - show splash and disable input
log "=== Splash cover starting ==="

# Save our PID
echo $$ > "$SPLASH_PID_FILE"

# Create temp directory
mkdir -p "$SPLASH_DIR"

# Store input device IDs BEFORE disabling
log "Storing input device IDs..."
xinput list | grep -E "slave\s+(keyboard|pointer)" | grep -v "XTEST" | grep -oP 'id=\K[0-9]+' > "$INPUT_DEVICES_FILE"

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
log "Using font: $FONT"

# Get colors from pywal cache
if [ -f ~/.cache/wal/colors.json ]; then
    BG_COLOR=$(jq -r '.special.background // .colors.color0' ~/.cache/wal/colors.json)
    FG_COLOR=$(jq -r '.special.foreground // .colors.color7' ~/.cache/wal/colors.json)
    ACCENT_COLOR=$(jq -r '.colors.color4' ~/.cache/wal/colors.json)
else
    BG_COLOR="#0B0E1B"
    FG_COLOR="#91ded4"
    ACCENT_COLOR="#1C7787"
fi
log "Colors: bg=$BG_COLOR fg=$FG_COLOR"

# Wait for X to be ready
sleep 0.3

# Get primary monitor resolution
RES=$(xrandr --query 2>/dev/null | grep " connected primary" | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
[ -z "$RES" ] && RES=$(xrandr --query 2>/dev/null | grep " connected" | head -1 | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
[ -z "$RES" ] && RES="1920x1080"

WIDTH=$(echo "$RES" | cut -d'x' -f1)
HEIGHT=$(echo "$RES" | cut -d'x' -f2)
log "Resolution: ${WIDTH}x${HEIGHT}"

# Calculate font sizes
MAIN_FONT_SIZE=$((HEIGHT / 10))
SUB_FONT_SIZE=$((HEIGHT / 30))

# Generate splash image
SPLASH_IMG="$SPLASH_DIR/splash.png"
log "Generating splash image..."

magick -size "${WIDTH}x${HEIGHT}" "xc:${BG_COLOR}" \
    -gravity center \
    -font "$FONT" -pointsize "$MAIN_FONT_SIZE" -fill "$FG_COLOR" \
    -annotate +0-50 "HYDRIX" \
    -font "$FONT" -pointsize "$SUB_FONT_SIZE" -fill "$ACCENT_COLOR" \
    -annotate +0+80 "initializing..." \
    "$SPLASH_IMG" 2>/dev/null

if [ ! -f "$SPLASH_IMG" ]; then
    log "ERROR: Failed to generate splash image"
    rm -f "$SPLASH_PID_FILE" "$INPUT_DEVICES_FILE"
    exit 1
fi

# Launch feh fullscreen
log "Launching splash..."
feh --fullscreen --auto-zoom "$SPLASH_IMG" &
FEH_PID=$!
echo "$FEH_PID" > "$FEH_PID_FILE"
sleep 0.3

# Make splash window sticky (appears on all workspaces)
SPLASH_WIN=$(xdotool search --pid $FEH_PID 2>/dev/null | head -1)
if [ -n "$SPLASH_WIN" ]; then
    i3-msg "[id=$SPLASH_WIN] floating enable, sticky enable, fullscreen enable" >/dev/null 2>&1
    log "Splash window $SPLASH_WIN made sticky"
else
    log "WARNING: Could not find splash window to make sticky"
fi

# INPUT BLOCKING DISABLED - uncomment when splash-per-workspace is implemented
# Disabling input before i3 is fully running causes lockups
# log "Disabling physical input..."
# while read -r id; do
#     xinput disable "$id" 2>/dev/null && log "  Disabled device $id"
# done < "$INPUT_DEVICES_FILE"

log "Splash cover active. Call with --kill to terminate."

# Keep running in background (will be killed by vm-autostart.sh)
# Wait for feh to exit (either killed or closed)
wait $FEH_PID 2>/dev/null

# If we get here, feh was killed - make sure to re-enable input
log "Feh exited, ensuring input is re-enabled..."
if [ -f "$INPUT_DEVICES_FILE" ]; then
    while read -r id; do
        xinput enable "$id" 2>/dev/null
    done < "$INPUT_DEVICES_FILE"
    rm -f "$INPUT_DEVICES_FILE"
fi

rm -f "$SPLASH_PID_FILE" "$FEH_PID_FILE"
rm -rf "$SPLASH_DIR"
log "Splash cover exited"
