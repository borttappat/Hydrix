#!/usr/bin/env bash
# Deploy a full VM image (pre-built with all packages)
#
# Usage: ./deploy-full-vm.sh <type> <name> [--resources <low|medium|high>]
#
# Examples:
#   ./deploy-full-vm.sh pentest google
#   ./deploy-full-vm.sh pentest htb --resources high
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_usage() {
    echo "Usage: $0 <type> <name> [--resources <low|medium|high>]"
    echo ""
    echo "Types: pentest (more coming soon)"
    echo ""
    echo "Resource levels:"
    echo "  low    - 2 vCPU, 4GB RAM  (25%)"
    echo "  medium - 4 vCPU, 8GB RAM  (50%)"
    echo "  high   - 6 vCPU, 12GB RAM (75%)"
    echo ""
    echo "Examples:"
    echo "  $0 pentest google"
    echo "  $0 pentest htb --resources high"
    exit 1
}

# Parse arguments
if [ $# -lt 2 ]; then
    print_usage
fi

VM_TYPE="$1"
VM_NAME="$2"
RESOURCES="high"  # Default to high for pentest

shift 2
while [ $# -gt 0 ]; do
    case "$1" in
        --resources)
            RESOURCES="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_usage
            ;;
    esac
done

# Validate type
case "$VM_TYPE" in
    pentest)
        FLAKE_PACKAGE="pentest-vm-full"
        ;;
    *)
        echo -e "${RED}Unknown VM type: $VM_TYPE${NC}"
        echo "Available types: pentest"
        exit 1
        ;;
esac

# Calculate resources
HOST_CPUS=$(nproc)
HOST_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HOST_MEM_GB=$((HOST_MEM_KB / 1024 / 1024))

case "$RESOURCES" in
    low)
        VCPUS=$((HOST_CPUS / 4))
        MEM_GB=$((HOST_MEM_GB / 4))
        ;;
    medium)
        VCPUS=$((HOST_CPUS / 2))
        MEM_GB=$((HOST_MEM_GB / 2))
        ;;
    high)
        VCPUS=$((HOST_CPUS * 3 / 4))
        MEM_GB=$((HOST_MEM_GB * 3 / 4))
        ;;
    *)
        echo -e "${RED}Unknown resource level: $RESOURCES${NC}"
        exit 1
        ;;
esac

# Enforce minimums
[ "$VCPUS" -lt 2 ] && VCPUS=2
[ "$MEM_GB" -lt 4 ] && MEM_GB=4

MEM_MB=$((MEM_GB * 1024))
VM_FULL_NAME="${VM_TYPE}-${VM_NAME}"
IMAGE_DIR="/var/lib/libvirt/images"
DISK_SIZE="100G"

echo -e "${GREEN}=== Deploying Full VM ===${NC}"
echo "Type: $VM_TYPE"
echo "Name: $VM_FULL_NAME"
echo "Resources: $VCPUS vCPUs, ${MEM_GB}GB RAM ($RESOURCES)"
echo ""

# Check if VM already exists
if virsh list --all --name 2>/dev/null | grep -q "^${VM_FULL_NAME}$"; then
    echo -e "${YELLOW}VM '$VM_FULL_NAME' already exists.${NC}"
    read -p "Delete and recreate? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Removing existing VM..."
        virsh destroy "$VM_FULL_NAME" 2>/dev/null || true
        virsh undefine "$VM_FULL_NAME" --remove-all-storage 2>/dev/null || true
    else
        echo "Aborting."
        exit 1
    fi
fi

# Build image if needed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRIX_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${GREEN}Building full image (this may take a while on first build)...${NC}"
cd "$HYDRIX_DIR"
nix build ".#${FLAKE_PACKAGE}" --no-link --print-out-paths | head -1 > /tmp/hydrix-build-path
BUILD_PATH=$(cat /tmp/hydrix-build-path)

if [ ! -f "$BUILD_PATH/nixos.qcow2" ]; then
    echo -e "${RED}Build failed or image not found${NC}"
    exit 1
fi

echo -e "${GREEN}Image built: $BUILD_PATH/nixos.qcow2${NC}"

# Copy image
echo "Copying image to $IMAGE_DIR/${VM_FULL_NAME}.qcow2..."
sudo cp "$BUILD_PATH/nixos.qcow2" "$IMAGE_DIR/${VM_FULL_NAME}.qcow2"
sudo chmod 644 "$IMAGE_DIR/${VM_FULL_NAME}.qcow2"

# Resize disk
echo "Resizing disk to $DISK_SIZE..."
sudo qemu-img resize "$IMAGE_DIR/${VM_FULL_NAME}.qcow2" "$DISK_SIZE"

# Create VM
echo -e "${GREEN}Creating VM...${NC}"
sudo virt-install \
    --name "$VM_FULL_NAME" \
    --memory "$MEM_MB" \
    --vcpus "$VCPUS" \
    --disk "path=$IMAGE_DIR/${VM_FULL_NAME}.qcow2,format=qcow2,bus=virtio" \
    --import \
    --os-variant nixos-unstable \
    --network network=default,model=virtio \
    --graphics spice,listen=127.0.0.1 \
    --video qxl \
    --channel spicevmc,target_type=virtio,name=com.redhat.spice.0 \
    --noautoconsole

echo ""
echo -e "${GREEN}=== VM Deployed Successfully ===${NC}"
echo ""
echo "VM: $VM_FULL_NAME"
echo "Resources: $VCPUS vCPUs, ${MEM_GB}GB RAM"
echo ""
echo "Commands:"
echo "  virt-manager                    # GUI management"
echo "  virsh console $VM_FULL_NAME    # Console access"
echo "  virsh start $VM_FULL_NAME      # Start VM"
echo "  virsh shutdown $VM_FULL_NAME   # Graceful shutdown"
echo ""
echo "Inside VM, update with:"
echo "  rebuild                         # Pull + rebuild"
