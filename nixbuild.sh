#!/usr/bin/env bash

# Hydrix NixOS Rebuild Script
# Auto-detects machine type and builds appropriate configuration
# Works on both host machines and VMs

set -e

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get system information
ARCH=$(uname -m)
VENDOR=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
MODEL=$(hostnamectl | grep -i "Hardware Model" | awk -F': ' '{print $2}' | xargs)
CHASSIS=$(hostnamectl | grep -i "Chassis" | awk -F': ' '{print $2}' | xargs)
HOSTNAME=$(hostnamectl hostname)

echo "======================================"
echo "Hydrix NixOS Rebuild"
echo "======================================"
echo "Architecture: $ARCH"
echo "Chassis: $CHASSIS"
echo "Vendor: $VENDOR"
echo "Model: $MODEL"
echo "Hostname: $HOSTNAME"
echo "======================================"

# Check for ARM architecture
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] || [[ "$VENDOR" == *"Apple"* && ("$ARCH" == *"arm"* || "$ARCH" == *"aarch"*) ]]; then
    echo "Detected ARM architecture, building ARM configuration"
    sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#armVM"
    exit $?
fi

# === VM DETECTION ===
# Check if running in a virtual machine (check both chassis and vendor)
if [[ "$CHASSIS" == "vm" ]] || echo "$VENDOR" | grep -q "QEMU\|VMware"; then
    echo "Detected Virtual Machine"

    # Detect VM type from hostname pattern
    # Expected patterns: pentest-*, comms-*, browsing-*, dev-*, router-*
    if [[ "$HOSTNAME" =~ ^pentest- ]]; then
        echo "Building pentest VM configuration..."
        sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#vm-pentest"
    elif [[ "$HOSTNAME" =~ ^comms- ]]; then
        echo "Building comms VM configuration..."
        sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#vm-comms"
    elif [[ "$HOSTNAME" =~ ^browsing- ]]; then
        echo "Building browsing VM configuration..."
        sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#vm-browsing"
    elif [[ "$HOSTNAME" =~ ^dev- ]]; then
        echo "Building dev VM configuration..."
        sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#vm-dev"
    elif [[ "$HOSTNAME" =~ ^router- ]] || [[ "$HOSTNAME" == "router-vm" ]]; then
        echo "Building router VM configuration..."
        sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#vm-router"
    else
        echo "Unknown VM type (hostname: $HOSTNAME)"
        echo "Please rename VM to match pattern: pentest-*, comms-*, browsing-*, dev-*, router-*"
        exit 1
    fi
    exit $?
fi

# === PHYSICAL MACHINE DETECTION ===

# === SPECIALISATION DETECTION FUNCTION ===
# Shared function for machines with router/maximalism specialisations
detect_specialisation() {
    local CURRENT_LABEL="base-setup"

    # Primary: Check configuration-name file
    if [[ -f /run/current-system/configuration-name ]]; then
        if grep -q "maximalism" /run/current-system/configuration-name 2>/dev/null; then
            CURRENT_LABEL="maximalism-setup"
        elif grep -q "router" /run/current-system/configuration-name 2>/dev/null; then
            CURRENT_LABEL="router-setup"
        elif grep -q "fallback" /run/current-system/configuration-name 2>/dev/null; then
            CURRENT_LABEL="fallback-setup"
        fi
    fi

    # Fallback: Check for running VMs (last resort)
    if [[ "$CURRENT_LABEL" == "base-setup" ]]; then
        local ROUTER_RUNNING=$(sudo virsh list --name 2>/dev/null | grep -c "router-vm" || true)
        local PENTEST_RUNNING=$(sudo virsh list --name 2>/dev/null | grep -c "pentest" || true)

        if [[ "$ROUTER_RUNNING" -gt 0 && "$PENTEST_RUNNING" -gt 0 ]]; then
            CURRENT_LABEL="maximalism-setup"
        elif [[ "$ROUTER_RUNNING" -gt 0 ]]; then
            CURRENT_LABEL="router-setup"
        fi
    fi

    echo "$CURRENT_LABEL"
}

