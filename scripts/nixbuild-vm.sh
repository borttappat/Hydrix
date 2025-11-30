#!/usr/bin/env bash
# VM-specific nixbuild script
# Detects VM type from hostname and rebuilds with appropriate flake entry

set -euo pipefail

readonly HYDRIX_DIR="/etc/nixos/hydrix"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }

detect_vm_type() {
    local hostname=$(hostname)

    # Extract VM type from hostname (e.g., "pentest-google" -> "pentest")
    local vm_type="${hostname%%-*}"

    log "Detected hostname: $hostname"
    log "Extracted VM type: $vm_type"

    echo "$vm_type"
}

get_flake_entry() {
    local vm_type=$1

    case "$vm_type" in
        pentest)
            echo "vm-pentest"
            ;;
        comms)
            echo "vm-comms"
            ;;
        browsing)
            echo "vm-browsing"
            ;;
        dev)
            echo "vm-dev"
            ;;
        *)
            error "Unknown VM type: $vm_type. Expected: pentest, comms, browsing, or dev"
            ;;
    esac
}

main() {
    log "=== Hydrix VM Rebuild ==="

    # Check if Hydrix directory exists
    if [[ ! -d "$HYDRIX_DIR" ]]; then
        error "Hydrix directory not found at: $HYDRIX_DIR"
    fi

    # Detect VM type
    VM_TYPE=$(detect_vm_type)
    FLAKE_ENTRY=$(get_flake_entry "$VM_TYPE")

    log "VM Type: $VM_TYPE"
    log "Flake Entry: $FLAKE_ENTRY"
    log "Rebuilding system..."

    # Change to Hydrix directory
    cd "$HYDRIX_DIR"

    # Perform rebuild with impure mode (needed for some packages)
    if nixos-rebuild switch --flake ".#$FLAKE_ENTRY" --impure; then
        success "System rebuild completed successfully"
    else
        error "System rebuild failed"
    fi
}

main "$@"
