#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly BASE_IMAGE_RESULT="$PROJECT_DIR/result/nixos.qcow2"

# Host system detection
HOST_CORES=$(nproc)
HOST_RAM_MB=$(free -m | grep '^Mem:' | awk '{print $2}')

# Minimum allocations
MIN_VCPUS=2
MIN_MEMORY=2048

# VM configuration (will be set based on type)
VM_TYPE=""
VM_NAME=""
VM_MEMORY=""
VM_VCPUS=""
VM_DISK_SIZE="100G"
VM_BRIDGE="virbr2"
FORCE_REBUILD=false

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }

print_usage() {
    cat << EOF
Usage: $0 --type TYPE --name NAME [OPTIONS]

Hydrix VM Deployment System
Builds universal base image and deploys type-specific VMs

Required Arguments:
  --type TYPE           VM type: pentest, comms, browsing, dev
  --name NAME           VM instance name (e.g., google, signal, leisure, rust)

Optional Arguments:
  --force-rebuild       Rebuild base image even if it exists
  --disk SIZE          Disk size (default: 100G)
  --bridge BRIDGE      Network bridge (default: virbr2)
  -h, --help           Show this help

VM Types and Resource Allocation:
  pentest    - Pentesting tools (75% CPU/RAM) - Red theme
  comms      - Communication apps (25% CPU/RAM) - Blue theme
  browsing   - Web browsing/media (50% CPU/RAM) - Green theme
  dev        - Development tools (75% CPU/RAM) - Purple theme

Host System:
  CPU Cores: $HOST_CORES
  RAM: ${HOST_RAM_MB}MB (~$((HOST_RAM_MB / 1024))GB)

Examples:
  # Deploy pentest VM named "google" (hostname: pentest-google)
  $0 --type pentest --name google

  # Deploy comms VM named "signal" (hostname: comms-signal)
  $0 --type comms --name signal

  # Deploy dev VM with custom disk size
  $0 --type dev --name rust --disk 200G

Workflow:
  1. Check if base image exists (builds if missing)
  2. Calculate resources based on VM type
  3. Create VM with hostname "<type>-<name>"
  4. First boot: shaping service applies full profile

EOF
    exit 0
}

get_resource_allocation() {
    local type=$1
    local percent=0

    case "$type" in
        pentest)
            percent=75
            log "Pentest VM - High performance allocation (75%)"
            ;;
        dev)
            percent=75
            log "Dev VM - High performance allocation (75%)"
            ;;
        browsing)
            percent=50
            log "Browsing VM - Moderate allocation (50%)"
            ;;
        comms)
            percent=25
            log "Comms VM - Light allocation (25%)"
            ;;
        *)
            error "Unknown VM type: $type. Valid types: pentest, comms, browsing, dev"
            ;;
    esac

    # Calculate resources
    VM_VCPUS=$((HOST_CORES * percent / 100))
    VM_MEMORY=$((HOST_RAM_MB * percent / 100))

    # Ensure minimums
    if [[ $VM_VCPUS -lt $MIN_VCPUS ]]; then
        VM_VCPUS=$MIN_VCPUS
    fi
    if [[ $VM_MEMORY -lt $MIN_MEMORY ]]; then
        VM_MEMORY=$MIN_MEMORY
    fi

    log "Allocated Resources:"
    log "  vCPUs: $VM_VCPUS (of $HOST_CORES available)"
    log "  RAM: ${VM_MEMORY}MB (~$((VM_MEMORY / 1024))GB)"
    log "  Disk: $VM_DISK_SIZE"
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        print_usage
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --type)
                [[ -z "${2:-}" ]] && error "--type requires a value"
                VM_TYPE="$2"
                shift 2
                ;;
            --name)
                [[ -z "${2:-}" ]] && error "--name requires a value"
                VM_NAME="$2"
                shift 2
                ;;
            --disk)
                [[ -z "${2:-}" ]] && error "--disk requires a value"
                VM_DISK_SIZE="$2"
                shift 2
                ;;
            --bridge)
                [[ -z "${2:-}" ]] && error "--bridge requires a value"
                VM_BRIDGE="$2"
                shift 2
                ;;
            --force-rebuild)
                FORCE_REBUILD=true
                shift
                ;;
            -h|--help)
                print_usage
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done

    # Validate required arguments
    [[ -z "$VM_TYPE" ]] && error "Missing required argument: --type"
    [[ -z "$VM_NAME" ]] && error "Missing required argument: --name"

    # Validate VM type
    case "$VM_TYPE" in
        pentest|comms|browsing|dev)
            ;;
        *)
            error "Invalid VM type: $VM_TYPE. Valid types: pentest, comms, browsing, dev"
            ;;
    esac
}

