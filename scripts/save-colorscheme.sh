#!/usr/bin/env bash
# Save current pywal colors as a named scheme for use in VMs
#
# Usage: ./save-colorscheme.sh <name>
# Example: ./save-colorscheme.sh tokyo-night
#
# This copies your current ~/.cache/wal/colors.json to
# Hydrix/colorschemes/<name>.json for use in VM builds

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRIX_DIR="$(dirname "$SCRIPT_DIR")"
SCHEMES_DIR="$HYDRIX_DIR/colorschemes"

NAME="${1:-}"

if [ -z "$NAME" ]; then
    echo "Usage: $0 <scheme-name>"
    echo ""
    echo "Saves current pywal colors as a named scheme."
    echo "Apply a wallpaper with pywal first: wal -i /path/to/image.jpg"
    echo ""
    echo "Existing schemes:"
    ls -1 "$SCHEMES_DIR"/*.json 2>/dev/null | xargs -I{} basename {} .json || echo "  (none)"
    exit 1
fi

# Check pywal cache exists
if [ ! -f ~/.cache/wal/colors.json ]; then
    echo "Error: No pywal colors found at ~/.cache/wal/colors.json"
    echo "Run 'wal -i /path/to/wallpaper.jpg' first"
    exit 1
fi

# Create schemes directory
mkdir -p "$SCHEMES_DIR"

# Copy colors.json
cp ~/.cache/wal/colors.json "$SCHEMES_DIR/${NAME}.json"

echo "Saved color scheme: $NAME"
echo "Location: $SCHEMES_DIR/${NAME}.json"
echo ""
echo "To use in a VM, set in the profile:"
echo "  hydrix.colorscheme = \"$NAME\";"
