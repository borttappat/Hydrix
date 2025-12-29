#!/usr/bin/env bash
# Open a VM in fullscreen mode on a specific workspace
# Usage: vm-fullscreen.sh <vm-name> [workspace]
#
# Examples:
#   vm-fullscreen.sh browsing-test 6
#   vm-fullscreen.sh pentest-vm 7

set -euo pipefail

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

echo "Opening $VM_NAME in fullscreen..."

# Move to target workspace first (if specified)
if [ -n "$WORKSPACE" ]; then
    i3-msg "workspace $WORKSPACE" >/dev/null
fi

# Use virt-viewer with fullscreen flag
# --full-screen starts in fullscreen mode (adjusts guest resolution to fit)
# --auto-resize=always continuously resizes guest when window changes
# --hotkeys: Super_L releases keyboard grab, Shift+F11 toggles fullscreen
# --reconnect: Auto-reconnect if VM restarts
# Note: Resolution changes are handled by udev rule in VM (modules/vm/auto-resize.nix)
virt-viewer --connect qemu:///system \
    --full-screen \
    --auto-resize=always \
    --hotkeys=toggle-fullscreen=shift+f11,release-cursor=Super_L \
    --reconnect \
    "$VM_NAME" &

echo "VM $VM_NAME launched in fullscreen on workspace ${WORKSPACE:-current}"
echo ""
echo "Controls:"
echo "  Super_L (tap)           - Release keyboard grab"
echo "  Super + 1/2/3...        - Switch workspace (after release)"
echo "  Shift+F11               - Toggle fullscreen"
