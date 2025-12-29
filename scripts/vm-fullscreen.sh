#!/usr/bin/env bash
# Open a VM in fullscreen mode on a specific workspace using virt-manager
# Usage: vm-fullscreen.sh <vm-name> [workspace]
#
# Uses virt-manager (not virt-viewer) because:
# - virt-manager properly triggers SPICE resolution updates for vm-auto-resize.sh
# - Super_L release key works via dconf setting
# - vm-fullscreen-hack.sh triggers internal fullscreen (hides menubar)
#
# Examples:
#   vm-fullscreen.sh browsing-test 3
#   vm-fullscreen.sh pentest-test 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="${1:-}"
WORKSPACE="${2:-}"

if [ -z "$VM_NAME" ]; then
    echo "Usage: vm-fullscreen.sh <vm-name> [workspace]"
    echo ""
    echo "Available VMs:"
    sudo virsh list --name | grep -v "^$" | sed 's/^/  /'
    exit 1
fi

# Check if VM is running
if ! sudo virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
    echo "Error: VM '$VM_NAME' is not running"
    exit 1
fi

echo "Opening $VM_NAME..."

# Move to target workspace first (if specified)
# Map workspace numbers to full names for consistent naming
declare -A WS_NAMES=(
    ["1"]="1 - HOST"
    ["2"]="2 - HÄXING"
    ["3"]="3 - BROWSING"
    ["4"]="4 - COMMS"
    ["5"]="5 - DEV"
)
if [ -n "$WORKSPACE" ]; then
    WS_FULL="${WS_NAMES[$WORKSPACE]:-$WORKSPACE}"
    i3-msg "workspace \"$WS_FULL\"" >/dev/null
fi

# Ensure Super_L is set as release key BEFORE launching virt-manager
# Key code 65515 = Super_L. Must be set before virt-manager reads it.
# Kill existing virt-manager console windows for this VM to ensure fresh dconf read
dconf write /org/virt-manager/virt-manager/console/grab-keys "'65515'" 2>/dev/null || true

# Launch virt-manager with direct console view
virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" &
VIRT_PID=$!

# Wait for window to appear (blocking, not background)
echo "Waiting for VM window to appear..."
WINDOW_FOUND=0
for i in {1..30}; do
    if xdotool search --name "$VM_NAME on QEMU" >/dev/null 2>&1; then
        WINDOW_FOUND=1
        break
    fi
    sleep 0.3
done

if [ "$WINDOW_FOUND" -eq 0 ]; then
    echo "Warning: VM window did not appear within timeout"
    echo "Skipping fullscreen hack to avoid freeze"
else
    sleep 1  # Extra time for window to stabilize

    # Trigger internal fullscreen (hides menubar) - with timeout to prevent hang
    echo "Triggering fullscreen..."
    timeout 10 "$SCRIPT_DIR/vm-fullscreen-hack.sh" "$VM_NAME" || echo "Fullscreen hack timed out or failed"

    sleep 1  # Allow fullscreen to complete
fi

echo "VM $VM_NAME launched on workspace ${WORKSPACE:-current}"
echo ""
echo "Controls:"
echo "  Super_L (tap)           - Release keyboard grab"
echo "  Super + 1/2/3...        - Switch workspace (after release)"
