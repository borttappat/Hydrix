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
# --full-screen starts in fullscreen mode
# --auto-resize adjusts guest resolution to match window
# --hotkeys allows customizing release keys
virt-viewer --connect qemu:///system \
    --full-screen \
    --auto-resize=always \
    --hotkeys=toggle-fullscreen=shift+f11,release-cursor=Super_L \
    "$VM_NAME" &

echo "VM $VM_NAME launched in fullscreen on workspace ${WORKSPACE:-current}"
echo ""
echo "Controls:"
echo "  Super (hold) + 1/2/3...  - Release and switch workspace"
echo "  Shift+F11                - Toggle fullscreen"
