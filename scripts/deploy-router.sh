#!/usr/bin/env bash
# Deploy Router VM for Hydrix
# Supports both standard and lockdown modes
#
# Usage:
#   ./scripts/deploy-router.sh                    # Standard mode (virbr bridges)
#   ./scripts/deploy-router.sh --lockdown         # Lockdown mode (br-* bridges)
#   ./scripts/deploy-router.sh --lockdown --wan enp0s31f6  # With WAN interface
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRIX_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="router-vm"
MEMORY=2048
VCPUS=2
DISK_SIZE="20G"
IMAGE_DIR="/var/lib/libvirt/images"
MODE="standard"
WAN_INTERFACE=""
FORCE_REBUILD=false

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy the Hydrix router VM.

Options:
  --lockdown           Deploy for lockdown mode (uses br-* bridges)
  --standard           Deploy for standard mode (uses virbr* bridges) [default]
  --wan INTERFACE      Physical interface for WAN (lockdown mode only)
  --name NAME          VM name (default: router-vm)
  --memory MB          Memory in MB (default: 2048)
  --vcpus N            Number of vCPUs (default: 2)
  --disk SIZE          Disk size (default: 20G)
  --force-rebuild      Force rebuild of router VM image
  -h, --help           Show this help

Examples:
  $(basename "$0")                              # Standard mode
  $(basename "$0") --lockdown                   # Lockdown mode
  $(basename "$0") --lockdown --wan enp0s31f6   # Lockdown with WAN bridge

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --lockdown)
            MODE="lockdown"
            shift
            ;;
        --standard)
            MODE="standard"
            shift
            ;;
        --wan)
            WAN_INTERFACE="$2"
            shift 2
            ;;
        --name)
            VM_NAME="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --vcpus)
            VCPUS="$2"
            shift 2
            ;;
        --disk)
            DISK_SIZE="$2"
            shift 2
            ;;
        --force-rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

echo -e "${BLUE}=== Hydrix Router VM Deployment ===${NC}"
echo -e "Mode: ${GREEN}$MODE${NC}"
echo -e "VM Name: $VM_NAME"
echo -e "Memory: ${MEMORY}MB, vCPUs: $VCPUS"

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Note: This script may need sudo for some operations${NC}"
fi

# Build router VM image if needed
IMAGE_PATH="$IMAGE_DIR/${VM_NAME}.qcow2"
BUILD_RESULT="$HYDRIX_DIR/result/nixos.qcow2"

if [[ "$FORCE_REBUILD" == "true" ]] || [[ ! -f "$BUILD_RESULT" ]]; then
    echo -e "${BLUE}Building router VM image...${NC}"
    cd "$HYDRIX_DIR"
    nix build '.#router-vm' --out-link result
fi

# Copy image if not exists or force rebuild
if [[ "$FORCE_REBUILD" == "true" ]] || [[ ! -f "$IMAGE_PATH" ]]; then
    echo -e "${BLUE}Copying image to $IMAGE_PATH...${NC}"
    sudo mkdir -p "$IMAGE_DIR"
    sudo cp "$BUILD_RESULT" "$IMAGE_PATH"
    sudo chmod 644 "$IMAGE_PATH"

    # Resize disk
    echo -e "${BLUE}Resizing disk to $DISK_SIZE...${NC}"
    sudo qemu-img resize "$IMAGE_PATH" "$DISK_SIZE"
fi

# Check if VM already exists
if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
    echo -e "${YELLOW}VM '$VM_NAME' already exists.${NC}"
    read -p "Destroy and recreate? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Destroying existing VM...${NC}"
        sudo virsh destroy "$VM_NAME" 2>/dev/null || true
        sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
        # Re-copy image since we removed it
        sudo cp "$BUILD_RESULT" "$IMAGE_PATH"
        sudo qemu-img resize "$IMAGE_PATH" "$DISK_SIZE"
    else
        echo -e "${YELLOW}Keeping existing VM. Use --force-rebuild to recreate.${NC}"
        exit 0
    fi
fi

