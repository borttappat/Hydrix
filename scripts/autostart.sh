#!/run/current-system/sw/bin/bash

AUTOSTART_LOG="/tmp/autostart.log"
echo "$(date): ========== Autostart.sh invoked ==========" >> "$AUTOSTART_LOG"

# Ensure dunst uses wal colors
mkdir -p ~/.config/dunst
ln -sf ~/.cache/wal/dunstrc ~/.config/dunst/dunstrc

# Notify user that display configuration is starting
notify-send "Display Setup" "Configuring monitors..." -t 2000

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

source ~/.config/scripts/load-display-config.sh

AUTOSTART_LOG="/tmp/autostart.log"
echo "$(date): Autostart.sh starting" >> "$AUTOSTART_LOG"

killall -q polybar
while pgrep -u $UID -x polybar >/dev/null; do sleep 1; done

# Get all connected monitors
MONITORS=$(xrandr --query | grep " connected" | cut -d' ' -f1)
echo "$(date): Detected monitors: $MONITORS" >> "$AUTOSTART_LOG"

# Launch polybar on each monitor with appropriate config
for monitor in $MONITORS; do
    # Get monitor resolution
    MONITOR_RES=$(xrandr --query | grep "^${monitor} connected" | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
    echo "$(date): Monitor $monitor resolution: $MONITOR_RES" >> "$AUTOSTART_LOG"

    # Look up resolution-specific settings from display-config.json
    RES_DEFAULTS=$(jq -r ".resolution_defaults[\"$MONITOR_RES\"] // null" ~/.config/display-config.json)

    if [ "$RES_DEFAULTS" = "null" ]; then
        echo "$(date): No defaults found for $MONITOR_RES, using 1920x1080 defaults" >> "$AUTOSTART_LOG"
        RES_DEFAULTS=$(jq -r '.resolution_defaults["1920x1080"]' ~/.config/display-config.json)
    fi

    # Get resolution-specific polybar settings
    MONITOR_POLYBAR_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.polybar_font_size')
    MONITOR_POLYBAR_HEIGHT=$(echo "$RES_DEFAULTS" | jq -r '.polybar_height')
    MONITOR_POLYBAR_LINE_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.polybar_line_size')

    # Override with machine-specific settings if they exist
    HOSTNAME=$(hostnamectl hostname | cut -d'-' -f1)
    MACHINE_OVERRIDE=$(jq -r ".machine_overrides[\"$HOSTNAME\"] // null" ~/.config/display-config.json)

    if [ "$MACHINE_OVERRIDE" != "null" ]; then
        # Check for zen external monitor patterns
        if [ "$HOSTNAME" = "zen" ]; then
            EXTERNAL_MONITOR_PATTERNS=$(echo "$MACHINE_OVERRIDE" | jq -r ".external_monitor_resolutions // [] | join(\"|\")")
            if [ -n "$EXTERNAL_MONITOR_PATTERNS" ] && echo "$MONITOR_RES" | grep -qE "^(${EXTERNAL_MONITOR_PATTERNS})x"; then
                # External monitor - use external settings if available
                MONITOR_POLYBAR_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_font_size_external // .polybar_font_size // $MONITOR_POLYBAR_FONT_SIZE")
                MONITOR_POLYBAR_HEIGHT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_height_external // .polybar_height // $MONITOR_POLYBAR_HEIGHT")
                MONITOR_POLYBAR_LINE_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_line_size_external // .polybar_line_size // $MONITOR_POLYBAR_LINE_SIZE")
            else
                # Use machine override settings
                MONITOR_POLYBAR_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_font_size // $MONITOR_POLYBAR_FONT_SIZE")
                MONITOR_POLYBAR_HEIGHT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_height // $MONITOR_POLYBAR_HEIGHT")
                MONITOR_POLYBAR_LINE_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_line_size // $MONITOR_POLYBAR_LINE_SIZE")
            fi
        fi
    fi

    echo "$(date): Monitor $monitor using: font=$MONITOR_POLYBAR_FONT_SIZE height=$MONITOR_POLYBAR_HEIGHT line=$MONITOR_POLYBAR_LINE_SIZE" >> "$AUTOSTART_LOG"

    # Generate monitor-specific config
    MONITOR_CONFIG="/tmp/polybar-${monitor}.ini"
    sed -e "s/\${POLYBAR_FONT_SIZE}/$MONITOR_POLYBAR_FONT_SIZE/g" \
        -e "s/\${POLYBAR_FONT}/$POLYBAR_FONT/g" \
        -e "s/\${POLYBAR_HEIGHT}/$MONITOR_POLYBAR_HEIGHT/g" \
        -e "s/\${POLYBAR_LINE_SIZE}/$MONITOR_POLYBAR_LINE_SIZE/g" \
        ~/.config/polybar/config.ini.template > "$MONITOR_CONFIG"

    # Launch polybar on this monitor with its config
    echo "$(date): Launching polybar on $monitor with config $MONITOR_CONFIG" >> "$AUTOSTART_LOG"
    MONITOR=$monitor polybar -q --config="$MONITOR_CONFIG" main >> "$AUTOSTART_LOG" 2>&1 &
done

notify-send "Display Setup" "Configuration complete!" -t 2000

echo "$(date): Autostart completed... Resolution: $DISPLAY_RESOLUTION, Polybar font: $POLYBAR_FONT_SIZE" >> "$AUTOSTART_LOG"