check_dependencies() {
    log "Checking dependencies..."
    local missing=()

    for cmd in nix virsh virt-install qemu-img virt-customize; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}\nInstall with: nix-shell -p libvirt qemu libguestfs"
    fi

    if ! sudo systemctl is-active --quiet libvirtd; then
        log "Starting libvirtd..."
        sudo systemctl start libvirtd
    fi

    if [[ -r /dev/kvm ]]; then
        log "KVM acceleration available"
    else
        log "WARNING: KVM not available, performance may be limited"
    fi
}

check_base_image() {
    log "=== Checking Base Image ==="

    if [[ "$FORCE_REBUILD" == true ]]; then
        log "Force rebuild requested"
        build_base_image
        return
    fi

    if [[ -f "$BASE_IMAGE_RESULT" ]]; then
        local size=$(du -h "$BASE_IMAGE_RESULT" | cut -f1)
        success "Base image exists: $BASE_IMAGE_RESULT ($size)"
        return
    fi

    log "Base image not found at: $BASE_IMAGE_RESULT"
    read -p "Build base image now? [Y/n]: " -r build_choice
    build_choice=${build_choice,,}

    if [[ $build_choice =~ ^(n|no)$ ]]; then
        error "Base image required. Exiting."
    fi

    build_base_image
}

build_base_image() {
    log "=== Building Universal Base Image ==="
    log "This may take 10-15 minutes on first build..."

    cd "$PROJECT_DIR"

    if ! nix build .#base-vm-qcow --print-build-logs; then
        error "Base image build failed"
    fi

    if [[ -f "$BASE_IMAGE_RESULT" ]]; then
        local size=$(du -h "$BASE_IMAGE_RESULT" | cut -f1)
        success "Base image built successfully: $BASE_IMAGE_RESULT ($size)"
    else
        error "Base image build succeeded but result not found at: $BASE_IMAGE_RESULT"
    fi
}

create_vm_disk() {
    log "=== Creating VM Disk ==="

    local vm_hostname="${VM_TYPE}-${VM_NAME}"
    local target_image="/var/lib/libvirt/images/$vm_hostname.qcow2"

    # Remove existing VM if it exists
    if sudo virsh --connect qemu:///system list --all | grep -q "\\b$vm_hostname\\b"; then
        log "Removing existing VM: $vm_hostname"
        sudo virsh --connect qemu:///system destroy "$vm_hostname" 2>/dev/null || true
        sudo virsh --connect qemu:///system undefine "$vm_hostname" --nvram 2>/dev/null || true
    fi

    # Remove existing disk
    if [[ -f "$target_image" ]]; then
        log "Removing existing disk: $target_image"
        sudo rm -f "$target_image"
    fi

    sudo mkdir -p /var/lib/libvirt/images

    log "Copying and resizing base image..."
    sudo cp "$BASE_IMAGE_RESULT" "$target_image"
    sudo qemu-img resize "$target_image" "$VM_DISK_SIZE"

    # Set hostname in the image before first boot
    log "Setting hostname to: $vm_hostname"
    if command -v virt-customize >/dev/null 2>&1; then
        sudo virt-customize -a "$target_image" --hostname "$vm_hostname"
    else
        log "WARNING: virt-customize not found, hostname may need manual configuration"
        log "Install with: nix-shell -p libguestfs"
    fi

    # Set permissions
    if id "libvirt-qemu" >/dev/null 2>&1; then
        sudo chown libvirt-qemu:kvm "$target_image"
    else
        sudo chmod 644 "$target_image"
    fi

    log "VM disk ready: $(sudo qemu-img info "$target_image" | grep 'virtual size')"
}

