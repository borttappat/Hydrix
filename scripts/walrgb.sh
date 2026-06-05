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

# Mark wal as active (for vm-focus-daemon to use wal colors)
touch ~/.cache/wal/.active

# Restart polybar to pick up new colors (no need for full display-setup)
polybar-msg cmd restart >/dev/null 2>&1 || true
echo "Polybar restarted"

nixwal

# Update startpage if it exists
startpage="$HOME/.config/startpage.html"
colors_css="$HOME/.cache/wal/colors.css"

if [ -f "$startpage" ]; then
    sed -i '12,28d' "$startpage"
    sed -n '12,28p' "$colors_css" | sed -i '11r /dev/stdin' "$startpage"
fi

zathuracolors

echo "updating firefox using pywalfox..."
pywalfox update
echo "pywalfox updated successfully"

wal-gtk

echo "Updating dunst config..."
# Regenerate dunstrc via generate-dunstrc (reads wal cache + scaling.json)
generate-dunstrc
systemctl --user restart dunst
echo "Dunst config updated"

echo "Colors updated!"

# On i3/X11: force update i3wm.color4 and reload to pick up new wal colors.
# On Sway: skip — sway-apply-colors (called by nixwal) already regenerated
# colors.conf and called swaymsg reload. A second reload here would disrupt
# XWayland output enumeration and kill the eDP polybar instance.
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    if [ -f ~/.cache/wal/colors.json ]; then
        COLOR4=$(jq -r '.colors.color4' ~/.cache/wal/colors.json)
        xrdb -merge <<< "i3wm.color4: $COLOR4"
    fi
    current_ws=$(i3-msg -t get_workspaces 2>/dev/null | jq -r '.[] | select(.focused==true) | .name' || echo "")
    i3-msg reload >/dev/null 2>&1 || true
    [ -n "$current_ws" ] && i3-msg "workspace $current_ws" >/dev/null 2>&1 || true
    echo "i3 reloaded"
fi
