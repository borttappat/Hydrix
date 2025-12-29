#!/run/current-system/sw/bin/bash
unclutter -grab &

find "$HOME" -maxdepth 1 -name ".serverauth.*" -type f -mtime +2 -delete 2>/dev/null

hostname=$(hostnamectl | grep "Icon name:" | cut -d ":" -f2 | xargs)

# Prefer Hydrix repo paths for templates (changes take effect without rebuild)
# Falls back to ~/.config/ for VMs before they clone the repo
HYDRIX_CONFIGS="$HOME/Hydrix/configs"
if [ -d "$HYDRIX_CONFIGS" ]; then
    TEMPLATE_BASE="$HYDRIX_CONFIGS"
else
    TEMPLATE_BASE="$HOME/.config"
fi

# Ensure color cache exists before starting X (both VM and host)
if [ ! -f ~/.cache/wal/.static-colors-generated ]; then
    echo "Generating color cache..."
    # Check if custom colorscheme is set
    if [ -f ~/.cache/wal/.static-colors-type ] && grep -q "CUSTOM_SCHEME" ~/.cache/wal/.static-colors-type; then
        SCHEME_FILE=$(grep "CUSTOM_SCHEME" ~/.cache/wal/.static-colors-type | cut -d'=' -f2)
        apply-colorscheme "$SCHEME_FILE"
    else
        if [[ $hostname =~ [vV][mM] ]]; then
            # Use VM type from hostname
            VM_TYPE=$(echo "$hostname" | grep -oE "(pentest|comms|browsing|dev)" | head -n1)
            [ -z "$VM_TYPE" ] && VM_TYPE="browsing"
            vm-static-colors "$VM_TYPE"
        else
            # Host mode - use default host colors
            vm-static-colors "host"
        fi
    fi
fi

if [[ $hostname =~ [vV][mM] ]]; then
    # VM-specific setup
    spice-vdagent -x &
    VM_DISPLAY=$(xrandr | grep -E "(Virtual-1|qxl-0)" | grep " connected" | cut -d' ' -f1 | head -n1)
    if [ -n "$VM_DISPLAY" ]; then
        xrandr --output "$VM_DISPLAY" --mode 1920x1200 2>/dev/null || true
    fi
    export MOD_KEY="Mod1"

    # Auto-resize is now handled by udev rule in modules/vm/auto-resize.nix
    # The udev rule triggers on DRM changes and applies xrandr automatically
    # Keeping polling script commented out as fallback:
    # if [ -x "$HOME/Hydrix/scripts/vm-auto-resize.sh" ]; then
    #     "$HOME/Hydrix/scripts/vm-auto-resize.sh" &
    # fi
else
    export MOD_KEY="Mod4"
    # Resolution will be set by load-display-config.sh based on machine overrides
fi

# Restore pywal colors (now guaranteed to exist)
wal -Rn &

sleep 0.5

# Source load-display-config from Hydrix or fallback to ~/.config
if [ -f "$HOME/Hydrix/scripts/load-display-config.sh" ]; then
    source "$HOME/Hydrix/scripts/load-display-config.sh"
else
    source ~/.config/scripts/load-display-config.sh
fi

# Detect monitors for workspace output assignments
# Wait for external monitors to be detected (up to 3 seconds)
INTERNAL_OUTPUT=""
EXTERNAL_OUTPUT=""
for i in 1 2 3 4 5 6; do
    INTERNAL_OUTPUT=$(xrandr --query | grep "eDP" | grep " connected" | cut -d' ' -f1)
    EXTERNAL_OUTPUT=$(xrandr --query | grep " connected" | grep -E "(DP-|HDMI-)" | cut -d' ' -f1 | head -n1)
    if [ -n "$EXTERNAL_OUTPUT" ]; then
        break
    fi
    sleep 0.5
done

# If no external monitor, use internal for all workspaces
if [ -z "$EXTERNAL_OUTPUT" ]; then
    EXTERNAL_OUTPUT="$INTERNAL_OUTPUT"
fi
# If no internal (desktop?), use external for all
if [ -z "$INTERNAL_OUTPUT" ]; then
    INTERNAL_OUTPUT="$EXTERNAL_OUTPUT"
fi

# Process templates from Hydrix repo (or ~/.config as fallback)
# Output always goes to ~/.config/ for app compatibility
sed -e "s/\${MOD_KEY}/$MOD_KEY/g" \
    -e "s/\${I3_FONT}/$I3_FONT/g" \
    -e "s/\${I3_FONT_SIZE}/$I3_FONT_SIZE/g" \
    -e "s/\${I3_BORDER_THICKNESS}/$I3_BORDER_THICKNESS/g" \
    -e "s/\${GAPS_INNER}/$GAPS_INNER/g" \
    -e "s/\${INTERNAL_OUTPUT}/$INTERNAL_OUTPUT/g" \
    -e "s/\${EXTERNAL_OUTPUT}/$EXTERNAL_OUTPUT/g" \
    "$TEMPLATE_BASE/i3/config.template" > ~/.config/i3/config
sed -e "s/\${POLYBAR_FONT_SIZE}/$POLYBAR_FONT_SIZE/g" \
    -e "s/\${POLYBAR_FONT}/$POLYBAR_FONT/g" \
    -e "s/\${POLYBAR_HEIGHT}/$POLYBAR_HEIGHT/g" \
    -e "s/\${POLYBAR_LINE_SIZE}/$POLYBAR_LINE_SIZE/g" \
    "$TEMPLATE_BASE/polybar/config.ini.template" > ~/.config/polybar/config.ini
