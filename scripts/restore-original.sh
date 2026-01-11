#!/usr/bin/env bash
# restore-original.sh - Restore to original Hydrix setup
#
# This script helps switch back from local-hydrix to the original ~/Hydrix setup.
# Useful when testing the rework branch and needing to revert.
#
# Usage:
#   ./scripts/restore-original.sh              # Interactive mode
#   ./scripts/restore-original.sh --rebuild    # Backup local-hydrix and rebuild from ~/Hydrix
#   ./scripts/restore-original.sh --relink     # Re-run setup-local.sh from ~/Hydrix
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Paths
ORIGINAL_HYDRIX="$HOME/Hydrix"
LOCAL_HYDRIX="$HOME/local-hydrix"
BACKUP_DIR="$HOME/local-hydrix-backup-$(date +%Y%m%d-%H%M%S)"

show_help() {
    cat << 'EOF'
Restore Original Hydrix Setup

This script helps you switch back from the rework branch to your original
~/Hydrix setup.

Options:
  --rebuild     Backup local-hydrix, then rebuild system from ~/Hydrix
  --relink      Re-run setup-local.sh from ~/Hydrix (creates new local-hydrix)
  --backup-only Just backup local-hydrix without rebuilding
  --status      Show current setup status
  -h, --help    Show this help

What each option does:

  --rebuild:
    1. Backs up ~/local-hydrix to ~/local-hydrix-backup-<timestamp>
    2. Runs nixos-rebuild from ~/Hydrix (your original config)
    3. You'll need to reboot after

  --relink:
    1. Backs up existing ~/local-hydrix
    2. Runs setup-local.sh from ~/Hydrix
    3. Creates fresh ~/local-hydrix with symlinks to ~/Hydrix
    4. Builds system from the new local-hydrix

  --backup-only:
    Just creates a backup without any rebuild

Recovery if something breaks:
  cd ~/Hydrix
  sudo nixos-rebuild switch --flake .#$(hostname)
EOF
    exit 0
}

show_status() {
    echo ""
    log "Current Setup Status"
    echo "===================="
    echo ""

    # Check original Hydrix
    if [[ -d "$ORIGINAL_HYDRIX" ]]; then
        echo -e "Original Hydrix: ${GREEN}$ORIGINAL_HYDRIX${NC} (exists)"
        if [[ -f "$ORIGINAL_HYDRIX/flake.nix" ]]; then
            echo "  - Has flake.nix"
        fi
    else
        echo -e "Original Hydrix: ${RED}$ORIGINAL_HYDRIX${NC} (NOT FOUND)"
    fi
    echo ""

    # Check local-hydrix
    if [[ -d "$LOCAL_HYDRIX" ]]; then
        echo -e "Local Hydrix: ${GREEN}$LOCAL_HYDRIX${NC} (exists)"

        # Check where symlinks point
        if [[ -L "$LOCAL_HYDRIX/modules" ]]; then
            local target=$(readlink "$LOCAL_HYDRIX/modules")
            echo "  - modules → $target"
            if [[ "$target" == *"Hydrix-rework"* ]]; then
                echo -e "    ${YELLOW}(pointing to rework branch)${NC}"
            elif [[ "$target" == *"Hydrix"* ]]; then
                echo -e "    ${GREEN}(pointing to original)${NC}"
            fi
        fi
    else
        echo -e "Local Hydrix: ${YELLOW}$LOCAL_HYDRIX${NC} (not created yet)"
    fi
    echo ""

    # Check current system
    echo "Current System:"
    echo "  Hostname: $(hostname)"
    if [[ -f /run/current-system/nixos-version ]]; then
        echo "  NixOS: $(cat /run/current-system/nixos-version)"
    fi
    echo ""
}

backup_local_hydrix() {
    if [[ ! -d "$LOCAL_HYDRIX" ]]; then
        log "No local-hydrix to backup"
        return 0
    fi

    log "Backing up $LOCAL_HYDRIX to $BACKUP_DIR..."

    # Copy instead of move to preserve any running references
    cp -a "$LOCAL_HYDRIX" "$BACKUP_DIR"

    success "Backup created: $BACKUP_DIR"

    # Now remove the original
    log "Removing $LOCAL_HYDRIX..."
    rm -rf "$LOCAL_HYDRIX"

    success "local-hydrix removed"
}

rebuild_from_original() {
    log "Rebuilding system from original Hydrix..."

    if [[ ! -d "$ORIGINAL_HYDRIX" ]]; then
        error "Original Hydrix not found at $ORIGINAL_HYDRIX"
    fi

    if [[ ! -f "$ORIGINAL_HYDRIX/flake.nix" ]]; then
        error "No flake.nix in $ORIGINAL_HYDRIX"
    fi

    cd "$ORIGINAL_HYDRIX"

    local hostname=$(hostname)
    log "Running: nixos-rebuild boot --flake .#$hostname"

    if sudo nixos-rebuild boot --flake ".#$hostname"; then
        success "System rebuilt from original Hydrix"
        echo ""
        warn "Reboot required to activate changes"
        echo "  sudo reboot"
    else
        error "Rebuild failed"
    fi
}

relink_from_original() {
    log "Re-running setup from original Hydrix..."

    if [[ ! -d "$ORIGINAL_HYDRIX" ]]; then
        error "Original Hydrix not found at $ORIGINAL_HYDRIX"
    fi

    if [[ ! -x "$ORIGINAL_HYDRIX/scripts/setup-local.sh" ]]; then
        error "setup-local.sh not found in $ORIGINAL_HYDRIX"
    fi

    cd "$ORIGINAL_HYDRIX"
    ./scripts/setup-local.sh
}

interactive_mode() {
    echo ""
    log "Restore Original Hydrix Setup"
    echo "=============================="
    echo ""

    show_status

    echo "What would you like to do?"
    echo ""
    echo "  1) Backup local-hydrix and rebuild from ~/Hydrix"
    echo "  2) Re-run setup-local.sh from ~/Hydrix (fresh local-hydrix)"
    echo "  3) Just backup local-hydrix (no rebuild)"
    echo "  4) Cancel"
    echo ""

    read -p "Choice [1-4]: " choice

    case "$choice" in
        1)
            backup_local_hydrix
            rebuild_from_original
            ;;
        2)
            backup_local_hydrix
            relink_from_original
            ;;
        3)
            backup_local_hydrix
            success "Backup complete. No rebuild performed."
            ;;
        4)
            log "Cancelled"
            exit 0
            ;;
        *)
            error "Invalid choice"
            ;;
    esac
}

main() {
    case "${1:-}" in
        --help|-h)
            show_help
            ;;
        --status)
            show_status
            ;;
        --rebuild)
            backup_local_hydrix
            rebuild_from_original
            ;;
        --relink)
            backup_local_hydrix
            relink_from_original
            ;;
        --backup-only)
            backup_local_hydrix
            success "Backup complete"
            ;;
        "")
            interactive_mode
            ;;
        *)
            error "Unknown option: $1. Use --help for usage."
            ;;
    esac
}

main "$@"
