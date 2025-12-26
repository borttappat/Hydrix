#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Base image paths (set based on VM type)
BASE_IMAGE_RESULT=""
BASE_IMAGE_FLAKE=""

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
VM_BRIDGE=""  # Will be auto-detected based on mode
VM_MODE="auto"  # auto, standard, or lockdown
FORCE_REBUILD=false

# Bridge mappings (unified naming - same bridges used in all modes)
# Standard mode: 192.168.x.x subnets
# Lockdown mode: 10.100.x.x subnets with VPN policy routing
# Note: Isolated bridges cannot talk to each other directly
#       br-shared allows crosstalk between VMs
declare -A VM_BRIDGES=(
    ["pentest"]="br-pentest"
    ["office"]="br-office"
    ["comms"]="br-office"      # comms uses office network
    ["browsing"]="br-browse"
    ["dev"]="br-dev"
    ["shared"]="br-shared"     # shared bridge for VM crosstalk
)

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }

detect_mode() {
    # Detect if we're in lockdown mode by checking host IP on br-mgmt
    # Lockdown: 10.100.0.x, Standard: 192.168.100.x
    if ip addr show br-mgmt 2>/dev/null | grep -q "10.100.0"; then
        echo "lockdown"
    elif ip addr show br-mgmt 2>/dev/null | grep -q "192.168.100"; then
        echo "standard"
    elif ip link show br-mgmt &>/dev/null; then
        # Bridge exists but no IP yet - check for any passthrough mode
        echo "standard"
    else
        echo "base"
    fi
}

get_bridge_for_type() {
    local type=$1
    # Unified bridge naming - same in all modes
    echo "${VM_BRIDGES[$type]:-br-dev}"
}

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
  --bridge BRIDGE      Network bridge (overrides auto-detection)
  --mode MODE          Network mode: auto, standard, lockdown (default: auto)
  -h, --help           Show this help

VM Types and Resource Allocation:
  pentest    - Pentesting tools (75% CPU/RAM) - Red theme
  comms      - Communication apps (25% CPU/RAM) - Blue theme
  browsing   - Web browsing/media (50% CPU/RAM) - Green theme
  dev        - Development tools (75% CPU/RAM) - Purple theme

Network Modes:
  auto       - Auto-detect based on host IP on br-mgmt
  standard   - 192.168.x.x networks (simple NAT)
  lockdown   - 10.100.x.x networks (VPN policy routing)

Bridge Mapping (same bridges in all modes):
  pentest  → br-pentest (192.168.101.x / 10.100.1.x) - ISOLATED
  comms    → br-office  (192.168.102.x / 10.100.2.x) - ISOLATED
  browsing → br-browse  (192.168.103.x / 10.100.3.x) - ISOLATED
  dev      → br-dev     (192.168.104.x / 10.100.4.x) - ISOLATED
  shared   → br-shared  (192.168.105.x / 10.100.5.x) - CROSSTALK ALLOWED

Isolation:
  VMs on isolated bridges (pentest, office, browse, dev) cannot
  communicate directly with VMs on other isolated bridges.
  Use --bridge br-shared to add a VM that needs to talk to other VMs.

In lockdown mode, pentest/comms/browsing are VPN-routed by the router VM.

Host System:
  CPU Cores: $HOST_CORES
  RAM: ${HOST_RAM_MB}MB (~$((HOST_RAM_MB / 1024))GB)

Examples:
  # Deploy pentest VM (auto-detects mode, uses isolated br-pentest)
  $0 --type pentest --name google

  # Deploy for lockdown mode explicitly
  $0 --type pentest --name google --mode lockdown

  # Deploy a dev VM on the shared bridge (allows crosstalk with other VMs)
  $0 --type dev --name shared-rust --bridge br-shared

  # Deploy with custom bridge
  $0 --type dev --name rust --bridge br-dev

Workflow:
  1. Check if base image exists (builds if missing)
  2. Auto-detect network mode (standard vs lockdown)
  3. Calculate resources based on VM type
  4. Create VM with hostname "<type>-<name>"
  5. First boot: shaping service applies full profile

EOF
    exit 0
}

