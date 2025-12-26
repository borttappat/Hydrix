#!/usr/bin/env bash
# load-display-config.sh - Load display settings based on resolution
#
# Logic:
#   1. If external monitor detected → use resolution_defaults for that resolution
#   2. If internal only → use machine_overrides if present, else resolution_defaults
#   3. Fallback to 1920x1080 defaults if resolution not found

# Read directly from Hydrix repo so changes take effect without rebuild
# Falls back to ~/.config if repo not found (e.g., fresh VM before clone)
HYDRIX_CONFIG="$HOME/Hydrix/configs/display-config.json"
FALLBACK_CONFIG="$HOME/.config/display-config.json"

if [ -f "$HYDRIX_CONFIG" ]; then
    CONFIG_FILE="$HYDRIX_CONFIG"
elif [ -f "$FALLBACK_CONFIG" ]; then
    CONFIG_FILE="$FALLBACK_CONFIG"
else
    echo "Config file not found at $HYDRIX_CONFIG or $FALLBACK_CONFIG"
    exit 1
fi

HOSTNAME=$(hostnamectl hostname | cut -d'-' -f1)

# Detect all connected monitors and their resolutions
# xrandr --listmonitors format: "0: +*eDP-1 2880/302x1800/189+0+0  eDP-1"
# where format is: width/widthMM x height/heightMM + offset
get_external_resolution() {
    # Get all connected monitors except internal (eDP)
    local external_res
    external_res=$(xrandr --listmonitors 2>/dev/null | grep -v "eDP" | grep -v "^Monitors:" | sed 's|.* \([0-9]*\)/[0-9]*x\([0-9]*\)/.*|\1x\2|' | head -n1)
    echo "$external_res"
}

get_internal_resolution() {
    # Get internal display resolution (eDP)
    local internal_res
    internal_res=$(xrandr --listmonitors 2>/dev/null | grep "eDP" | sed 's|.* \([0-9]*\)/[0-9]*x\([0-9]*\)/.*|\1x\2|' | head -n1)
    echo "$internal_res"
}

# Check if external monitor is connected
EXTERNAL_RES=$(get_external_resolution)
INTERNAL_RES=$(get_internal_resolution)
EXTERNAL_MONITOR=0

if [ -n "$EXTERNAL_RES" ]; then
    EXTERNAL_MONITOR=1
    CURRENT_RESOLUTION="$EXTERNAL_RES"
    echo "External monitor detected: $EXTERNAL_RES"
elif [ -n "$INTERNAL_RES" ]; then
    CURRENT_RESOLUTION="$INTERNAL_RES"
    echo "Internal display only: $INTERNAL_RES"
else
    # Fallback - try to detect any resolution
    CURRENT_RESOLUTION=$(xrandr --listmonitors | awk '/\+\*/ {gsub(/\/[0-9]+/, "", $3); print $3}' | grep -oP '[0-9]{3,5}x[0-9]{3,5}' | head -n1)
    echo "Fallback resolution detection: $CURRENT_RESOLUTION"
fi

# Initialize all exports to null
init_exports() {
    export POLYBAR_FONT_SIZE="null"
    export POLYBAR_HEIGHT="null"
    export POLYBAR_LINE_SIZE="null"
    export ALACRITTY_FONT_SIZE="null"
    export I3_FONT_SIZE="null"
    export I3_BORDER_THICKNESS="null"
    export GAPS_INNER="null"
    export ROFI_FONT_SIZE="null"
    export ALACRITTY_SCALE_FACTOR="null"
    export DUNST_FONT_SIZE="null"
    export DUNST_WIDTH="null"
    export DUNST_HEIGHT="null"
    export DUNST_OFFSET_X="null"
    export DUNST_OFFSET_Y="null"
    export DUNST_PADDING="null"
    export DUNST_FRAME_WIDTH="null"
    export DUNST_ICON_SIZE="null"
    export FIREFOX_FONT_SIZE="null"
    export FIREFOX_HEADER_FONT_SIZE="null"
    export OBSIDIAN_FONT_SIZE="null"
    export OBSIDIAN_HEADER_FONT_SIZE="null"
}

init_exports

