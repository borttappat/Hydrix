#!/usr/bin/env bash
# Deploy Router VM for Hydrix
# Supports router mode (default) and lockdown mode
#
# Usage:
#   ./scripts/deploy-router.sh                    # Router mode (br-* bridges, 192.168.x.x)
#   ./scripts/deploy-router.sh --lockdown         # Lockdown mode (br-* bridges, 10.100.x.x)
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
MODE="router"
FORCE_REBUILD=false

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy the Hydrix router VM.

Options:
  --router             Deploy for router mode (192.168.x.x networks) [default]
  --lockdown           Deploy for lockdown mode (10.100.x.x networks, host isolated)
  --name NAME          VM name (default: router-vm, lockdown uses lockdown-router)
  --memory MB          Memory in MB (default: 2048)
  --vcpus N            Number of vCPUs (default: 2)
  --disk SIZE          Disk size (default: 20G)
  --force-rebuild      Force rebuild of router VM image
  -h, --help           Show this help

Examples:
  $(basename "$0")                              # Router mode (default)
  $(basename "$0") --lockdown                   # Lockdown mode

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --lockdown)
            MODE="lockdown"
            VM_NAME="lockdown-router"
            shift
            ;;
        --router)
            MODE="router"
            VM_NAME="router-vm"
            shift
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

# Check if bridges exist
echo -e "${BLUE}Checking bridges...${NC}"
BRIDGES_OK=true
for br in br-mgmt br-pentest br-office br-browse br-dev; do
    if ip link show "$br" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $br exists"
    else
        echo -e "  ${RED}✗${NC} $br missing"
        BRIDGES_OK=false
    fi
done

if [[ "$BRIDGES_OK" != "true" ]]; then
    echo -e "${YELLOW}Warning: Some bridges are missing.${NC}"
    echo -e "${YELLOW}Make sure you're running in router or lockdown specialisation.${NC}"
    echo -e "${YELLOW}The VM will be defined but may not start until bridges exist.${NC}"
fi

# Build virt-install command - same bridges for both modes
# Router VM auto-detects mode based on VM name or host IP
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
    --network bridge=br-mgmt,model=virtio
    --network bridge=br-pentest,model=virtio
    --network bridge=br-office,model=virtio
    --network bridge=br-browse,model=virtio
    --network bridge=br-dev,model=virtio
)

# Create and start the VM
echo -e "${BLUE}Creating VM...${NC}"
"${VIRT_INSTALL_CMD[@]}"

echo ""
echo -e "${GREEN}=== Router VM Deployed Successfully ===${NC}"
echo ""

case "$MODE" in
    router)
        echo -e "Mode: Router (standard)"
        echo -e ""
        echo -e "Networks (192.168.x.x):"
        echo -e "  enp1s0 (br-mgmt):    192.168.100.x - Management + host"
        echo -e "  enp2s0 (br-pentest): 192.168.101.x - Pentest VMs"
        echo -e "  enp3s0 (br-office):  192.168.102.x - Office VMs"
        echo -e "  enp4s0 (br-browse):  192.168.103.x - Browse VMs"
        echo -e "  enp5s0 (br-dev):     192.168.104.x - Dev VMs"
        echo ""
        echo -e "Access:"
        echo -e "  SSH: ssh traum@192.168.100.253"
        echo -e "  Console: sudo virsh console $VM_NAME"
        echo -e "  GUI: virt-manager → $VM_NAME"
        ;;
    lockdown)
        echo -e "Mode: Lockdown (isolated)"
        echo -e ""
        echo -e "Networks (10.100.x.x):"
        echo -e "  enp1s0 (br-mgmt):    10.100.0.x - Management (no internet)"
        echo -e "  enp2s0 (br-pentest): 10.100.1.x - Pentest (VPN routed)"
        echo -e "  enp3s0 (br-office):  10.100.2.x - Office (VPN routed)"
        echo -e "  enp4s0 (br-browse):  10.100.3.x - Browse (VPN routed)"
        echo -e "  enp5s0 (br-dev):     10.100.4.x - Dev (direct/configurable)"
        echo ""
        echo -e "Access:"
        echo -e "  SSH: ssh traum@10.100.0.253"
        echo -e "  Console: sudo virsh console $VM_NAME"
        echo ""
        echo -e "VPN Management (on router):"
        echo -e "  vpn-status                     # Show status"
        echo -e "  vpn-assign pentest mullvad     # Route pentest through Mullvad"
        ;;
esac

echo ""
echo -e "${GREEN}Router VM is now running!${NC}"
