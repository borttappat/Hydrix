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

# Open virt-manager console
virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" &
VIRT_PID=$!

# Wait for window to appear
echo "Waiting for window..."
sleep 2

# Find the window
WIN_ID=""
for i in $(seq 1 10); do
    WIN_ID=$(xdotool search --name "$VM_NAME" 2>/dev/null | head -1 || true)
    if [ -n "$WIN_ID" ]; then
        break
    fi
    sleep 0.5
done

if [ -z "$WIN_ID" ]; then
    echo "Error: Could not find window for $VM_NAME"
    exit 1
fi

# Activate and fullscreen
xdotool windowactivate --sync "$WIN_ID"
sleep 0.3
xdotool key alt+v
sleep 0.2
xdotool key f

echo "VM $VM_NAME is now fullscreen"

# If workspace was specified, confirm we're there
if [ -n "$WORKSPACE" ]; then
    echo "On workspace $WORKSPACE"
fi
