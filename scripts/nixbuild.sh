#!/usr/bin/env bash

# Hydrix NixOS Rebuild Script
# Always builds #host for physical machines, auto-detects VMs
# Stages local/ files for nix visibility (gitignored directory)

set +e  # Don't exit on error - we handle errors manually for better feedback

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"

# Get system information
CHASSIS=$(hostnamectl | grep -i "Chassis" | awk -F': ' '{print $2}' | xargs)
VENDOR=$(hostnamectl | grep -i "Hardware Vendor" | awk -F': ' '{print $2}' | xargs)
HOSTNAME=$(hostnamectl hostname)

echo "======================================"
echo "Hydrix NixOS Rebuild"
echo "======================================"
echo "Hostname: $HOSTNAME"
echo "Chassis: $CHASSIS"
echo "======================================"

# ========== HELPER FUNCTIONS ==========

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
            echo "done"
            ((success_count++))
        else
            echo "skipped"
        fi
    done

    echo ""
    echo "VM cache updated: $success_count/${#vm_configs[@]} configurations"
}

# Detect current specialisation
detect_specialisation() {
    local CURRENT_SPEC=""

    # Check configuration-name file (set by NixOS when booting a specialisation)
    if [[ -f /run/current-system/configuration-name ]]; then
        local CONFIG_NAME=$(cat /run/current-system/configuration-name 2>/dev/null)
        if [[ "$CONFIG_NAME" == "lockdown" ]] || [[ "$CONFIG_NAME" == "fallback" ]]; then
            CURRENT_SPEC="$CONFIG_NAME"
        fi
    fi

    # Fallback: Check for lockdown-router VM
    if [[ -z "$CURRENT_SPEC" ]]; then
        if sudo virsh list --name 2>/dev/null | grep -q "lockdown-router"; then
            CURRENT_SPEC="lockdown"
        fi
    fi

    echo "$CURRENT_SPEC"
}

# Stage local files for nix visibility (gitignored directory)
stage_local_files() {
    echo "Staging local files for nix visibility..."
    cd "$FLAKE_DIR"

    local files_staged=0
    for file in local/host.nix local/shared.nix local/machines/host.nix local/router.nix; do
        if [[ -f "$file" ]]; then
            git add -f "$file" 2>/dev/null && ((files_staged++))
        fi
    done

    echo "  Staged $files_staged local files"
}

# Unstage local files after build (prevent accidental commits)
unstage_local_files() {
    cd "$FLAKE_DIR"
    git reset HEAD -- local/ 2>/dev/null || true
}

# Rebuild the system
rebuild_system() {
    local FLAKE_TARGET="$1"
    local SPECIALISATION="$2"
    local REBUILD_STATUS=0

    # Clean up home-manager backup files that block activation
    echo "Cleaning up home-manager backup files..."
    find ~/.config -name "*.hm-backup" -type f -delete 2>/dev/null || true
    rm -f ~/.xinitrc.hm-backup ~/.vimrc.hm-backup ~/.Xmodmap.hm-backup 2>/dev/null || true

    # Pre-build to force fresh evaluation (run as user to use user's nix cache)
    echo "Building configuration..."
    if ! nix build "$FLAKE_DIR#nixosConfigurations.$FLAKE_TARGET.config.system.build.toplevel" --impure --no-link; then
        echo ""
        echo "ERROR: Nix build failed! Check the output above for errors."
        return 1
    fi

    # Run nixos-rebuild
    if [[ -n "$SPECIALISATION" ]]; then
        echo "Rebuilding with specialisation: $SPECIALISATION"
        echo "Running: sudo nixos-rebuild switch --flake $FLAKE_DIR#$FLAKE_TARGET --impure --specialisation $SPECIALISATION"
        echo ""
        sudo nixos-rebuild switch --flake "$FLAKE_DIR#$FLAKE_TARGET" --impure --specialisation "$SPECIALISATION" 2>&1
        REBUILD_STATUS=$?
    else
        echo "Rebuilding base configuration"
        echo "Running: sudo nixos-rebuild switch --flake $FLAKE_DIR#$FLAKE_TARGET --impure"
        echo ""
        sudo nixos-rebuild switch --flake "$FLAKE_DIR#$FLAKE_TARGET" --impure 2>&1
        REBUILD_STATUS=$?
    fi

    if [[ $REBUILD_STATUS -ne 0 ]]; then
        echo ""
        echo "ERROR: nixos-rebuild failed with exit code $REBUILD_STATUS"
        return $REBUILD_STATUS
    fi

    echo ""
    echo "System rebuild completed successfully"

    # Check home-manager status
    if systemctl is-failed --quiet home-manager-$USER.service 2>/dev/null; then
        echo "WARNING: home-manager failed during activation!"
        echo "Check with: journalctl -u home-manager-$USER.service -n 20"
    else
        echo "Home-manager configs applied successfully"
    fi

    # Force colorscheme re-application
    if systemctl list-units --type=service | grep -q "hydrix-colorscheme"; then
        echo "Applying configured colorscheme..."
        sudo systemctl restart hydrix-colorscheme.service 2>/dev/null || true
    fi

    return 0
}

# ========== VM DETECTION ==========

if [[ "$CHASSIS" == "vm" ]] || echo "$VENDOR" | grep -q "QEMU\|VMware"; then
    echo "Detected Virtual Machine"

    # Extract VM type from hostname pattern (e.g., "pentest-google" -> "pentest")
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

    if rebuild_system "$FLAKE_TARGET" ""; then
        echo ""
        echo "VM configuration applied successfully!"
        exit 0
    else
        echo ""
        echo "VM configuration failed - see errors above"
        exit 1
    fi
fi

# ========== PHYSICAL MACHINE (Always builds #host) ==========

echo "Detected Physical Machine"
echo ""

# Stage local files so nix can see them
stage_local_files

# Always build #host - machine-specific config comes from local/machines/host.nix
FLAKE_TARGET="host"

echo ""
echo "Building configuration: $FLAKE_TARGET"

# Detect and apply specialisation
CURRENT_SPEC=$(detect_specialisation)
if [[ -n "$CURRENT_SPEC" ]]; then
    echo "Current specialisation: $CURRENT_SPEC"
else
    echo "Current specialisation: (base config)"
fi
echo ""

if rebuild_system "$FLAKE_TARGET" "$CURRENT_SPEC"; then
    # Unstage local files to prevent accidental commits
    unstage_local_files

    echo ""
    echo "Configuration applied successfully!"
    [[ -z "$CURRENT_SPEC" ]] && echo "  (Running in base mode)"

    # Pre-build VM configs to update virtiofs cache
    prebuild_vm_configs
else
    # Unstage local files even on failure
    unstage_local_files

    echo ""
    echo "Configuration failed - see errors above"
    exit 1
fi