# Apply machine overrides ONLY if no external monitor
if [ "$EXTERNAL_MONITOR" -eq 0 ]; then
    MACHINE_OVERRIDE=$(jq -r ".machine_overrides[\"$HOSTNAME\"] // null" "$CONFIG_FILE")

    if [ "$MACHINE_OVERRIDE" != "null" ]; then
        echo "Applying machine overrides for: $HOSTNAME"

        # Apply forced resolution if set
        FORCED_RES=$(echo "$MACHINE_OVERRIDE" | jq -r '.force_resolution // "null"')
        FORCED_DPI=$(echo "$MACHINE_OVERRIDE" | jq -r '.dpi // "null"')
        FORCED_GDK_SCALE=$(echo "$MACHINE_OVERRIDE" | jq -r '.gdk_scale // "null"')

        if [ "$FORCED_RES" != "null" ]; then
            CURRENT_RESOLUTION="$FORCED_RES"
            INTERNAL_DISPLAY=$(xrandr | grep "eDP" | cut -d' ' -f1 | head -n1)
            if [ -n "$INTERNAL_DISPLAY" ]; then
                if [ "$FORCED_DPI" != "null" ]; then
                    xrandr --output "$INTERNAL_DISPLAY" --mode "$FORCED_RES" --dpi "$FORCED_DPI" 2>/dev/null || echo "Warning: Could not set resolution to $FORCED_RES"
                else
                    xrandr --output "$INTERNAL_DISPLAY" --mode "$FORCED_RES" 2>/dev/null || echo "Warning: Could not set resolution to $FORCED_RES"
                fi
            fi
        fi

        # Apply DPI scaling for HiDPI displays
        if [ "$FORCED_DPI" != "null" ]; then
            echo "Xft.dpi: $FORCED_DPI" | xrdb -merge
        fi

        # Apply GTK/Qt scaling
        if [ "$FORCED_GDK_SCALE" != "null" ]; then
            export GDK_SCALE="$FORCED_GDK_SCALE"
            export QT_AUTO_SCREEN_SCALE_FACTOR=1
        fi

        # Load machine-specific display settings
        export POLYBAR_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_font_size // null")
        export POLYBAR_HEIGHT=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_height // null")
        export POLYBAR_LINE_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".polybar_line_size // null")
        export ALACRITTY_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".alacritty_font_size // null")
        export I3_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".i3_font_size // null")
        export I3_BORDER_THICKNESS=$(echo "$MACHINE_OVERRIDE" | jq -r ".i3_border_thickness // null")
        export GAPS_INNER=$(echo "$MACHINE_OVERRIDE" | jq -r ".gaps_inner // null")
        export ROFI_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".rofi_font_size // null")
        export ALACRITTY_SCALE_FACTOR=$(echo "$MACHINE_OVERRIDE" | jq -r ".alacritty_scale_factor // null")
        export DUNST_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".dunst_font_size // null")
        export DUNST_WIDTH=$(echo "$MACHINE_OVERRIDE" | jq -r ".dunst_width // null")
        export DUNST_HEIGHT=$(echo "$MACHINE_OVERRIDE" | jq -r ".dunst_height // null")
        export DUNST_OFFSET_X=$(echo "$MACHINE_OVERRIDE" | jq -r ".dunst_offset_x // null")
        export DUNST_OFFSET_Y=$(echo "$MACHINE_OVERRIDE" | jq -r ".dunst_offset_y // null")
        export DUNST_PADDING=$(echo "$MACHINE_OVERRIDE" | jq -r ".dunst_padding // null")
        export DUNST_FRAME_WIDTH=$(echo "$MACHINE_OVERRIDE" | jq -r ".dunst_frame_width // null")
        export DUNST_ICON_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".dunst_icon_size // null")
        export FIREFOX_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".firefox_font_size // null")
        export FIREFOX_HEADER_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".firefox_header_font_size // null")
        export OBSIDIAN_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".obsidian_font_size // null")
        export OBSIDIAN_HEADER_FONT_SIZE=$(echo "$MACHINE_OVERRIDE" | jq -r ".obsidian_header_font_size // null")
    fi
fi

# Get resolution defaults - always fallback to these for any "null" values
RES_DEFAULTS=$(jq -r ".resolution_defaults[\"$CURRENT_RESOLUTION\"] // null" "$CONFIG_FILE")

if [ "$RES_DEFAULTS" = "null" ]; then
    echo "No defaults found for resolution: $CURRENT_RESOLUTION, using 1920x1080 defaults"
    RES_DEFAULTS=$(jq -r '.resolution_defaults["1920x1080"]' "$CONFIG_FILE")
fi

