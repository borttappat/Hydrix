# Generates a static pywal cache for VMs based on VM type
# This ensures VMs have consistent colors while using the same templates as the host

set -euo pipefail

VM_TYPE="${1:-}"

if [ -z "$VM_TYPE" ]; then
    echo "Usage: vm-static-colors.sh <pentest|comms|browsing|dev>"
    exit 1
fi

echo "Generating static color scheme for VM type: $VM_TYPE"

# Color scheme definitions
# Each VM type gets a distinctive accent color
case "$VM_TYPE" in
    pentest)
        ACCENT_HEX="ea6c73"  # Red - aggressive, warning, security focus
        WALLPAPER_NAME="pentest-red.jpg"
        ;;
    comms)
        ACCENT_HEX="6c89ea"  # Blue - calm, communication, connectivity
        WALLPAPER_NAME="comms-blue.jpg"
        ;;
    browsing)
        ACCENT_HEX="73ea6c"  # Green - safe, browsing, general use
        WALLPAPER_NAME="browsing-green.jpg"
        ;;
    dev)
        ACCENT_HEX="ba6cea"  # Purple - creative, development, building
        WALLPAPER_NAME="dev-purple.jpg"
        ;;
    *)
        echo "Unknown VM type: $VM_TYPE"
        echo "Valid types: pentest, comms, browsing, dev"
        exit 1
        ;;
esac

# Ensure cache directory exists
mkdir -p ~/.cache/wal

# Generate 16-color palette from accent color
# We'll create a simple palette by varying brightness/saturation
cat > ~/.cache/wal/colors << EOF
#1a1b26
#${ACCENT_HEX}
#a9b1d6
#7aa2f7
#bb9af7
#73daca
#${ACCENT_HEX}
#c0caf5
#414868
#${ACCENT_HEX}
#a9b1d6
#7aa2f7
#bb9af7
#73daca
#${ACCENT_HEX}
#c0caf5
EOF

# Generate colors.json for pywal compatibility
cat > ~/.cache/wal/colors.json << EOF
{
    "special": {
        "background": "#1a1b26",
        "foreground": "#c0caf5",
        "cursor": "#${ACCENT_HEX}"
    },
    "colors": {
        "color0": "#1a1b26",
        "color1": "#${ACCENT_HEX}",
        "color2": "#a9b1d6",
        "color3": "#7aa2f7",
        "color4": "#bb9af7",
        "color5": "#73daca",
        "color6": "#${ACCENT_HEX}",
        "color7": "#c0caf5",
        "color8": "#414868",
        "color9": "#${ACCENT_HEX}",
        "color10": "#a9b1d6",
        "color11": "#7aa2f7",
        "color12": "#bb9af7",
        "color13": "#73daca",
        "color14": "#${ACCENT_HEX}",
        "color15": "#c0caf5"
    }
}
EOF

# Generate colors.css for web integrations
cat > ~/.cache/wal/colors.css << EOF
/* Pywal colors - Static ${VM_TYPE} theme */

:root {
    /* Special */
    --background: #1a1b26;
    --foreground: #c0caf5;
    --cursor: #${ACCENT_HEX};

    /* Colors */
    --color0: #1a1b26;
    --color1: #${ACCENT_HEX};
    --color2: #a9b1d6;
    --color3: #7aa2f7;
    --color4: #bb9af7;
    --color5: #73daca;
    --color6: #${ACCENT_HEX};
    --color7: #c0caf5;
    --color8: #414868;
    --color9: #${ACCENT_HEX};
    --color10: #a9b1d6;
    --color11: #7aa2f7;
    --color12: #bb9af7;
    --color13: #73daca;
    --color14: #${ACCENT_HEX};
    --color15: #c0caf5;
}
EOF

# Generate sequences file for terminal color restoration
cat > ~/.cache/wal/sequences << 'EOF'
]4;0;#1a1b26\]4;1;#${ACCENT_HEX}\]4;2;#a9b1d6\]4;3;#7aa2f7\]4;4;#bb9af7\]4;5;#73daca\]4;6;#${ACCENT_HEX}\]4;7;#c0caf5\]4;8;#414868\]4;9;#${ACCENT_HEX}\]4;10;#a9b1d6\]4;11;#7aa2f7\]4;12;#bb9af7\]4;13;#73daca\]4;14;#${ACCENT_HEX}\]4;15;#c0caf5\]10;#c0caf5\]11;#1a1b26\]12;#c0caf5\]13;#c0caf5\]17;#c0caf5\]19;#1a1b26\]4;232;#1a1b26\]4;256;#c0caf5\]708;#1a1b26\
EOF

# Replace ${ACCENT_HEX} in sequences file
sed -i "s/\${ACCENT_HEX}/$ACCENT_HEX/g" ~/.cache/wal/sequences

# Mark as generated
touch ~/.cache/wal/.static-colors-generated
echo "VM_TYPE=$VM_TYPE" > ~/.cache/wal/.static-colors-type

echo "Static color scheme generated successfully for $VM_TYPE"
echo "Colors will persist across reboots and remain ${VM_TYPE}-themed"
