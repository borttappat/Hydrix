#!/usr/bin/env bash
# Simple test for splash cover - displays for 5 seconds then exits

set -x  # Debug mode - show all commands

SPLASH_DIR="/tmp/splash-test"
CONFIG_FILE="$HOME/Hydrix/configs/display-config.json"
mkdir -p "$SPLASH_DIR"

# Get font from display-config.json
if [ -f "$CONFIG_FILE" ]; then
    # Read the default font, use CozetteVector for ImageMagick compatibility
    FONT_BASE=$(jq -r '.fonts.default // "cozette"' "$CONFIG_FILE")
    # Map common names to ImageMagick-compatible names
    case "$FONT_BASE" in
        cozette|Cozette) FONT="CozetteVector" ;;
        *) FONT="$FONT_BASE" ;;
    esac
else
    FONT="CozetteVector"
fi

echo "Using font: $FONT"

# Get colors from pywal cache (or use defaults)
if [ -f ~/.cache/wal/colors.json ]; then
    BG_COLOR=$(jq -r '.special.background // .colors.color0' ~/.cache/wal/colors.json)
    FG_COLOR=$(jq -r '.special.foreground // .colors.color7' ~/.cache/wal/colors.json)
    ACCENT_COLOR=$(jq -r '.colors.color4' ~/.cache/wal/colors.json)
else
    BG_COLOR="#0B0E1B"
    FG_COLOR="#91ded4"
    ACCENT_COLOR="#1C7787"
fi

echo "Colors: bg=$BG_COLOR fg=$FG_COLOR accent=$ACCENT_COLOR"

# Get primary monitor resolution
RES=$(xrandr --query | grep " connected primary" | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
if [ -z "$RES" ]; then
    RES=$(xrandr --query | grep " connected" | head -1 | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
fi
echo "Resolution: $RES"

WIDTH=$(echo "$RES" | cut -d'x' -f1)
HEIGHT=$(echo "$RES" | cut -d'x' -f2)

# Calculate font sizes based on resolution
MAIN_FONT_SIZE=$((HEIGHT / 10))
SUB_FONT_SIZE=$((HEIGHT / 30))

echo "Font sizes: main=$MAIN_FONT_SIZE sub=$SUB_FONT_SIZE"

# Generate splash image
SPLASH_IMG="$SPLASH_DIR/test-splash.png"

echo "Generating image at $SPLASH_IMG..."

# Use magick (ImageMagick v7) with the font from config
magick -size "${WIDTH}x${HEIGHT}" "xc:${BG_COLOR}" \
    -gravity center \
    -font "$FONT" -pointsize "$MAIN_FONT_SIZE" -fill "$FG_COLOR" \
    -annotate +0-50 "HYDRIX" \
    -font "$FONT" -pointsize "$SUB_FONT_SIZE" -fill "$ACCENT_COLOR" \
    -annotate +0+80 "test splash - closes in 5 seconds" \
    "$SPLASH_IMG"

if [ ! -f "$SPLASH_IMG" ]; then
    echo "ERROR: Failed to generate image"
    exit 1
fi

echo "Image generated: $(ls -la "$SPLASH_IMG")"

# Display with feh
echo "Launching feh..."
feh --fullscreen --auto-zoom "$SPLASH_IMG" &
FEH_PID=$!
echo "feh PID: $FEH_PID"

# Wait for window to appear, then make it click-through
sleep 0.5
WINDOW_ID=$(xdotool search --pid $FEH_PID 2>/dev/null | head -1)
if [ -n "$WINDOW_ID" ]; then
    echo "Making window $WINDOW_ID click-through..."
    "$HOME/Hydrix/scripts/make-click-through.py" "$WINDOW_ID" || echo "Click-through failed (python-xlib may not be installed)"
else
    echo "Could not find feh window"
fi

# Wait 5 seconds then kill
echo "Try clicking behind the splash - it should pass through!"
sleep 5
echo "Killing feh..."
kill $FEH_PID 2>/dev/null || true

# Cleanup
rm -rf "$SPLASH_DIR"
echo "Done!"
