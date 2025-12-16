#!/run/current-system/sw/bin/bash
# Legacy autostart script - actual autostart is handled by systemd services
# in the specialisation configuration. This script is kept for manual use.
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] Router: $*"; }

VIRSH="/run/current-system/sw/bin/virsh"

# Detect which router VM to use based on current mode
detect_router_vm() {
    if $VIRSH --connect qemu:///system list --all 2>/dev/null | grep -q "lockdown-router"; then
        echo "lockdown-router"
    elif $VIRSH --connect qemu:///system list --all 2>/dev/null | grep -q "router-vm"; then
        echo "router-vm"
    else
        echo ""
    fi
}

VM_NAME=$(detect_router_vm)

if [ -z "$VM_NAME" ]; then
    log "No router VM found. Please switch to a passthrough specialisation first."
    log "  sudo nixos-rebuild switch --specialisation maximalism"
    exit 1
fi

log "Found router VM: $VM_NAME"

vm_state=$($VIRSH --connect qemu:///system domstate "$VM_NAME" 2>/dev/null || echo "unknown")
log "Current state: $vm_state"

case "$vm_state" in
    "running")
        log "Router VM is already running"
        ;;
    "paused")
        log "Resuming paused router VM..."
        $VIRSH --connect qemu:///system resume "$VM_NAME"
        ;;
    "shut off"|"shutoff")
        log "Starting router VM..."
        $VIRSH --connect qemu:///system start "$VM_NAME"
        ;;
    *)
        log "Unexpected state: $vm_state - attempting start..."
        $VIRSH --connect qemu:///system start "$VM_NAME" 2>/dev/null || true
        ;;
esac

sleep 2

if $VIRSH --connect qemu:///system list | grep -q "$VM_NAME.*running"; then
    log "Router VM is running"

    # Show appropriate management IP based on VM name
    if [[ "$VM_NAME" == "lockdown-router" ]]; then
        log "Management IP: 10.100.0.253 (lockdown mode)"
    else
        log "Management IP: 192.168.100.253 (standard mode)"
    fi
else
    log "WARNING: Router VM may not have started correctly"
    exit 1
fi