sed -e "s/\${ALACRITTY_FONT_SIZE}/$ALACRITTY_FONT_SIZE/g" \
    -e "s/\${ALACRITTY_FONT}/$ALACRITTY_FONT/g" \
    -e "s/\${ALACRITTY_SCALE_FACTOR_LINE}/$ALACRITTY_SCALE_FACTOR_LINE/g" \
    "$TEMPLATE_BASE/alacritty/alacritty.toml.template" > ~/.config/alacritty/alacritty.toml
# Extract dunst colors from pywal cache
if [ -f ~/.cache/wal/colors.json ]; then
    DUNST_BG=$(jq -r '.special.background // .colors.color0' ~/.cache/wal/colors.json)
    DUNST_FG=$(jq -r '.special.foreground // .colors.color7' ~/.cache/wal/colors.json)
    DUNST_BG_CRITICAL=$(jq -r '.colors.color1' ~/.cache/wal/colors.json)
    DUNST_FRAME_LOW=$(jq -r '.colors.color2' ~/.cache/wal/colors.json)
    DUNST_FRAME_NORMAL=$(jq -r '.colors.color4' ~/.cache/wal/colors.json)
    DUNST_FRAME_CRITICAL=$(jq -r '.colors.color1' ~/.cache/wal/colors.json)
else
    # Fallback colors if pywal cache doesn't exist
    DUNST_BG="#0B0E1B"
    DUNST_FG="#91ded4"
    DUNST_BG_CRITICAL="#1B5D68"
    DUNST_FRAME_LOW="#156D73"
    DUNST_FRAME_NORMAL="#1C7787"
    DUNST_FRAME_CRITICAL="#1B5D68"
fi

sed -e "s/\${DUNST_FONT}/$DUNST_FONT/g" \
    -e "s/\${DUNST_FONT_SIZE}/$DUNST_FONT_SIZE/g" \
    -e "s/\${DUNST_WIDTH}/$DUNST_WIDTH/g" \
    -e "s/\${DUNST_HEIGHT}/$DUNST_HEIGHT/g" \
    -e "s/\${DUNST_OFFSET_X}/$DUNST_OFFSET_X/g" \
    -e "s/\${DUNST_OFFSET_Y}/$DUNST_OFFSET_Y/g" \
    -e "s/\${DUNST_PADDING}/$DUNST_PADDING/g" \
    -e "s/\${DUNST_FRAME_WIDTH}/$DUNST_FRAME_WIDTH/g" \
    -e "s/\${DUNST_ICON_SIZE}/$DUNST_ICON_SIZE/g" \
    -e "s/\${DUNST_BG}/$DUNST_BG/g" \
    -e "s/\${DUNST_FG}/$DUNST_FG/g" \
    -e "s/\${DUNST_BG_CRITICAL}/$DUNST_BG_CRITICAL/g" \
    -e "s/\${DUNST_FRAME_LOW}/$DUNST_FRAME_LOW/g" \
    -e "s/\${DUNST_FRAME_NORMAL}/$DUNST_FRAME_NORMAL/g" \
    -e "s/\${DUNST_FRAME_CRITICAL}/$DUNST_FRAME_CRITICAL/g" \
    "$TEMPLATE_BASE/dunst/dunstrc.template" > ~/.config/dunst/dunstrc
sed -e "s/\${ROFI_FONT}/$ROFI_FONT/g" \
    -e "s/\${ROFI_FONT_SIZE}/$ROFI_FONT_SIZE/g" \
    "$TEMPLATE_BASE/rofi/config.rasi.template" > ~/.config/rofi/config.rasi

# Firefox font configuration
# Use dynamic username instead of hardcoded "traum"
FIREFOX_PROFILE_NAME="$USER"
mkdir -p ~/.mozilla/firefox/$FIREFOX_PROFILE_NAME/chrome
sed -e "s/\${FIREFOX_FONT}/$FIREFOX_FONT/g" \
    -e "s/\${FIREFOX_FONT_SIZE}/$FIREFOX_FONT_SIZE/g" \
    -e "s/\${FIREFOX_HEADER_FONT_SIZE}/$FIREFOX_HEADER_FONT_SIZE/g" \
    "$TEMPLATE_BASE/firefox/chrome/userChrome.css.template" > ~/.mozilla/firefox/$FIREFOX_PROFILE_NAME/chrome/userChrome.css
sed -e "s/\${FIREFOX_FONT}/$FIREFOX_FONT/g" \
    -e "s/\${FIREFOX_FONT_SIZE}/$FIREFOX_FONT_SIZE/g" \
    -e "s/\${FIREFOX_HEADER_FONT_SIZE}/$FIREFOX_HEADER_FONT_SIZE/g" \
    "$TEMPLATE_BASE/firefox/chrome/userContent.css.template" > ~/.mozilla/firefox/$FIREFOX_PROFILE_NAME/chrome/userContent.css
sed -e "s/\${FIREFOX_FONT}/$FIREFOX_FONT/g" \
    -e "s/\${FIREFOX_FONT_SIZE}/$FIREFOX_FONT_SIZE/g" \
    -e "s/\${FIREFOX_HEADER_FONT_SIZE}/$FIREFOX_HEADER_FONT_SIZE/g" \
    -e "s/\${FIREFOX_UI_SCALE}/$FIREFOX_UI_SCALE/g" \
    "$TEMPLATE_BASE/firefox/user.js.template" > ~/.mozilla/firefox/$FIREFOX_PROFILE_NAME/user.js

# Generate profiles.ini with dynamic username
sed -e "s/\${FIREFOX_PROFILE_NAME}/$FIREFOX_PROFILE_NAME/g" \
    "$TEMPLATE_BASE/firefox/profiles.ini.template" > ~/.mozilla/firefox/profiles.ini

exec i3