deploy_vm() {
    log "=== Deploying VM ==="

    local vm_hostname="${VM_TYPE}-${VM_NAME}"
    local target_image="/var/lib/libvirt/images/$vm_hostname.qcow2"

    # Check bridge
    if ! sudo virsh net-list --all | grep -q "\\b$VM_BRIDGE\\b" && ! ip link show "$VM_BRIDGE" >/dev/null 2>&1; then
        log "Warning: Bridge $VM_BRIDGE not found, using default network"
        VM_BRIDGE="default"
    fi

    log "VM Configuration:"
    log "  Hostname: $vm_hostname"
    log "  Type: $VM_TYPE"
    log "  Resources: ${VM_VCPUS}/${HOST_CORES} cores, ${VM_MEMORY}MB/${HOST_RAM_MB}MB RAM"
    log "  Storage: $VM_DISK_SIZE disk"
    log "  Network: $VM_BRIDGE bridge"
    log "  Graphics: SPICE optimized"

    # Deploy VM (hostname already set in image via virt-customize)
    sudo virt-install \
        --connect qemu:///system \
        --name="$vm_hostname" \
        --memory="$VM_MEMORY" \
        --vcpus="$VM_VCPUS" \
        --cpu host-passthrough \
        --disk "$target_image,device=disk,bus=virtio,cache=writeback" \
        --os-variant=nixos-unstable \
        --boot=hd \
        --graphics spice,listen=127.0.0.1 \
        --video qxl,vram=65536 \
        --channel spicevmc,target_type=virtio,name=com.redhat.spice.0 \
        --network bridge="$VM_BRIDGE",model=virtio \
        --memballoon virtio \
        --rng /dev/urandom \
        --features kvm_hidden=on \
        --clock offset=utc,rtc_tickpolicy=catchup \
        --noautoconsole \
        --import

    success "VM deployed successfully!"
}

show_info() {
    local vm_hostname="${VM_TYPE}-${VM_NAME}"

    cat << EOF

=== VM Ready! ===

VM Details:
  Hostname: $vm_hostname
  Type: $VM_TYPE
  Resources: ${VM_VCPUS}/${HOST_CORES} cores, ${VM_MEMORY}MB/${HOST_RAM_MB}MB RAM
  Allocation: $((VM_VCPUS * 100 / HOST_CORES))% CPU, $((VM_MEMORY * 100 / HOST_RAM_MB))% RAM

First Boot Process:
  1. VM boots with base image (i3, fish, core tools)
  2. Shaping service detects hostname "$vm_hostname"
  3. Extracts type "$VM_TYPE" from hostname
  4. Clones Hydrix repo to /etc/nixos/hydrix
  5. Runs: nixos-rebuild switch --flake .#vm-$VM_TYPE
  6. System rebuilds with full $VM_TYPE profile
  7. Ready to use with all $VM_TYPE-specific packages

Connection:
  virt-manager → $vm_hostname
  virt-viewer qemu:///system $vm_hostname

Credentials:
  Username: traum
  Password: (set in users.nix)

Management:
  Start:   sudo virsh start $vm_hostname
  Stop:    sudo virsh shutdown $vm_hostname
  Console: sudo virsh console $vm_hostname
  Delete:  sudo virsh undefine $vm_hostname --nvram

EOF
}

main() {
    parse_args "$@"

    log "=== Hydrix VM Deployment System ==="
    log "Deploying: ${VM_TYPE}-${VM_NAME}"

    check_dependencies
    get_resource_allocation "$VM_TYPE"
    check_base_image
    create_vm_disk
    deploy_vm
    show_info

    success "Deployment complete!"
}

main "$@"
