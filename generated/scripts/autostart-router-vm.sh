#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly VM_NAME="router-vm-passthrough"
log() { echo "[$(date +%H:%M:%S)] Router Autostart: $*"; }

VIRSH="/run/current-system/sw/bin/virsh"
SYSTEMCTL="/run/current-system/sw/bin/systemctl"

log "Starting router VM autostart process..."

if ! $SYSTEMCTL is-active --quiet libvirtd; then
    log "Starting libvirtd service..."
    $SYSTEMCTL start libvirtd
    sleep 3
fi

sleep 2

if ! $VIRSH --connect qemu:///system list --all | grep -q "$VM_NAME"; then
    log "ERROR: Router VM '$VM_NAME' not found"
    log "Please run deploy-router-vm.sh first"
    exit 1
fi

vm_state=$($VIRSH --connect qemu:///system list --all | grep "$VM_NAME" | awk '{print $3}' || echo "unknown")
log "Router VM current state: $vm_state"

case "$vm_state" in
    "running")
        log "Router VM is already running"
        ;;
    "paused")
        log "Router VM is paused, resuming..."
        if $VIRSH --connect qemu:///system resume "$VM_NAME" 2>&1; then
            log "Router VM resumed successfully"
            sleep 2
        else
            # Check if VM is actually running (race condition)
            sleep 1
            current_state=$($VIRSH --connect qemu:///system domstate "$VM_NAME" || echo "unknown")
            if [ "$current_state" = "running" ]; then
                log "Router VM transitioned to running state (race condition handled)"
            else
                log "ERROR: Failed to resume router VM (current state: $current_state)"
                exit 1
            fi
        fi
        ;;
    "shut"|"shutoff")
        log "Starting router VM..."
        if $VIRSH --connect qemu:///system start "$VM_NAME" 2>&1; then
            log "Router VM started successfully"
            sleep 2
        else
            # Check if VM is actually running (race condition)
            sleep 1
            current_state=$($VIRSH --connect qemu:///system domstate "$VM_NAME" || echo "unknown")
            if [ "$current_state" = "running" ]; then
                log "Router VM transitioned to running state (race condition handled)"
            else
                log "ERROR: Failed to start router VM (current state: $current_state)"
                exit 1
            fi
        fi
        ;;
    *)
        log "Router VM in unexpected state: $vm_state"
        log "Attempting to start anyway..."
        if $VIRSH --connect qemu:///system start "$VM_NAME" 2>&1; then
            log "Router VM started despite unexpected state"
            sleep 2
        else
            # Check if VM is actually running (race condition)
            sleep 1
            current_state=$($VIRSH --connect qemu:///system domstate "$VM_NAME" || echo "unknown")
            if [ "$current_state" = "running" ]; then
                log "Router VM transitioned to running state (race condition handled)"
            else
                log "ERROR: Failed to start router VM (current state: $current_state)"
                exit 1
            fi
        fi
        ;;
esac

if $VIRSH --connect qemu:///system list | grep -q "$VM_NAME.*running"; then
    log "[+] Router VM is running and ready"
    log "[+] Management interface: 192.168.100.253"
else
    log "[!] Router VM startup verification failed"
    exit 1
fi

log "Router VM autostart completed successfully"
