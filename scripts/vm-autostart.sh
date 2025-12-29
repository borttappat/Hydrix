#!/usr/bin/env bash
# Auto-detect running VMs and place them on designated workspaces
# Uses vm-workspaces.json for configuration
# Sends notification if multiple VMs of the same type are detected

set -euo pipefail

HYDRIX_DIR="${HYDRIX_DIR:-$HOME/Hydrix}"
CONFIG_FILE="$HYDRIX_DIR/configs/vm-workspaces.json"
FULLSCREEN_SCRIPT="$HYDRIX_DIR/scripts/vm-fullscreen.sh"

# VM type to workspace mapping (fallback if config not found)
declare -A TYPE_TO_WORKSPACE=(
    ["pentest"]="2"
    ["browsing"]="3"
    ["comms"]="4"
    ["dev"]="5"
    ["office"]="6"
)

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed"
    exit 1
fi

if ! command -v notify-send &>/dev/null; then
    echo "Warning: notify-send not found, notifications disabled"
fi

# Load config if available
if [ -f "$CONFIG_FILE" ]; then
    echo "Loading workspace config from $CONFIG_FILE"
    # Parse workspace mappings from JSON
    while IFS="=" read -r ws type; do
        if [ -n "$type" ] && [ "$type" != "null" ]; then
            TYPE_TO_WORKSPACE["$type"]="$ws"
        fi
    done < <(jq -r '.workspaces | to_entries[] | select(.value.type != null) | "\(.key)=\(.value.type)"' "$CONFIG_FILE")
fi

# Get list of running VMs (excluding router-vm)
echo "Detecting running VMs..."
RUNNING_VMS=$(sudo virsh list --name 2>/dev/null | grep -v "^$" | grep -v "router-vm" || true)

if [ -z "$RUNNING_VMS" ]; then
    echo "No running VMs found (excluding router-vm)"
    exit 0
fi

echo "Running VMs:"
echo "$RUNNING_VMS" | sed 's/^/  /'

# Count VMs by type
declare -A TYPE_COUNT
declare -A TYPE_VMS

while read -r vm_name; do
    [ -z "$vm_name" ] && continue

    # Extract type from VM name (e.g., "pentest-kali" -> "pentest", "browsing-test" -> "browsing")
    vm_type=""
    for type in pentest browsing comms dev office; do
        if [[ "$vm_name" == *"$type"* ]]; then
            vm_type="$type"
            break
        fi
    done

    if [ -n "$vm_type" ]; then
        TYPE_COUNT["$vm_type"]=$((${TYPE_COUNT["$vm_type"]:-0} + 1))
        TYPE_VMS["$vm_type"]="${TYPE_VMS["$vm_type"]:-} $vm_name"
    else
        echo "  Warning: Could not determine type for VM '$vm_name'"
    fi
done <<< "$RUNNING_VMS"

# Process each type
PLACED=0
CONFLICTS=""

for vm_type in "${!TYPE_COUNT[@]}"; do
    count=${TYPE_COUNT["$vm_type"]}
    vms=${TYPE_VMS["$vm_type"]}
    workspace=${TYPE_TO_WORKSPACE["$vm_type"]:-}

    if [ -z "$workspace" ]; then
        echo "  No workspace mapping for type '$vm_type'"
        continue
    fi

    if [ "$count" -eq 1 ]; then
        # Single VM of this type - auto-place it
        vm_name=$(echo "$vms" | xargs)  # trim whitespace
        echo "  Placing $vm_name on workspace $workspace"

        if [ -x "$FULLSCREEN_SCRIPT" ]; then
            # Run synchronously - vm-fullscreen.sh now blocks until complete
            "$FULLSCREEN_SCRIPT" "$vm_name" "$workspace"
            PLACED=$((PLACED + 1))
            sleep 3  # Wait for virt-manager to fully stabilize before next VM
        else
            echo "  Error: $FULLSCREEN_SCRIPT not found or not executable"
        fi
    else
        # Multiple VMs of this type - don't auto-place
        echo "  Conflict: $count VMs of type '$vm_type':$vms"
        CONFLICTS="${CONFLICTS}\n  $vm_type ($count):$vms"
    fi
done

# Send notification about conflicts
if [ -n "$CONFLICTS" ]; then
    msg="Multiple VMs of same type detected:$CONFLICTS\n\nUse vm-fullscreen.sh to place manually"
    echo -e "$msg"

    if command -v notify-send &>/dev/null; then
        notify-send -u normal "VM Autostart" "$(echo -e "$msg")"
    fi
fi

echo ""
echo "VM Autostart complete: $PLACED VMs placed"
