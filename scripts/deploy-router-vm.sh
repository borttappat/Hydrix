#!/usr/bin/env bash
set -euo pipefail

# Router VM Deployment Script
# Builds (if needed) and deploys the router VM with WiFi passthrough
#
# Usage:
#   ./scripts/deploy-router-vm.sh              # Standard router mode
#   ./scripts/deploy-router-vm.sh --lockdown   # Lockdown mode (different VM name)
#   ./scripts/deploy-router-vm.sh --force      # Force rebuild

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly LIBVIRT_IMAGE="/var/lib/libvirt/images/router-vm.qcow2"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] $*"; }
error() { echo -e "${RED}[$(date +%H:%M:%S)] ERROR: $*${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] $*${NC}"; }

# Defaults
VM_NAME="router-vm"
MODE="router"
FORCE_REBUILD=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --lockdown)
            MODE="lockdown"
            VM_NAME="lockdown-router"
            shift
            ;;
        --force|--force-rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --lockdown      Deploy as lockdown-router (10.100.x.x mode)"
            echo "  --force         Force rebuild of router VM image"
            echo "  -h, --help      Show this help"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Detect WiFi hardware for passthrough
detect_wifi_hardware() {
    log "Detecting WiFi hardware..."

    # Find wireless interfaces
    local wifi_interface
    wifi_interface=$(find /sys/class/net -maxdepth 1 -name "wl*" -exec basename {} \; 2>/dev/null | head -1)

    if [[ -z "$wifi_interface" ]]; then
        # Try alternative detection
        wifi_interface=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
    fi

    if [[ -z "$wifi_interface" ]]; then
        warn "No WiFi interface found - VM will be created without passthrough"
        return 1
    fi

    # Get PCI address
    local pci_path
    pci_path=$(readlink -f "/sys/class/net/$wifi_interface/device" 2>/dev/null)

    if [[ -z "$pci_path" ]]; then
        warn "Could not determine PCI address for $wifi_interface"
        return 1
    fi

    WIFI_PCI=$(basename "$pci_path")
    WIFI_PCI_SHORT="${WIFI_PCI#0000:}"

    # Get device ID for VFIO
    WIFI_DEVICE_ID=$(lspci -n -s "$WIFI_PCI" 2>/dev/null | awk '{print $3}')

    log "  Interface: $wifi_interface"
    log "  PCI Address: $WIFI_PCI"
    log "  Device ID: $WIFI_DEVICE_ID"

    return 0
}

# Build router VM image if needed
build_router_vm() {
    cd "$PROJECT_DIR"

    # Check if image already exists
    if [[ "$FORCE_REBUILD" != true ]] && [[ -f "$LIBVIRT_IMAGE" ]]; then
        local size
        size=$(sudo du -h "$LIBVIRT_IMAGE" 2>/dev/null | cut -f1)
        log "Router VM image already exists: $LIBVIRT_IMAGE ($size)"
        log "Use --force to rebuild"
        return 0
    fi

    log "Building router VM image (this may take several minutes)..."

    # Build using nix
    if ! nix build '.#router-vm' --out-link router-vm-result; then
        error "Router VM build failed"
    fi

    if [[ ! -f "router-vm-result/nixos.qcow2" ]]; then
        error "Router VM build completed but no qcow2 found"
    fi

    local size
    size=$(du -h router-vm-result/nixos.qcow2 | cut -f1)
    success "Router VM built: $size"

    # Copy to libvirt storage
    log "Installing to libvirt storage..."
    sudo mkdir -p /var/lib/libvirt/images
    sudo cp "router-vm-result/nixos.qcow2" "$LIBVIRT_IMAGE"
    sudo chmod 644 "$LIBVIRT_IMAGE"

    success "Router VM image installed: $LIBVIRT_IMAGE"
}

# Check if required bridges exist
check_bridges() {
    log "Checking bridges..."
    local all_ok=true

    for br in br-mgmt br-pentest br-office br-browse br-dev; do
        if ip link show "$br" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $br"
        else
            echo -e "  ${RED}✗${NC} $br (missing)"
            all_ok=false
        fi
    done

    if [[ "$all_ok" != true ]]; then
        warn "Some bridges are missing."
        warn "Make sure you've booted into router mode (base config) or rebooted after setup."
        warn "The VM will be defined but may not start until bridges exist."
        return 1
    fi

    return 0
}

