#!/usr/bin/env bash

# Hydrix NixOS Rebuild Script
# Auto-detects machine type and builds appropriate configuration
# Works on both host machines and VMs

# Don't exit on error - we handle errors manually for better feedback
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"

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

# Pre-build VM configurations to populate virtiofs cache
prebuild_vm_configs() {
    echo ""
    echo "======================================"
    echo "Pre-building VM configurations"
    echo "======================================"
    echo "(Populates /nix/store for virtiofs shared cache)"
    echo ""

    local vm_configs=("vm-pentest" "vm-browsing" "vm-comms" "vm-dev")
    local success_count=0

    for vm_config in "${vm_configs[@]}"; do
        echo -n "  $vm_config... "
        if nix build "$FLAKE_DIR#nixosConfigurations.${vm_config}.config.system.build.toplevel" --no-link 2>/dev/null; then
            echo "✓"
            ((success_count++))
        else
            echo "✗ (may not exist)"
        fi
    done

    echo ""
    echo "VM cache updated: $success_count/${#vm_configs[@]} configurations"
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
# NOTE: The base config IS router mode - "router" is NOT a specialisation!
# Only "lockdown" and "fallback" are valid specialisations
detect_specialisation() {
    local CURRENT_SPEC="none"

    # Primary: Check configuration-name file
    if [[ -f /run/current-system/configuration-name ]]; then
        local CONFIG_NAME=$(cat /run/current-system/configuration-name 2>/dev/null)
        if [[ "$CONFIG_NAME" == "lockdown" ]]; then
            CURRENT_SPEC="lockdown"
        elif [[ "$CONFIG_NAME" == "fallback" ]]; then
            CURRENT_SPEC="fallback"
        fi
        # Note: base/router mode has no configuration-name or empty
    fi

    # Fallback: Check for running VMs to detect lockdown mode
    # (router-vm running = base mode, lockdown-router = lockdown mode)
    if [[ "$CURRENT_SPEC" == "none" ]]; then
        local LOCKDOWN_ROUTER=$(sudo virsh list --name 2>/dev/null | grep -c "lockdown-router" || true)
        if [[ "$LOCKDOWN_ROUTER" -gt 0 ]]; then
            CURRENT_SPEC="lockdown"
        fi
        # router-vm running = base mode (no specialisation needed)
    fi

    echo "$CURRENT_SPEC"
}

# Rebuild with or without specialisation
rebuild_system() {
    local FLAKE_TARGET="$1"
    local SPECIALISATION="$2"
    local REBUILD_STATUS=0

    # Clean up home-manager backup files that block activation
    # This MUST happen BEFORE nixos-rebuild because home-manager runs during activation
    echo "Cleaning up home-manager backup files..."
    find ~/.config -name "*.hm-backup" -type f -delete 2>/dev/null || true
    rm -f ~/.xinitrc.hm-backup ~/.vimrc.hm-backup ~/.Xmodmap.hm-backup 2>/dev/null || true

    # Force fresh flake evaluation to ensure home-manager picks up changes
    # This pre-builds the system config which forces nix to evaluate everything fresh
    # Run WITHOUT sudo to use user's nix cache properly
    echo "Forcing fresh flake evaluation..."
    if ! nix build "$FLAKE_DIR#nixosConfigurations.$FLAKE_TARGET.config.system.build.toplevel" --impure --no-link; then
        echo ""
        echo "ERROR: Nix build failed! Check the output above for errors."
        return 1
    fi

    # Run nixos-rebuild with output visible (no buffering issues)
    if [[ "$SPECIALISATION" != "none" ]]; then
        echo "Rebuilding with specialisation: $SPECIALISATION"
        echo "Running: sudo nixos-rebuild switch --flake ~/Hydrix#$FLAKE_TARGET --impure --specialisation $SPECIALISATION"
        echo ""
        sudo nixos-rebuild switch --flake ~/Hydrix#"$FLAKE_TARGET" --impure --specialisation "$SPECIALISATION" 2>&1
        REBUILD_STATUS=$?
    else
        echo "Rebuilding base configuration"
        echo "Running: sudo nixos-rebuild switch --flake ~/Hydrix#$FLAKE_TARGET --impure"
        echo ""
        sudo nixos-rebuild switch --flake ~/Hydrix#"$FLAKE_TARGET" --impure 2>&1
        REBUILD_STATUS=$?
    fi

    if [[ $REBUILD_STATUS -ne 0 ]]; then
        echo ""
        echo "ERROR: nixos-rebuild failed with exit code $REBUILD_STATUS"
        echo "Check the output above for errors."
        return $REBUILD_STATUS
    fi

    echo ""
    echo "✓ System rebuild completed successfully"

    # Check home-manager status (it runs during activation)
    echo ""
    if systemctl is-failed --quiet home-manager-$USER.service 2>/dev/null; then
        echo "WARNING: home-manager failed during activation!"
        echo "Check with: journalctl -u home-manager-$USER.service -n 20"
        echo "Common fix: rm ~/.config/**/*.hm-backup and rebuild"
    else
        echo "✓ Home-manager configs applied successfully"
    fi

    # Force colorscheme re-application (enforces config-defined colorscheme)
    if systemctl list-units --type=service | grep -q "hydrix-colorscheme"; then
        echo ""
        echo "Applying configured colorscheme..."
        sudo systemctl restart hydrix-colorscheme.service 2>/dev/null || true
        if systemctl is-failed --quiet hydrix-colorscheme.service 2>/dev/null; then
            echo "WARNING: colorscheme service failed"
        else
            echo "✓ Colorscheme applied"
        fi
    fi

    return 0
}

# ========== ARCHITECTURE CHECK ==========

if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] || [[ "$VENDOR" == *"Apple"* && ("$ARCH" == *"arm"* || "$ARCH" == *"aarch"*) ]]; then
    echo "Detected ARM architecture"
    if flake_config_exists "armVM"; then
        if rebuild_system "armVM" "none"; then
            echo "✓ ARM configuration applied successfully!"
            exit 0
        else
            echo "✗ ARM configuration failed - see errors above"
            exit 1
        fi
    else
        echo "ERROR: No ARM configuration found in flake"
        exit 1
    fi
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
        if rebuild_system "$FLAKE_TARGET" "none"; then
            echo "✓ VM configuration applied successfully!"
            exit 0
        else
            echo "✗ VM configuration failed - see errors above"
            exit 1
        fi
    else
        echo "ERROR: Configuration '$FLAKE_TARGET' not found in flake"
        exit 1
    fi
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

if rebuild_system "$FLAKE_TARGET" "$CURRENT_SPEC"; then
    echo ""
    echo "✓ Configuration applied successfully!"
    [[ "$CURRENT_SPEC" == "none" ]] && echo "  (Running in base mode)"

    # Pre-build VM configs to update virtiofs cache
    prebuild_vm_configs
else
    echo ""
    echo "✗ Configuration failed - see errors above"
    exit 1
fi
