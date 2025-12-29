#!/run/current-system/sw/bin/bash

AUTOSTART_LOG="/tmp/autostart.log"
echo "$(date): ========== Autostart.sh invoked ==========" >> "$AUTOSTART_LOG"

# Prefer Hydrix repo config, fallback to ~/.config (same pattern as load-display-config.sh)
HYDRIX_CONFIG="$HOME/Hydrix/configs/display-config.json"
FALLBACK_CONFIG="$HOME/.config/display-config.json"
if [ -f "$HYDRIX_CONFIG" ]; then
    CONFIG_FILE="$HYDRIX_CONFIG"
elif [ -f "$FALLBACK_CONFIG" ]; then
    CONFIG_FILE="$FALLBACK_CONFIG"
else
    echo "$(date): Config file not found at $HYDRIX_CONFIG or $FALLBACK_CONFIG" >> "$AUTOSTART_LOG"
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

# Ensure dunst uses wal colors
mkdir -p ~/.config/dunst
ln -sf ~/.cache/wal/dunstrc ~/.config/dunst/dunstrc

# Note: We send a single consolidated notification at the end instead of multiple notifications

hostname=$(hostnamectl | grep "Icon name:" | cut -d ":" -f2 | xargs)

if [[ ! $hostname =~ [vV][mM] ]]; then
killall -q picom
while pgrep -u $UID -x picom >/dev/null; do sleep 1; done
picom -b
fi

# Configure external monitors (DP and HDMI)
# Give displays a moment to stabilize
sleep 0.5

INTERNAL_DISPLAY=$(xrandr --query | grep "eDP" | grep " connected" | cut -d' ' -f1)
EXTERNAL_DISPLAYS=$(xrandr --query | grep " connected" | grep -E "(DP-|HDMI-)" | cut -d' ' -f1)

echo "$(date): Internal: $INTERNAL_DISPLAY, External: $EXTERNAL_DISPLAYS" >> /tmp/autostart.log

if [ -n "$INTERNAL_DISPLAY" ] && [ -n "$EXTERNAL_DISPLAYS" ]; then
echo "$(date): Configuring display layout: external monitors above internal" >> /tmp/autostart.log
for external in $EXTERNAL_DISPLAYS; do
xrandr --output "$external" --auto --above "$INTERNAL_DISPLAY"
echo "$(date): Positioned $external above $INTERNAL_DISPLAY" >> /tmp/autostart.log
done

# Restore wallpaper after xrandr changes
sleep 0.5
wal -Rnq
~/.fehbg &
fi

# Source load-display-config from Hydrix first (avoid stale symlinks)
if [ -f "$HOME/Hydrix/scripts/load-display-config.sh" ]; then
    source "$HOME/Hydrix/scripts/load-display-config.sh"
else
    source ~/.config/scripts/load-display-config.sh
fi

AUTOSTART_LOG="/tmp/autostart.log"
echo "$(date): Autostart.sh starting" >> "$AUTOSTART_LOG"

killall -q polybar
while pgrep -u $UID -x polybar >/dev/null; do sleep 1; done

# Get all connected monitors
MONITORS=$(xrandr --query | grep " connected" | cut -d' ' -f1)
echo "$(date): Detected monitors: $MONITORS" >> "$AUTOSTART_LOG"

# Determine which bars to launch based on host vs VM
IS_VM=0
if [[ $hostname =~ [vV][mM] ]]; then
    IS_VM=1
fi