# Fill in any remaining null values from resolution defaults
[ "$POLYBAR_FONT_SIZE" = "null" ] && export POLYBAR_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.polybar_font_size')
[ "$POLYBAR_HEIGHT" = "null" ] && export POLYBAR_HEIGHT=$(echo "$RES_DEFAULTS" | jq -r '.polybar_height')
[ "$POLYBAR_LINE_SIZE" = "null" ] && export POLYBAR_LINE_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.polybar_line_size')
[ "$ALACRITTY_FONT_SIZE" = "null" ] && export ALACRITTY_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.alacritty_font_size')
[ "$I3_FONT_SIZE" = "null" ] && export I3_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.i3_font_size')
[ "$I3_BORDER_THICKNESS" = "null" ] && export I3_BORDER_THICKNESS=$(echo "$RES_DEFAULTS" | jq -r '.i3_border_thickness')
[ "$GAPS_INNER" = "null" ] && export GAPS_INNER=$(echo "$RES_DEFAULTS" | jq -r '.gaps_inner')
[ "$ROFI_FONT_SIZE" = "null" ] && export ROFI_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.rofi_font_size')

# Dunst settings
[ "$DUNST_FONT_SIZE" = "null" ] && export DUNST_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.dunst_font_size')
[ "$DUNST_WIDTH" = "null" ] && export DUNST_WIDTH=$(echo "$RES_DEFAULTS" | jq -r '.dunst_width')
[ "$DUNST_HEIGHT" = "null" ] && export DUNST_HEIGHT=$(echo "$RES_DEFAULTS" | jq -r '.dunst_height')
[ "$DUNST_OFFSET_X" = "null" ] && export DUNST_OFFSET_X=$(echo "$RES_DEFAULTS" | jq -r '.dunst_offset_x')
[ "$DUNST_OFFSET_Y" = "null" ] && export DUNST_OFFSET_Y=$(echo "$RES_DEFAULTS" | jq -r '.dunst_offset_y')
[ "$DUNST_PADDING" = "null" ] && export DUNST_PADDING=$(echo "$RES_DEFAULTS" | jq -r '.dunst_padding')
[ "$DUNST_FRAME_WIDTH" = "null" ] && export DUNST_FRAME_WIDTH=$(echo "$RES_DEFAULTS" | jq -r '.dunst_frame_width')
[ "$DUNST_ICON_SIZE" = "null" ] && export DUNST_ICON_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.dunst_icon_size')

# Firefox settings
[ "$FIREFOX_FONT_SIZE" = "null" ] && export FIREFOX_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.firefox_font_size')
[ "$FIREFOX_HEADER_FONT_SIZE" = "null" ] && export FIREFOX_HEADER_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.firefox_header_font_size')

# Obsidian settings
[ "$OBSIDIAN_FONT_SIZE" = "null" ] && export OBSIDIAN_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.obsidian_font_size')
[ "$OBSIDIAN_HEADER_FONT_SIZE" = "null" ] && export OBSIDIAN_HEADER_FONT_SIZE=$(echo "$RES_DEFAULTS" | jq -r '.obsidian_header_font_size')

# Alacritty scale factor defaults to 1.0 if not set
[ "$ALACRITTY_SCALE_FACTOR" = "null" ] && export ALACRITTY_SCALE_FACTOR="1.0"

export DISPLAY_RESOLUTION="$CURRENT_RESOLUTION"

# Font exports - use per-app fonts with fallback to default
DEFAULT_FONT=$(jq -r '.fonts.default' "$CONFIG_FILE")
export POLYBAR_FONT="$DEFAULT_FONT"
export ALACRITTY_FONT="$DEFAULT_FONT"
export I3_FONT="$DEFAULT_FONT"
export ROFI_FONT="$DEFAULT_FONT"
export DUNST_FONT=$(jq -r '.fonts.dunst // .fonts.default' "$CONFIG_FILE")
export FIREFOX_FONT=$(jq -r '.fonts.firefox // .fonts.default' "$CONFIG_FILE")
export OBSIDIAN_FONT=$(jq -r '.fonts.obsidian // .fonts.default' "$CONFIG_FILE")

# Generate the WINIT_X11_SCALE_FACTOR line for alacritty if scale factor is set
if [ "$ALACRITTY_SCALE_FACTOR" != "null" ] && [ "$ALACRITTY_SCALE_FACTOR" != "1" ] && [ "$ALACRITTY_SCALE_FACTOR" != "1.0" ]; then
    export ALACRITTY_SCALE_FACTOR_LINE="WINIT_X11_SCALE_FACTOR = \"$ALACRITTY_SCALE_FACTOR\""
else
    export ALACRITTY_SCALE_FACTOR_LINE=""
fi

echo "Loaded config for $HOSTNAME @ $DISPLAY_RESOLUTION: polybar=$POLYBAR_FONT_SIZE alacritty=$ALACRITTY_FONT_SIZE (scale=$ALACRITTY_SCALE_FACTOR) i3=$I3_FONT_SIZE gaps=$GAPS_INNER font=$POLYBAR_FONT external=$EXTERNAL_MONITOR"
