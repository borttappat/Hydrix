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

# Process templates from Hydrix repo (or ~/.config as fallback)
# Output always goes to ~/.config/ for app compatibility
sed -e "s/\${MOD_KEY}/$MOD_KEY/g" \
    -e "s/\${I3_FONT}/$I3_FONT/g" \
    -e "s/\${I3_FONT_SIZE}/$I3_FONT_SIZE/g" \
    -e "s/\${I3_BORDER_THICKNESS}/$I3_BORDER_THICKNESS/g" \
    -e "s/\${GAPS_INNER}/$GAPS_INNER/g" \
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
sed -e "s/\${DUNST_FONT}/$DUNST_FONT/g" \
    -e "s/\${DUNST_FONT_SIZE}/$DUNST_FONT_SIZE/g" \
    -e "s/\${DUNST_WIDTH}/$DUNST_WIDTH/g" \
    -e "s/\${DUNST_HEIGHT}/$DUNST_HEIGHT/g" \
    -e "s/\${DUNST_OFFSET_X}/$DUNST_OFFSET_X/g" \
    -e "s/\${DUNST_OFFSET_Y}/$DUNST_OFFSET_Y/g" \
    -e "s/\${DUNST_PADDING}/$DUNST_PADDING/g" \
    -e "s/\${DUNST_FRAME_WIDTH}/$DUNST_FRAME_WIDTH/g" \
    -e "s/\${DUNST_ICON_SIZE}/$DUNST_ICON_SIZE/g" \
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
    "$TEMPLATE_BASE/firefox/user.js.template" > ~/.mozilla/firefox/$FIREFOX_PROFILE_NAME/user.js

# Generate profiles.ini with dynamic username
sed -e "s/\${FIREFOX_PROFILE_NAME}/$FIREFOX_PROFILE_NAME/g" \
    "$TEMPLATE_BASE/firefox/profiles.ini.template" > ~/.mozilla/firefox/profiles.ini

exec i3
