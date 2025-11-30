#!/usr/bin/env bash
set -euo pipefail

# Router VM Deployment Script
# Simplified version matching splix approach - no mode checking

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VM_NAME="router-vm-passthrough"
readonly VM_IMAGE_SOURCE="$SCRIPT_DIR/result/nixos.qcow2"
readonly VM_IMAGE_DEST="/var/lib/libvirt/images/$VM_NAME.qcow2"
readonly WIFI_PCI_ID="0000:00:14.3"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    error "This script must be run with sudo"
fi

# Check if VM image exists
if [[ ! -f "$VM_IMAGE_SOURCE" ]]; then
    error "Router VM image not found at: $VM_IMAGE_SOURCE"
    error "Run: nix build '.#router-vm'"
fi

# Check if libvirtd is running
if ! systemctl is-active --quiet libvirtd; then
    log "Starting libvirtd..."
    systemctl start libvirtd
    sleep 3
fi

# Check if VM already exists
if virsh --connect qemu:///system list --all | grep -q "$VM_NAME"; then
    log "VM '$VM_NAME' already exists"
    read -p "Destroy and recreate? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Destroying existing VM..."
        virsh --connect qemu:///system destroy "$VM_NAME" 2>/dev/null || true
        virsh --connect qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || true
        rm -f "$VM_IMAGE_DEST"
    else
        log "Keeping existing VM. Exiting."
        exit 0
    fi
fi

# Copy VM image to libvirt storage
log "Copying VM image to $VM_IMAGE_DEST..."
cp "$VM_IMAGE_SOURCE" "$VM_IMAGE_DEST"
chmod 644 "$VM_IMAGE_DEST"
chown root:root "$VM_IMAGE_DEST"

# Create VM - try with VFIO first, fallback to without
log "Creating router VM..."
if virt-install \
  --connect qemu:///system \
  --name "$VM_NAME" \
  --memory 2048 \
  --vcpus 2 \
  --disk "$VM_IMAGE_DEST,device=disk,bus=virtio" \
  --os-variant nixos-unstable \
  --boot hd \
  --nographics \
  --network bridge=virbr1,model=virtio \
  --network bridge=virbr2,model=virtio \
  --network bridge=virbr3,model=virtio \
  --network bridge=virbr4,model=virtio \
  --network bridge=virbr5,model=virtio \
  --hostdev 00:14.3 \
  --noautoconsole \
  --import 2>/dev/null; then
    log "✓ Router VM deployed with WiFi passthrough!"
else
    log "WiFi passthrough failed, creating without passthrough..."
    virt-install \
      --connect qemu:///system \
      --name "$VM_NAME" \
      --memory 2048 \
      --vcpus 2 \
      --disk "$VM_IMAGE_DEST,device=disk,bus=virtio" \
      --os-variant nixos-unstable \
      --boot hd \
      --nographics \
      --network bridge=virbr1,model=virtio \
      --network bridge=virbr2,model=virtio \
      --network bridge=virbr3,model=virtio \
      --network bridge=virbr4,model=virtio \
      --network bridge=virbr5,model=virtio \
      --noautoconsole \
      --import
    log "✓ Router VM deployed (without WiFi passthrough)"
fi

log ""
log "Next steps:"
log "  1. Check VM status: sudo virsh --connect qemu:///system list --all"
log "  2. Connect to console: sudo virsh --connect qemu:///system console $VM_NAME"
log "  3. Check network in VM: ip a"
