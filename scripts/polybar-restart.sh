#!/run/current-system/sw/bin/bash

LOCKFILE="/tmp/polybar-restart.lock"
LOGFILE="/tmp/polybar-restart.log"

echo "$(date): Polybar restart called" >> "$LOGFILE"

# Prefer Hydrix repo config, fallback to ~/.config (same pattern as load-display-config.sh)
HYDRIX_CONFIG="$HOME/Hydrix/configs/display-config.json"
FALLBACK_CONFIG="$HOME/.config/display-config.json"
if [ -f "$HYDRIX_CONFIG" ]; then
    CONFIG_FILE="$HYDRIX_CONFIG"
elif [ -f "$FALLBACK_CONFIG" ]; then
    CONFIG_FILE="$FALLBACK_CONFIG"
else
    echo "$(date): Config file not found at $HYDRIX_CONFIG or $FALLBACK_CONFIG" >> "$LOGFILE"
    CONFIG_FILE=""
fi

# Prefer Hydrix repo template, fallback to ~/.config
HYDRIX_TEMPLATE="$HOME/Hydrix/configs/polybar/config.ini.template"
FALLBACK_TEMPLATE="$HOME/.config/polybar/config.ini.template"
if [ -f "$HYDRIX_TEMPLATE" ]; then
    POLYBAR_TEMPLATE="$HYDRIX_TEMPLATE"
else
    POLYBAR_TEMPLATE="$FALLBACK_TEMPLATE"
fi

# Check if already running (with proper locking)
if ! mkdir "$LOCKFILE" 2>/dev/null; then
    echo "$(date): Already running, exiting" >> "$LOGFILE"
    exit 0
fi

# Ensure lockfile is removed on exit
trap "rmdir '$LOCKFILE' 2>/dev/null" EXIT

echo "$(date): Killing existing polybar instances" >> "$LOGFILE"
killall -q polybar 2>/dev/null

# Wait for them to die (max 2 seconds)
for i in {1..20}; do
    pgrep -u $UID -x polybar >/dev/null || break
    sleep 0.1
done

# Small delay to ensure clean state
sleep 0.2

# Load display config to get font settings (uses correct config path)
if [ -f "$HOME/Hydrix/scripts/load-display-config.sh" ]; then
    source "$HOME/Hydrix/scripts/load-display-config.sh"
else
    source ~/.config/scripts/load-display-config.sh
fi

# Launch polybar on each connected monitor
MONITORS=$(xrandr --query | grep " connected" | cut -d' ' -f1)
echo "$(date): Launching polybar on: $MONITORS" >> "$LOGFILE"

HOSTNAME=$(hostnamectl hostname | cut -d'-' -f1)

for monitor in $MONITORS; do
    # Get monitor resolution
    MONITOR_RES=$(xrandr --query | grep "^${monitor} connected" | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
    echo "$(date): Monitor $monitor resolution: $MONITOR_RES" >> "$LOGFILE"

    # Determine settings for this monitor (defaults from load-display-config.sh)
    MONITOR_POLYBAR_FONT_SIZE="$POLYBAR_FONT_SIZE"
    MONITOR_POLYBAR_HEIGHT="$POLYBAR_HEIGHT"
    MONITOR_POLYBAR_LINE_SIZE="$POLYBAR_LINE_SIZE"

    # Check for machine overrides (works for any machine, not just zen)
    MACHINE_OVERRIDE=$(jq -r ".machine_overrides[\"$HOSTNAME\"] // null" "$CONFIG_FILE")
    if [ "$MACHINE_OVERRIDE" != "null" ]; then
        # Check for external monitor patterns
        EXTERNAL_MONITOR_PATTERNS=$(echo "$MACHINE_OVERRIDE" | jq -r ".external_monitor_resolutions // [] | join(\"|\")")
        if [ -n "$EXTERNAL_MONITOR_PATTERNS" ] && echo "$MONITOR_RES" | grep -qE "^(${EXTERNAL_MONITOR_PATTERNS})$"; then
            # External monitor - use external settings if available
            EXT_FONT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_font_size_external // null")
            EXT_HEIGHT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_height_external // null")
            EXT_LINE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_line_size_external // null")
            [ "$EXT_FONT" != "null" ] && MONITOR_POLYBAR_FONT_SIZE="$EXT_FONT"
            [ "$EXT_HEIGHT" != "null" ] && MONITOR_POLYBAR_HEIGHT="$EXT_HEIGHT"
            [ "$EXT_LINE" != "null" ] && MONITOR_POLYBAR_LINE_SIZE="$EXT_LINE"
        else
            # Internal/default monitor - use machine override settings
            OVERRIDE_FONT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_font_size // null")
            OVERRIDE_HEIGHT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_height // null")
            OVERRIDE_LINE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_line_size // null")
            [ "$OVERRIDE_FONT" != "null" ] && MONITOR_POLYBAR_FONT_SIZE="$OVERRIDE_FONT"
            [ "$OVERRIDE_HEIGHT" != "null" ] && MONITOR_POLYBAR_HEIGHT="$OVERRIDE_HEIGHT"
            [ "$OVERRIDE_LINE" != "null" ] && MONITOR_POLYBAR_LINE_SIZE="$OVERRIDE_LINE"
        fi
    fi

    echo "$(date): Monitor $monitor using: font=$MONITOR_POLYBAR_FONT_SIZE height=$MONITOR_POLYBAR_HEIGHT line=$MONITOR_POLYBAR_LINE_SIZE" >> "$LOGFILE"

    # Generate monitor-specific config
    MONITOR_CONFIG="/tmp/polybar-${monitor}.ini"
    sed -e "s/\${POLYBAR_FONT_SIZE}/$MONITOR_POLYBAR_FONT_SIZE/g" \
        -e "s/\${POLYBAR_FONT}/$POLYBAR_FONT/g" \
        -e "s/\${POLYBAR_HEIGHT}/$MONITOR_POLYBAR_HEIGHT/g" \
        -e "s/\${POLYBAR_LINE_SIZE}/$MONITOR_POLYBAR_LINE_SIZE/g" \
        "$POLYBAR_TEMPLATE" > "$MONITOR_CONFIG"

    # Launch polybar on this monitor with its config
    echo "$(date): Launching polybar on $monitor with config $MONITOR_CONFIG" >> "$LOGFILE"
    MONITOR=$monitor polybar -q --config="$MONITOR_CONFIG" main &
done

echo "$(date): Polybar restart complete" >> "$LOGFILE"