# Deploy the VM
deploy_vm() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run with sudo"
    fi

    # Check if libvirtd is running
    if ! systemctl is-active --quiet libvirtd; then
        log "Starting libvirtd..."
        systemctl start libvirtd
        sleep 3
    fi

    # Check if VM already exists
    if virsh --connect qemu:///system dominfo "$VM_NAME" &>/dev/null; then
        warn "VM '$VM_NAME' already exists"
        read -p "Destroy and recreate? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Destroying existing VM..."
            virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
            virsh --connect qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
        else
            log "Keeping existing VM."
            exit 0
        fi
    fi

    # Check image exists
    if [[ ! -f "$LIBVIRT_IMAGE" ]]; then
        error "Router VM image not found at: $LIBVIRT_IMAGE\nRun: nix build '.#router-vm' first, or re-run setup-machine.sh"
    fi

    # Check bridges
    check_bridges || true

    # Build virt-install command
    local virt_cmd=(
        virt-install
        --connect qemu:///system
        --name "$VM_NAME"
        --memory 2048
        --vcpus 2
        --disk "$LIBVIRT_IMAGE,device=disk,bus=virtio"
        --os-variant nixos-unstable
        --boot hd
        --graphics spice
        --video virtio
        --network bridge=br-mgmt,model=virtio
        --network bridge=br-pentest,model=virtio
        --network bridge=br-office,model=virtio
        --network bridge=br-browse,model=virtio
        --network bridge=br-dev,model=virtio
        --noautoconsole
        --autostart
        --import
    )

    # Try with WiFi passthrough first
    if detect_wifi_hardware; then
        log "Creating VM with WiFi passthrough (PCI: $WIFI_PCI_SHORT)..."

        if "${virt_cmd[@]}" --hostdev "$WIFI_PCI_SHORT" 2>/dev/null; then
            success "Router VM deployed with WiFi passthrough!"
        else
            warn "WiFi passthrough failed - is VFIO enabled? Is the driver blacklisted?"
            warn "Creating VM without passthrough..."

            if "${virt_cmd[@]}" 2>/dev/null; then
                success "Router VM deployed (without WiFi passthrough)"
                warn "WiFi passthrough requires:"
                warn "  1. VFIO kernel params (intel_iommu=on iommu=pt)"
                warn "  2. WiFi driver blacklisted (e.g., iwlwifi)"
                warn "  3. Reboot after changing kernel params"
            else
                error "Failed to create VM"
            fi
        fi
    else
        log "Creating VM without WiFi passthrough..."
        if "${virt_cmd[@]}"; then
            success "Router VM deployed (no WiFi detected for passthrough)"
        else
            error "Failed to create VM"
        fi
    fi
}

# Show completion info
show_info() {
    echo ""
    echo -e "${GREEN}=== Router VM Deployed ===${NC}"
    echo ""

    case "$MODE" in
        router)
            echo "Mode: Router (standard)"
            echo ""
            echo "Networks (192.168.x.x - router provides DHCP):"
            echo "  br-mgmt:    192.168.100.0/24 (management + host)"
            echo "  br-pentest: 192.168.101.0/24"
            echo "  br-office:  192.168.102.0/24"
            echo "  br-browse:  192.168.103.0/24"
            echo "  br-dev:     192.168.104.0/24"
            echo ""
            echo "Access:"
            echo "  SSH:     ssh traum@192.168.100.253"
            echo "  Console: sudo virsh console $VM_NAME"
            echo "  GUI:     virt-manager → $VM_NAME"
            ;;
        lockdown)
            echo "Mode: Lockdown (isolated)"
            echo ""
            echo "Networks (10.100.x.x - VPN policy routing):"
            echo "  br-mgmt:    10.100.0.0/24 (management, no internet)"
            echo "  br-pentest: 10.100.1.0/24 (VPN routed)"
            echo "  br-office:  10.100.2.0/24 (VPN routed)"
            echo "  br-browse:  10.100.3.0/24 (VPN routed)"
            echo "  br-dev:     10.100.4.0/24 (configurable)"
            echo ""
            echo "Access:"
            echo "  SSH:     ssh traum@10.100.0.253"
            echo "  Console: sudo virsh console $VM_NAME"
            ;;
    esac

    echo ""
    echo "Status: $(virsh --connect qemu:///system domstate "$VM_NAME" 2>/dev/null || echo 'unknown')"
}

# Main
main() {
    echo -e "${BLUE}=== Hydrix Router VM Deployment ===${NC}"
    echo "Mode: $MODE"
    echo "VM Name: $VM_NAME"
    echo ""

    build_router_vm
    deploy_vm
    show_info
}

main
