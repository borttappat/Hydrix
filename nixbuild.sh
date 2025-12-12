#!/usr/bin/env bash

# Hydrix NixOS Rebuild Script
# Auto-detects machine type and builds appropriate configuration
# Works on both host machines and VMs

set -e

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get system information
ARCH=$(uname -m)
CHASSIS=$(hostnamectl | grep -i "Chassis" | awk -F': ' '{print $2}' | xargs)
VENDOR=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
HOSTNAME=$(hostnamectl hostname)

echo "======================================"
echo "Hydrix NixOS Rebuild"
echo "======================================"
echo "Architecture: $ARCH"
echo "Chassis: $CHASSIS"
echo "Vendor: $VENDOR"
echo "Hostname: $HOSTNAME"
echo "======================================"

# ========== HELPER FUNCTIONS ==========

# List available NixOS configurations from flake
list_available_configs() {
    echo "Available configurations in flake:"
    if command -v jq &> /dev/null; then
        nix flake show "$FLAKE_DIR" --json 2>/dev/null | jq -r '.nixosConfigurations | keys[]' 2>/dev/null | \
            while read -r config; do
                echo "  - $config"
            done
    else
        # Fallback if jq not available
        nix flake show "$FLAKE_DIR" 2>&1 | grep -A 100 "nixosConfigurations" | grep "├──\|└──" | \
            awk '{print $2}' | sed 's/://g' | \
            while read -r config; do
                echo "  - $config"
            done
    fi
}

# Check if a flake configuration exists
flake_config_exists() {
    local config_name="$1"
    nix flake show "$FLAKE_DIR" --json 2>/dev/null | grep -q "nixosConfigurations.*${config_name}"
}

# Interactive config selection
select_config_interactively() {
    echo ""
    echo "No automatic match found for hostname: $HOSTNAME"
    echo ""
    list_available_configs
    echo ""
    read -p "Enter configuration name to build (or press Ctrl+C to cancel): " selected_config

    if [[ -z "$selected_config" ]]; then
        echo "ERROR: No configuration selected"
        exit 1
    fi

    if flake_config_exists "$selected_config"; then
        echo "$selected_config"
    else
        echo "ERROR: Configuration '$selected_config' not found"
        exit 1
    fi
}

# Detect current specialisation (for machines with router/lockdown/fallback modes)
detect_specialisation() {
    local CURRENT_SPEC="none"

    # Primary: Check configuration-name file
    if [[ -f /run/current-system/configuration-name ]]; then
        if grep -q "lockdown" /run/current-system/configuration-name 2>/dev/null; then
            CURRENT_SPEC="lockdown"
        elif grep -q "router" /run/current-system/configuration-name 2>/dev/null; then
            CURRENT_SPEC="router"
        elif grep -q "fallback" /run/current-system/configuration-name 2>/dev/null; then
            CURRENT_SPEC="fallback"
        fi
    fi

    # Fallback: Check for running VMs (only if no label detected)
    if [[ "$CURRENT_SPEC" == "none" ]]; then
        local LOCKDOWN_ROUTER=$(sudo virsh list --name 2>/dev/null | grep -c "lockdown-router" || true)
        local ROUTER_RUNNING=$(sudo virsh list --name 2>/dev/null | grep -c "router-vm" || true)

        if [[ "$LOCKDOWN_ROUTER" -gt 0 ]]; then
            CURRENT_SPEC="lockdown"
        elif [[ "$ROUTER_RUNNING" -gt 0 ]]; then
            CURRENT_SPEC="router"
        fi
    fi

    echo "$CURRENT_SPEC"
}

# Rebuild with or without specialisation
rebuild_system() {
    local FLAKE_TARGET="$1"
    local SPECIALISATION="$2"

    if [[ "$SPECIALISATION" != "none" ]]; then
        echo "Rebuilding with specialisation: $SPECIALISATION"
        sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false \
            --flake "$FLAKE_DIR#$FLAKE_TARGET" --specialisation "$SPECIALISATION"
    else
        echo "Rebuilding base configuration"
        sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false \
            --flake "$FLAKE_DIR#$FLAKE_TARGET"
    fi
}

# ========== ARCHITECTURE CHECK ==========

if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] || [[ "$VENDOR" == *"Apple"* && ("$ARCH" == *"arm"* || "$ARCH" == *"aarch"*) ]]; then
    echo "Detected ARM architecture"
    if flake_config_exists "armVM"; then
        rebuild_system "armVM" "none"
    else
        echo "ERROR: No ARM configuration found in flake"
        exit 1
    fi
    exit $?
fi

# ========== VM DETECTION ==========

if [[ "$CHASSIS" == "vm" ]] || echo "$VENDOR" | grep -q "QEMU\|VMware"; then
    echo "Detected Virtual Machine"

    # Extract VM type from hostname pattern (e.g., "pentest-google" → "pentest")
    VM_TYPE=""
    if [[ "$HOSTNAME" =~ ^(pentest|comms|browsing|dev|router)- ]] || [[ "$HOSTNAME" == "router-vm" ]]; then
        VM_TYPE="${BASH_REMATCH[1]}"
        [[ "$HOSTNAME" == "router-vm" ]] && VM_TYPE="router"
    fi

    if [[ -z "$VM_TYPE" ]]; then
        echo "ERROR: VM hostname '$HOSTNAME' doesn't match expected pattern"
        echo "Expected: pentest-*, comms-*, browsing-*, dev-*, router-*"
        exit 1
    fi

    FLAKE_TARGET="vm-${VM_TYPE}"
    echo "VM type: $VM_TYPE"
    echo "Building: $FLAKE_TARGET"

    if flake_config_exists "$FLAKE_TARGET"; then
        rebuild_system "$FLAKE_TARGET" "none"
    else
        echo "ERROR: Configuration '$FLAKE_TARGET' not found in flake"
        exit 1
    fi
    exit $?
fi

# ========== PHYSICAL MACHINE ==========

echo "Detected Physical Machine"

# Use hostname as flake target
FLAKE_TARGET="$HOSTNAME"

# Check if hostname-based configuration exists
if ! flake_config_exists "$FLAKE_TARGET"; then
    # Try interactive selection
    FLAKE_TARGET=$(select_config_interactively)
fi

echo ""
echo "Building configuration: $FLAKE_TARGET"

# Detect and apply specialisation
CURRENT_SPEC=$(detect_specialisation)
echo "Current specialisation: $CURRENT_SPEC"
echo ""

rebuild_system "$FLAKE_TARGET" "$CURRENT_SPEC"

echo ""
echo "✓ Configuration applied successfully!"
[[ "$CURRENT_SPEC" == "none" ]] && echo "  (Running in base mode)"