# Build virt-install command based on mode
VIRT_INSTALL_CMD=(
    sudo virt-install
    --name "$VM_NAME"
    --memory "$MEMORY"
    --vcpus "$VCPUS"
    --disk "path=$IMAGE_PATH,format=qcow2,bus=virtio"
    --import
    --os-variant nixos-unstable
    --graphics spice
    --video virtio
    --channel spicevmc,target_type=virtio,name=com.redhat.spice.0
    --noautoconsole
    --autostart
)

case "$MODE" in
    standard)
        echo -e "${BLUE}Configuring for standard mode (virbr bridges)...${NC}"
        VIRT_INSTALL_CMD+=(
            --network bridge=virbr0,model=virtio      # WAN (NAT from host)
            --network bridge=virbr1,model=virtio      # Guest network 1
            --network bridge=virbr2,model=virtio      # Guest network 2
            --network bridge=virbr3,model=virtio      # Guest network 3
            --network bridge=virbr4,model=virtio      # Guest network 4
        )
        ;;
    lockdown)
        echo -e "${BLUE}Configuring for lockdown mode (br-* bridges)...${NC}"

        # Check if bridges exist
        for br in br-wan br-mgmt br-pentest br-office br-browse br-dev; do
            if ! ip link show "$br" &>/dev/null; then
                echo -e "${YELLOW}Warning: Bridge $br does not exist${NC}"
                echo -e "${YELLOW}Make sure you're running in lockdown specialisation${NC}"
            fi
        done

        VIRT_INSTALL_CMD+=(
            --network bridge=br-wan,model=virtio      # WAN (gets DHCP or upstream)
            --network bridge=br-mgmt,model=virtio     # Management (10.100.0.x)
            --network bridge=br-pentest,model=virtio  # Pentest (10.100.1.x)
            --network bridge=br-office,model=virtio   # Office (10.100.2.x)
            --network bridge=br-browse,model=virtio   # Browse (10.100.3.x)
            --network bridge=br-dev,model=virtio      # Dev (10.100.4.x)
        )

        # If WAN interface specified, add physical interface to br-wan
        if [[ -n "$WAN_INTERFACE" ]]; then
            echo -e "${BLUE}Adding $WAN_INTERFACE to br-wan...${NC}"
            if ip link show "$WAN_INTERFACE" &>/dev/null; then
                sudo ip link set "$WAN_INTERFACE" master br-wan 2>/dev/null || true
                sudo ip link set "$WAN_INTERFACE" up
            else
                echo -e "${RED}Warning: Interface $WAN_INTERFACE not found${NC}"
            fi
        fi
        ;;
esac

# Create and start the VM
echo -e "${BLUE}Creating VM...${NC}"
"${VIRT_INSTALL_CMD[@]}"

echo ""
echo -e "${GREEN}=== Router VM Deployed Successfully ===${NC}"
echo ""

case "$MODE" in
    standard)
        echo -e "Networks:"
        echo -e "  enp1s0 (virbr0): NAT to host internet"
        echo -e "  enp2s0-enp5s0: Guest networks 192.168.100-103.x"
        echo ""
        echo -e "Access:"
        echo -e "  Console: sudo virsh console $VM_NAME"
        echo -e "  GUI: virt-manager → $VM_NAME"
        ;;
    lockdown)
        echo -e "Networks:"
        echo -e "  enp1s0 (br-wan):     WAN uplink"
        echo -e "  enp2s0 (br-mgmt):    10.100.0.x - Management"
        echo -e "  enp3s0 (br-pentest): 10.100.1.x - Pentest (VPN routed)"
        echo -e "  enp4s0 (br-office):  10.100.2.x - Office (VPN routed)"
        echo -e "  enp5s0 (br-browse):  10.100.3.x - Browse (VPN routed)"
        echo -e "  enp6s0 (br-dev):     10.100.4.x - Dev (direct/configurable)"
        echo ""
        echo -e "Access:"
        echo -e "  SSH: ssh traum@10.100.0.253 (from management network)"
        echo -e "  Console: sudo virsh console $VM_NAME"
        echo ""
        echo -e "VPN Management (on router):"
        echo -e "  vpn-status                     # Show status"
        echo -e "  vpn-assign pentest mullvad     # Route pentest through Mullvad"
        echo -e "  vpn-assign connect mullvad     # Connect VPN first"
        ;;
esac

echo ""
echo -e "${GREEN}Router VM is now running!${NC}"