# Launch polybar on each monitor with appropriate config
for monitor in $MONITORS; do
    # Get monitor resolution
    MONITOR_RES=$(xrandr --query | grep "^${monitor} connected" | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
    echo "$(date): Monitor $monitor resolution: $MONITOR_RES" >> "$AUTOSTART_LOG"

    # Look up resolution-specific settings from display-config.json
    RES_DEFAULTS=$(jq -r ".resolution_defaults[\"$MONITOR_RES\"] // null" "$CONFIG_FILE")

    if [ "$RES_DEFAULTS" = "null" ]; then
        echo "$(date): No defaults found for $MONITOR_RES, using 1920x1080 defaults" >> "$AUTOSTART_LOG"
        RES_DEFAULTS=$(jq -r '.resolution_defaults["1920x1080"]' "$CONFIG_FILE")
    fi

    # Get resolution-specific polybar settings
    MONITOR_POLYBAR_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.polybar_font_size')
    MONITOR_POLYBAR_HEIGHT=$(echo "$RES_DEFAULTS" | jq -r '.polybar_height')
    MONITOR_POLYBAR_LINE_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.polybar_line_size')

    # Override with machine-specific settings if they exist
    HOSTNAME=$(hostnamectl hostname | cut -d'-' -f1)
    MACHINE_OVERRIDE=$(jq -r ".machine_overrides[\"$HOSTNAME\"] // null" "$CONFIG_FILE")

    if [ "$MACHINE_OVERRIDE" != "null" ]; then
        # Check for external monitor patterns (any machine can have these)
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
            # Use machine override settings (fallback to resolution defaults if not set)
            OVERRIDE_FONT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_font_size // null")
            OVERRIDE_HEIGHT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_height // null")
            OVERRIDE_LINE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_line_size // null")
            [ "$OVERRIDE_FONT" != "null" ] && MONITOR_POLYBAR_FONT_SIZE="$OVERRIDE_FONT"
            [ "$OVERRIDE_HEIGHT" != "null" ] && MONITOR_POLYBAR_HEIGHT="$OVERRIDE_HEIGHT"
            [ "$OVERRIDE_LINE" != "null" ] && MONITOR_POLYBAR_LINE_SIZE="$OVERRIDE_LINE"
        fi
    fi

    echo "$(date): Monitor $monitor using: font=$MONITOR_POLYBAR_FONT_SIZE height=$MONITOR_POLYBAR_HEIGHT line=$MONITOR_POLYBAR_LINE_SIZE" >> "$AUTOSTART_LOG"

    # Generate monitor-specific config
    MONITOR_CONFIG="/tmp/polybar-${monitor}.ini"
    sed -e "s/\${POLYBAR_FONT_SIZE}/$MONITOR_POLYBAR_FONT_SIZE/g" \
        -e "s/\${POLYBAR_FONT}/$POLYBAR_FONT/g" \
        -e "s/\${POLYBAR_HEIGHT}/$MONITOR_POLYBAR_HEIGHT/g" \
        -e "s/\${POLYBAR_LINE_SIZE}/$MONITOR_POLYBAR_LINE_SIZE/g" \
        "$POLYBAR_TEMPLATE" > "$MONITOR_CONFIG"

    if [ "$IS_VM" -eq 1 ]; then
        # VM: Launch both top and bottom bars
        echo "$(date): VM mode - launching top and bottom bars on $monitor" >> "$AUTOSTART_LOG"
        MONITOR=$monitor polybar -q --config="$MONITOR_CONFIG" main >> "$AUTOSTART_LOG" 2>&1 &
        MONITOR=$monitor polybar -q --config="$MONITOR_CONFIG" bottom >> "$AUTOSTART_LOG" 2>&1 &
    else
        # Host: Launch only top bar (sticky, overrides VM windows)
        echo "$(date): Host mode - launching top bar on $monitor" >> "$AUTOSTART_LOG"
        MONITOR=$monitor polybar -q --config="$MONITOR_CONFIG" main >> "$AUTOSTART_LOG" 2>&1 &
    fi
done

# Auto-start VMs on designated workspaces and build final notification (host only)
if [[ ! $hostname =~ [vV][mM] ]]; then
    EXTERNAL_MONITOR=$(xrandr --query | grep " connected" | grep -E "(DP-|HDMI-)" | cut -d' ' -f1 | head -n1)
    MONITOR_INFO=""
    if [ -n "$EXTERNAL_MONITOR" ]; then
        MONITOR_INFO="External: $EXTERNAL_MONITOR (WS 2-5)\n"
    else
        MONITOR_INFO="No external monitor\n"
    fi

    if [ -x "$HOME/Hydrix/scripts/vm-autostart.sh" ]; then
        echo "$(date): Starting VM autostart..." >> "$AUTOSTART_LOG"
        # Run VM autostart and capture output for notification
        (
            sleep 5
            VM_OUTPUT=$("$HOME/Hydrix/scripts/vm-autostart.sh" 2>&1)
            echo "$VM_OUTPUT" >> "$AUTOSTART_LOG"

            # Parse VM output for notification
            PLACED=$(echo "$VM_OUTPUT" | grep "VMs placed" | grep -oE "[0-9]+" | head -n1)
            CONFLICTS=$(echo "$VM_OUTPUT" | grep -A 20 "Conflict:" | grep -E "^\s+\w+" || true)

            if [ -n "$CONFLICTS" ]; then
                notify-send -u normal "Hydrix Setup Complete" "${MONITOR_INFO}VMs placed: ${PLACED:-0}\nDuplicate VMs detected:\n$CONFLICTS" -t 8000
            else
                notify-send "Hydrix Setup Complete" "${MONITOR_INFO}VMs placed: ${PLACED:-0}" -t 4000
            fi
        ) &
    else
        notify-send "Hydrix Setup Complete" "${MONITOR_INFO}No VM autostart script found" -t 4000
    fi
else
    # VM notification
    notify-send "VM Display Ready" "Top + bottom bars active" -t 2000
fi

echo "$(date): Autostart completed... Resolution: $DISPLAY_RESOLUTION, Polybar font: $POLYBAR_FONT_SIZE" >> "$AUTOSTART_LOG"
