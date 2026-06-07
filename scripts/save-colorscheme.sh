#!/usr/bin/env bash
# Save current pywal colors as a named scheme for use across VMs
#
# Usage: save-colorscheme <name>
# Example: save-colorscheme tokyo-night
#
# Saves ~/.cache/wal/colors.json to hydrix-config/colorschemes/<name>.json.
# User colorschemes take priority over framework built-ins — use any name
# to override a built-in (e.g. "nvid") or add a new one.

set -euo pipefail

# Locate hydrix-config (same detection as wifi-sync, vm-sync, rebuild)
if [[ -n "${HYDRIX_FLAKE_DIR:-}" && -f "$HYDRIX_FLAKE_DIR/flake.nix" ]]; then
    PROJECT_DIR="$HYDRIX_FLAKE_DIR"
elif [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
    PROJECT_DIR="$HOME/hydrix-config"
else
    echo "Error: No Hydrix config found at ~/hydrix-config" >&2
    exit 1
fi

SCHEMES_DIR="$PROJECT_DIR/colorschemes"
NAME="${1:-}"

if [ -z "$NAME" ]; then
    echo "Usage: save-colorscheme <scheme-name>"
    echo ""
    echo "Saves current pywal colors as a named scheme in hydrix-config/colorschemes/."
    echo "Apply a wallpaper with pywal first: wal -i /path/to/image.jpg"
    echo ""
    echo "Existing user schemes:"
    ls -1 "$SCHEMES_DIR"/*.json 2>/dev/null | xargs -I{} basename {} .json || echo "  (none)"
    exit 1
fi

# Check pywal cache exists
if [ ! -f ~/.cache/wal/colors.json ]; then
    echo "Error: No pywal colors found at ~/.cache/wal/colors.json"
    echo "Run 'wal -i /path/to/wallpaper.jpg' first"
    exit 1
fi

mkdir -p "$SCHEMES_DIR"
cp ~/.cache/wal/colors.json "$SCHEMES_DIR/${NAME}.json"

echo "Saved: $SCHEMES_DIR/${NAME}.json"
echo ""
echo "To use in a VM profile:"
echo "  hydrix.colorscheme = \"$NAME\";"
echo ""
echo "Rebuild the VM to apply: microvm update microvm-<profile>"
