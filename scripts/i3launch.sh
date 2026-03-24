#!/run/current-system/sw/bin/bash
# i3launch.sh - Launch i3 with resolution-aware config generation
#
# Flow:
#   1. Clean up old serverauth files
#   2. Detect display type (VM vs physical) and set resolution
#   3. Load display config (fonts, gaps, borders from display-config.json)
#   4. Set MOD_KEY based on VM detection
#   5. Generate i3 config from template via sed substitution
#   6. Launch i3

cleanup_old_serverauth() {
    echo "Cleaning up old serverauth files..."
    find "$HOME" -maxdepth 1 -name ".serverauth.*" -type f -mtime +2 -print0 | while IFS= read -r -d '' file; do
        echo "Removing old serverauth file: $(basename "$file")"
        rm -f "$file"
    done
}

cleanup_old_serverauth

# Detect if running in a VM
hostname=$(hostnamectl | grep "Icon name:" | cut -d ":" -f2 | xargs)
IS_VM="false"
if [[ $hostname =~ [vV][mM] ]]; then
    IS_VM="true"
fi

# VM display setup
if [[ $IS_VM == "true" ]]; then
    echo "VM detected, setting up VM display resolution..."

    VM_DISPLAY=$(xrandr | grep -E "(Virtual-1|qxl-0)" | grep " connected" | cut -d' ' -f1 | head -n1)

    if [ -n "$VM_DISPLAY" ]; then
        echo "Found VM display: $VM_DISPLAY"
        xrandr --newmode "1920x1200" 193.25 1920 2056 2256 2592 1200 1203 1209 1245 -hsync +vsync 2>/dev/null || true
        xrandr --newmode "2560x1440" 312.25 2560 2752 3024 3488 1440 1443 1448 1493 -hsync +vsync 2>/dev/null || true
        xrandr --addmode "$VM_DISPLAY" 1920x1200 2>/dev/null || true
        xrandr --addmode "$VM_DISPLAY" 2560x1440 2>/dev/null || true
        if xrandr --output "$VM_DISPLAY" --mode 2560x1440 2>/dev/null; then
            echo "Successfully set $VM_DISPLAY to 2560x1440"
        elif xrandr --output "$VM_DISPLAY" --mode 1920x1200 2>/dev/null; then
            echo "Successfully set $VM_DISPLAY to 1920x1200"
        else
            echo "Could not set custom resolution, using current resolution"
        fi
    else
        echo "No VM display found, proceeding with normal logic"
    fi
else
    # Physical machine - handle internal display
    INTERNAL_DISPLAY=$(xrandr | grep "eDP" | cut -d' ' -f1 | head -n1)

    if [ -n "$INTERNAL_DISPLAY" ]; then
        NATIVE_RES=$(xrandr | grep "$INTERNAL_DISPLAY" | grep -oP '\d+x\d+' | head -n1)

        case $NATIVE_RES in
            "2880x1800")
                xrandr --output "$INTERNAL_DISPLAY" --mode 1920x1200
                echo "Set internal display to 1920x1200 for font clarity"
                ;;
            "1920x1080")
                echo "Keeping native 1920x1080 resolution"
                ;;
            *)
                echo "Unknown internal resolution: $NATIVE_RES, keeping native"
                ;;
        esac
    else
        echo "No internal display found"
    fi
fi

sleep 0.5

# Load display configuration (sets I3_FONT, I3_FONT_SIZE, I3_BORDER_THICKNESS, GAPS_INNER, etc.)
LOAD_DISPLAY_CONFIG="$HOME/.config/scripts/load-display-config.sh"
if [ -f "$LOAD_DISPLAY_CONFIG" ]; then
    echo "Loading display configuration..."
    source "$LOAD_DISPLAY_CONFIG"
else
    echo "Warning: load-display-config.sh not found, using defaults"
    export I3_FONT="Cozette"
    export I3_FONT_SIZE="8"
    export I3_BORDER_THICKNESS="2"
    export GAPS_INNER="6"
fi

# Set MOD_KEY based on VM detection
if [[ $IS_VM == "true" ]]; then
    export MOD_KEY="Mod1"
    echo "VM detected: Using Mod1 (Alt) as modifier"
else
    export MOD_KEY="Mod4"
    echo "Regular system: Using Mod4 (Super) as modifier"
fi

# Generate i3 config from template
CONFIG_DIR="$HOME/.config/i3"
TEMPLATE_CONFIG="$CONFIG_DIR/config.template"
FINAL_CONFIG="$CONFIG_DIR/config"

if [ ! -f "$TEMPLATE_CONFIG" ]; then
    echo "Error: Template config file not found at $TEMPLATE_CONFIG"
    exit 1
fi

echo "Generating i3 config from template..."
sed -e "s/\${MOD_KEY}/$MOD_KEY/g" \
    -e "s/\${I3_FONT}/$I3_FONT/g" \
    -e "s/\${I3_FONT_SIZE}/$I3_FONT_SIZE/g" \
    -e "s/\${I3_BORDER_THICKNESS}/$I3_BORDER_THICKNESS/g" \
    -e "s/\${GAPS_INNER}/$GAPS_INNER/g" \
    "$TEMPLATE_CONFIG" > "$FINAL_CONFIG"

echo "Created i3 config at $FINAL_CONFIG"
echo "  MOD_KEY=$MOD_KEY"
echo "  I3_FONT=$I3_FONT $I3_FONT_SIZE"
echo "  I3_BORDER_THICKNESS=$I3_BORDER_THICKNESS"
echo "  GAPS_INNER=$GAPS_INNER"

exec i3
