#!/run/current-system/sw/bin/bash
# Hydrix display config refresh script

# Prefer Hydrix repo paths, fallback to ~/.config
HYDRIX_BASE="$HOME/Hydrix"
if [ -d "$HYDRIX_BASE/configs" ]; then
    TEMPLATE_BASE="$HYDRIX_BASE/configs"
else
    TEMPLATE_BASE="$HOME/.config"
fi

# Set MOD_KEY (same logic as .xinitrc)
hostname=$(hostnamectl | grep "Icon name:" | cut -d ":" -f2 | xargs)
if [[ $hostname =~ [vV][mM] ]]; then
    export MOD_KEY="Mod1"
else
    export MOD_KEY="Mod4"
fi

# Reload display config from Hydrix
if [ -f "$HYDRIX_BASE/scripts/load-display-config.sh" ]; then
    source "$HYDRIX_BASE/scripts/load-display-config.sh"
else
    source ~/.config/scripts/load-display-config.sh
fi

# Regenerate i3 config
sed -e "s/\${MOD_KEY}/$MOD_KEY/g" \
    -e "s/\${I3_FONT}/$I3_FONT/g" \
    -e "s/\${I3_FONT_SIZE}/$I3_FONT_SIZE/g" \
    -e "s/\${I3_BORDER_THICKNESS}/$I3_BORDER_THICKNESS/g" \
    -e "s/\${GAPS_INNER}/$GAPS_INNER/g" \
    "$TEMPLATE_BASE/i3/config.template" > ~/.config/i3/config

# Regenerate polybar config (will be overridden by polybar-restart with per-monitor configs)
sed -e "s/\${POLYBAR_FONT_SIZE}/$POLYBAR_FONT_SIZE/g" \
    -e "s/\${POLYBAR_FONT}/$POLYBAR_FONT/g" \
    -e "s/\${POLYBAR_HEIGHT}/$POLYBAR_HEIGHT/g" \
    -e "s/\${POLYBAR_LINE_SIZE}/$POLYBAR_LINE_SIZE/g" \
    "$TEMPLATE_BASE/polybar/config.ini.template" > ~/.config/polybar/config.ini

# Regenerate alacritty config
sed -e "s/\${ALACRITTY_FONT_SIZE}/$ALACRITTY_FONT_SIZE/g" \
    -e "s/\${ALACRITTY_FONT}/$ALACRITTY_FONT/g" \
    -e "s/\${ALACRITTY_SCALE_FACTOR_LINE}/$ALACRITTY_SCALE_FACTOR_LINE/g" \
    "$TEMPLATE_BASE/alacritty/alacritty.toml.template" > ~/.config/alacritty/alacritty.toml

# Regenerate Firefox configs (using Hydrix templates)
FIREFOX_PROFILE=$(find ~/.mozilla/firefox -maxdepth 1 -name "*.default*" -type d | head -1)
if [ -n "$FIREFOX_PROFILE" ]; then
    mkdir -p "$FIREFOX_PROFILE/chrome"
    sed -e "s/\${FIREFOX_FONT}/$FIREFOX_FONT/g" \
        ~/Hydrix/configs/firefox/user.js.template > "$FIREFOX_PROFILE/user.js"
    sed -e "s/\${FIREFOX_FONT}/$FIREFOX_FONT/g" \
        ~/Hydrix/configs/firefox/chrome/userChrome.css.template > "$FIREFOX_PROFILE/chrome/userChrome.css"
    sed -e "s/\${FIREFOX_FONT}/$FIREFOX_FONT/g" \
        ~/Hydrix/configs/firefox/chrome/userContent.css.template > "$FIREFOX_PROFILE/chrome/userContent.css"
fi

# Regenerate Obsidian font config (if obsidian vault exists)
if [ -d ~/hack_the_world/.obsidian/snippets ]; then
    sed -e "s/\${OBSIDIAN_FONT}/$OBSIDIAN_FONT/g" \
        -e "s/\${OBSIDIAN_FONT_SIZE}/$OBSIDIAN_FONT_SIZE/g" \
        -e "s/\${OBSIDIAN_HEADER_FONT_SIZE}/$OBSIDIAN_HEADER_FONT_SIZE/g" \
        ~/Hydrix/configs/obsidian/snippets/cozette-font.css.template > ~/hack_the_world/.obsidian/snippets/font.css
fi

# Reload i3 (which will reload config including gaps and borders)
i3-msg reload

# Regenerate dunst config
# Use wal template if wal colors exist and is not empty, otherwise use basic template
if [ -f ~/.cache/wal/dunstrc ] && [ -s ~/.cache/wal/dunstrc ]; then
    # Expand display-config variables in the wal-generated config
    sed -e "s/###DUNST_FONT###/$DUNST_FONT/g" \
        -e "s/###DUNST_FONT_SIZE###/$DUNST_FONT_SIZE/g" \
        -e "s/###DUNST_WIDTH###/$DUNST_WIDTH/g" \
        -e "s/###DUNST_HEIGHT###/$DUNST_HEIGHT/g" \
        -e "s/###DUNST_OFFSET_X###/$DUNST_OFFSET_X/g" \
        -e "s/###DUNST_OFFSET_Y###/$DUNST_OFFSET_Y/g" \
        -e "s/###DUNST_PADDING###/$DUNST_PADDING/g" \
        -e "s/###DUNST_FRAME_WIDTH###/$DUNST_FRAME_WIDTH/g" \
        -e "s/###DUNST_ICON_SIZE###/$DUNST_ICON_SIZE/g" \
        ~/.cache/wal/dunstrc > ~/.config/dunst/dunstrc
else
    # Use basic template as fallback
    sed -e "s/\${DUNST_FONT}/$DUNST_FONT/g" \
        -e "s/\${DUNST_FONT_SIZE}/$DUNST_FONT_SIZE/g" \
        -e "s/\${DUNST_WIDTH}/$DUNST_WIDTH/g" \
        -e "s/\${DUNST_HEIGHT}/$DUNST_HEIGHT/g" \
        -e "s/\${DUNST_OFFSET_X}/$DUNST_OFFSET_X/g" \
        -e "s/\${DUNST_OFFSET_Y}/$DUNST_OFFSET_Y/g" \
        -e "s/\${DUNST_PADDING}/$DUNST_PADDING/g" \
        -e "s/\${DUNST_FRAME_WIDTH}/$DUNST_FRAME_WIDTH/g" \
        -e "s/\${DUNST_ICON_SIZE}/$DUNST_ICON_SIZE/g" \
        ~/Hydrix/configs/dunst/dunstrc.template > ~/.config/dunst/dunstrc
fi

# Restart dunst to apply new config
killall dunst 2>/dev/null; dunst &

# Reload polybar with per-monitor configs
~/Hydrix/scripts/polybar-restart.sh

notify-send "Display Config" "Reloaded: external=$EXTERNAL_MONITOR font=$POLYBAR_FONT_SIZE gaps=$GAPS_INNER border=$I3_BORDER_THICKNESS"
