#!/run/current-system/sw/bin/bash

if [ -z "$1" ]; then
  echo "Usage: walrgb /path/to/file"
  exit 1
fi

file_path="$1"
file_name="${file_path##*/}"
directory="${file_path%/*}"

echo "File path: $file_path"
echo "File name: $file_name"
echo "Directory: $directory"

echo "Setting colorscheme according to $file_path"
wal -q -i "${file_path}"
echo "Colorscheme set"

HEX_CODE=$(sed -n '\''2p'\'' ~/.cache/wal/colors | sed '\''s/#//'\''')

if command -v asusctl >/dev/null 2>&1 && asusctl -v >/dev/null 2>&1; then
  echo "ASUS hardware detected, using asusctl"
  asusctl aura static -c $HEX_CODE
  asusctl -k high
elif command -v openrgb >/dev/null 2>&1; then
  echo "Checking for RGB devices..."
  if openrgb --list-devices 2>/dev/null | grep -q "Device [0-9]"; then
    echo "RGB devices found, using OpenRGB to set device lighting"  
    openrgb --device 0 --mode static --color "${HEX_CODE/#/}"
  else
    echo "No RGB devices detected, skipping OpenRGB"
  fi
else
  echo "No compatible RGB control tool found. Skipping RGB lighting control."
fi

echo "Backlight set"

polybar-msg cmd restart
echo "Restarting polybar..."

nixwal

# Update startpage if it exists
startpage="$HOME/.config/startpage.html"
colors_css="$HOME/.cache/wal/colors.css"

if [ -f "$startpage" ]; then
    sed -i '12,28d' "$startpage"
    sed -n '12,28p' "$colors_css" | sed -i '11r /dev/stdin' "$startpage"
fi

echo "Starting GitHub Pages color update..."

site_colors="$HOME/borttappat.github.io/assets/css/colors.css"
colors_css="$HOME/.cache/wal/colors.css"

mkdir -p "$(dirname "$site_colors")"

{
    echo "/* Theme colors - automatically generated */"
    echo ":root {"
    echo "    /* Colors extracted from pywal */"
    sed -n '12,28p' "$colors_css"
    echo ""
    echo "    /* Additional theme variables */"
    echo "    --scanline-color: rgba(12, 12, 12, 0.1);"
    echo "    --flicker-color: rgba(152, 217, 2, 0.01);"
    echo "    --text-shadow-color: var(--color1);"
    echo "    --header-shadow-color: var(--color0);"
    echo "}"
} > "$site_colors"
echo "Updated GitHub Pages colors"

zathuracolors

echo "updating firefox using pywalfox..."
pywalfox update
echo "pywalfox updated successfully"

wal-gtk

echo "Updating dunst config..."
# Regenerate dunstrc with proper fonts/sizing and new colors
HYDRIX_PATH="${HYDRIX_PATH:-$HOME/Hydrix}"
TEMPLATE_BASE="$HYDRIX_PATH/configs"

# Source display config for sizing variables
source "$HYDRIX_PATH/scripts/load-display-config.sh"

# Extract colors from pywal cache
if [ -f ~/.cache/wal/colors.json ]; then
    DUNST_BG=$(jq -r '.special.background // .colors.color0' ~/.cache/wal/colors.json)
    DUNST_FG=$(jq -r '.special.foreground // .colors.color7' ~/.cache/wal/colors.json)
    DUNST_BG_CRITICAL=$(jq -r '.colors.color1' ~/.cache/wal/colors.json)
    DUNST_FRAME_LOW=$(jq -r '.colors.color2' ~/.cache/wal/colors.json)
    DUNST_FRAME_NORMAL=$(jq -r '.colors.color4' ~/.cache/wal/colors.json)
    DUNST_FRAME_CRITICAL=$(jq -r '.colors.color1' ~/.cache/wal/colors.json)
else
    DUNST_BG="#0B0E1B"
    DUNST_FG="#91ded4"
    DUNST_BG_CRITICAL="#1B5D68"
    DUNST_FRAME_LOW="#156D73"
    DUNST_FRAME_NORMAL="#1C7787"
    DUNST_FRAME_CRITICAL="#1B5D68"
fi

# Generate dunstrc from template
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

pkill dunst 2>/dev/null || true
dunst &
echo "Dunst config updated"

echo "Colors updated!"