get_resource_allocation() {
    local type=$1
    local percent=0

    case "$type" in
        pentest)
            percent=75
            BASE_IMAGE_FLAKE="${type}-vm-full"
            BASE_IMAGE_RESULT="$PROJECT_DIR/${type}-vm-image/nixos.qcow2"
            log "Pentest VM - Full image, high performance (75%)"
            ;;
        dev)
            percent=75
            BASE_IMAGE_FLAKE="${type}-vm-full"
            BASE_IMAGE_RESULT="$PROJECT_DIR/${type}-vm-image/nixos.qcow2"
            log "Dev VM - Full image, high performance (75%)"
            ;;
        browsing)
            percent=50
            BASE_IMAGE_FLAKE="${type}-vm-full"
            BASE_IMAGE_RESULT="$PROJECT_DIR/${type}-vm-image/nixos.qcow2"
            log "Browsing VM - Full image (50%)"
            ;;
        comms)
            percent=25
            BASE_IMAGE_FLAKE="${type}-vm-full"
            BASE_IMAGE_RESULT="$PROJECT_DIR/${type}-vm-image/nixos.qcow2"
            log "Comms VM - Full image, light allocation (25%)"
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
            --mode)
                [[ -z "${2:-}" ]] && error "--mode requires a value"
                VM_MODE="$2"
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
    log "=== Building $VM_TYPE Base Image ==="
    log "This may take 10-15 minutes on first build..."

    cd "$PROJECT_DIR"

    # Build with output link based on type
    # Creates symlink: pentest-vm-image/ -> /nix/store/...-nixos.qcow2/
    if ! nix build ".#$BASE_IMAGE_FLAKE" --out-link "${VM_TYPE}-vm-image" --print-build-logs; then
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

    # Hostname is baked into the base image (e.g., "pentest-vm")
    # The base image already has the correct hostname set at build time
    log "Base image hostname: ${VM_TYPE}-vm (baked in at build time)"

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
  Mode: $VM_MODE
  Bridge: $VM_BRIDGE
  Resources: ${VM_VCPUS}/${HOST_CORES} cores, ${VM_MEMORY}MB/${HOST_RAM_MB}MB RAM
  Allocation: $((VM_VCPUS * 100 / HOST_CORES))% CPU, $((VM_MEMORY * 100 / HOST_RAM_MB))% RAM

First Boot Process:
  1. VM boots with base image (hostname: ${VM_TYPE}-vm)
  2. Hydrix repo is copied to /home/traum/Hydrix
  3. Hardware configuration is auto-generated
  4. Shaping service detects hostname "${VM_TYPE}-vm"
  5. Extracts type "$VM_TYPE" from hostname
  6. Runs: nixbuild-vm (rebuilds with flake .#vm-$VM_TYPE)
  7. System rebuilds with full $VM_TYPE profile
  8. Ready to use with all $VM_TYPE-specific packages and configs

EOF

    # Show isolation status
    if [[ "$VM_BRIDGE" == "br-shared" ]]; then
        echo "Network Isolation: DISABLED (br-shared allows crosstalk with all VMs)"
    else
        echo "Network Isolation: ENABLED (cannot reach VMs on other isolated bridges)"
        echo "  To allow crosstalk: redeploy with --bridge br-shared"
    fi
    echo ""

    if [[ "$VM_MODE" == "lockdown" ]]; then
        cat << EOF
Lockdown Mode Network:
  Bridge: $VM_BRIDGE
  Network: $(case $VM_BRIDGE in
    br-pentest) echo "10.100.1.x - Routed through assigned VPN (isolated)" ;;
    br-office)  echo "10.100.2.x - Routed through corporate VPN (isolated)" ;;
    br-browse)  echo "10.100.3.x - Routed through privacy VPN (isolated)" ;;
    br-dev)     echo "10.100.4.x - Direct or configurable routing (isolated)" ;;
    br-shared)  echo "10.100.5.x - Direct routing, crosstalk allowed" ;;
    *)          echo "Custom bridge" ;;
  esac)
  Router: SSH to traum@10.100.0.253 for VPN management

VPN Commands (on router):
  vpn-status                    # Check routing status
  vpn-assign $VM_TYPE <vpn>     # Route this network through VPN

EOF
    fi

    cat << EOF
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

    # Auto-detect mode if not specified
    if [[ "$VM_MODE" == "auto" ]]; then
        VM_MODE=$(detect_mode)
        if [[ "$VM_MODE" == "base" ]]; then
            error "Not in a passthrough mode. Please switch to router/maximalism/lockdown first:
  sudo nixos-rebuild switch --specialisation maximalism"
        fi
        log "Auto-detected network mode: $VM_MODE"
    fi

    # Set bridge if not explicitly specified (unified naming)
    if [[ -z "$VM_BRIDGE" ]]; then
        VM_BRIDGE=$(get_bridge_for_type "$VM_TYPE")
        log "Using bridge for $VM_TYPE: $VM_BRIDGE"
    fi

    # Verify bridge exists
    if ! ip link show "$VM_BRIDGE" &>/dev/null; then
        error "Bridge $VM_BRIDGE does not exist. Are you in a passthrough mode?
  sudo nixos-rebuild switch --specialisation maximalism"
    fi

    get_resource_allocation "$VM_TYPE"
    check_base_image
    create_vm_disk
    deploy_vm
    show_info

    success "Deployment complete!"
}

main "$@"