# === REBUILD STRATEGY FUNCTION ===
# Shared rebuild logic for machines with specialisations
rebuild_with_specialisation() {
    local MACHINE="$1"
    local CURRENT_LABEL="$2"

    echo "Current mode: $CURRENT_LABEL"
    echo ""

    # Build strategy based on current mode
    case "$CURRENT_LABEL" in
        "maximalism-setup")
            echo "Building $MACHINE in maximalism mode (requires reboot)..."
            sudo nixos-rebuild boot --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#$MACHINE"
            echo ""
            echo "✓ Configuration built successfully!"
            echo "  Reboot required to apply maximalism mode changes"
            echo ""
            echo "  To activate: sudo reboot"
            echo "  After reboot, select 'NixOS - Maximalism' in bootloader"
            ;;
        "router-setup")
            echo "Building $MACHINE in router mode (requires reboot)..."
            sudo nixos-rebuild boot --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#$MACHINE"
            echo ""
            echo "✓ Configuration built successfully!"
            echo "  Reboot required to apply router mode changes"
            echo ""
            echo "  To activate: sudo reboot"
            echo "  After reboot, select 'NixOS - Router' in bootloader"
            ;;
        "fallback-setup")
            echo "Building $MACHINE in fallback mode (live switch)..."
            sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#$MACHINE"
            echo ""
            echo "✓ Fallback mode configuration applied successfully!"
            echo "  System is ready to use (no reboot needed)"
            ;;
        "base-setup")
            echo "Building $MACHINE in base mode (live switch)..."
            sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#$MACHINE"
            echo ""
            echo "✓ Base mode configuration applied successfully!"
            echo "  System is ready to use (no reboot needed)"
            ;;
        *)
            echo "Building $MACHINE (unknown mode, treating as base)..."
            sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#$MACHINE"
            echo ""
            echo "✓ Configuration built successfully!"
            ;;
    esac
}

# For ASUS Zephyrus machines (with specialisations)
if echo "$MODEL" | grep -qi "zephyrus"; then
    echo "Detected ASUS Zephyrus"
    CURRENT_LABEL=$(detect_specialisation)
    rebuild_with_specialisation "zephyrus" "$CURRENT_LABEL"
    exit $?
fi

# For ASUS Zenbook machines (with specialisations)
if echo "$MODEL" | grep -qi "zenbook"; then
    echo "Detected ASUS Zenbook"
    CURRENT_LABEL=$(detect_specialisation)
    rebuild_with_specialisation "zenbook" "$CURRENT_LABEL"
    exit $?
fi

# === ADD NEW PHYSICAL MACHINES HERE ===
#
# To add support for a new physical machine:
#
# WITHOUT specialisations (simple machine):
# 1. Create profile in profiles/machines/{machine}.nix
# 2. Add entry to flake.nix nixosConfigurations
# 3. Add detection block here:
#
# if echo "$MODEL" | grep -qi "{keyword}"; then
#     echo "Detected {Machine Name}"
#     sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#{machine-name}"
#     exit $?
# fi
#
# WITH router/maximalism specialisations (advanced machine):
# 1. Create profile in profiles/machines/{machine}.nix with specialisations
# 2. Add entry to flake.nix nixosConfigurations
# 3. Add detection block here:
#
# if echo "$MODEL" | grep -qi "{keyword}"; then
#     echo "Detected {Machine Name}"
#     CURRENT_LABEL=$(detect_specialisation)
#     rebuild_with_specialisation "{machine-name}" "$CURRENT_LABEL"
#     exit $?
# fi
#

# For Razer machines
if echo "$VENDOR" | grep -q "Razer"; then
    echo "Detected Razer laptop"
    sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#razer"
    exit $?
fi

# For XMG/Schenker machines
if echo "$VENDOR" | grep -q "Schenker"; then
    echo "Detected Schenker/XMG laptop"
    sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#xmg"
    exit $?
fi

# For other ASUS machines
if echo "$VENDOR" | grep -q "ASUS"; then
    echo "Detected ASUS laptop (generic)"
    sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#asus"
    exit $?
fi

# === FALLBACK ===
echo ""
echo "⚠ Unknown hardware configuration"
echo "Vendor: $VENDOR"
echo "Model: $MODEL"
echo ""
echo "To add support for this machine:"
echo "1. Create a profile in profiles/machines/{name}.nix"
echo "2. Add entry to flake.nix"
echo "3. Add detection block in nixbuild.sh"
echo ""
echo "Building generic host configuration as fallback..."
sudo nixos-rebuild switch --impure --show-trace --option warn-dirty false --flake "$FLAKE_DIR#host"
