#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly LOCAL_DIR="$PROJECT_DIR/local"
readonly VMS_DIR="$LOCAL_DIR/vms"

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
SHARED_STORE=true  # Enable virtiofs shared /nix/store by default

# User configuration (new parameters for baked + orphaned model)
VM_USER=""         # Username inside VM (default: current user)
VM_PASSWORD=""     # Will be prompted if not provided
VM_HOSTNAME=""     # VM's internal hostname (default: <type>-<name>)

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
Builds VM images with baked-in configuration (orphaned model)

Required Arguments:
  --type TYPE           VM type: pentest, comms, browsing, dev
  --name NAME           VM instance name (e.g., google, signal, leisure, rust)

User Configuration:
  --user USERNAME      Username inside VM (default: current user)
  --hostname HOSTNAME  VM's internal hostname (default: <type>-<name>)
  --password PASSWORD  User password (will prompt if not provided)

Optional Arguments:
  --force-rebuild       Rebuild base image even if it exists
  --disk SIZE          Disk size (default: 100G)
  --bridge BRIDGE      Network bridge (overrides auto-detection)
  --mode MODE          Network mode: auto, standard, lockdown (default: auto)
  --no-shared-store    Disable virtiofs shared /nix/store (enabled by default)
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
  # Deploy pentest VM with default settings
  $0 --type pentest --name google

  # Deploy with custom username and password
  $0 --type pentest --name htb --user alice

  # Deploy for lockdown mode explicitly
  $0 --type pentest --name google --mode lockdown

  # Deploy a dev VM on the shared bridge (allows crosstalk with other VMs)
  $0 --type dev --name shared-rust --bridge br-shared

  # Deploy with custom hostname (different from display name)
  $0 --type pentest --name client-engagement --hostname target-audit

Workflow (Baked + Orphaned Model):
  1. Prompt for password (if not provided)
  2. Generate secrets file (local/vms/<hostname>.nix)
  3. Generate instance config (local/vm-instance.nix)
  4. Build VM image with baked-in configuration
  5. Deploy VM to libvirt
  6. Clean up instance config (secrets are preserved)

  The VM is self-contained after deployment:
  - Config baked into /home/<user>/Hydrix
  - No need to pull from git
  - Rebuilds use local baked config
  - virtiofs provides fast package access

EOF
    exit 0
}

get_resource_allocation() {
    local type=$1
    local percent=0

    case "$type" in
        pentest)
            percent=75
            BASE_IMAGE_FLAKE="${type}"
            BASE_IMAGE_RESULT="$PROJECT_DIR/${type}-vm-image/nixos.qcow2"
            log "Pentest VM - Full image, high performance (75%)"
            ;;
        dev)
            percent=75
            BASE_IMAGE_FLAKE="${type}"
            BASE_IMAGE_RESULT="$PROJECT_DIR/${type}-vm-image/nixos.qcow2"
            log "Dev VM - Full image, high performance (75%)"
            ;;
        browsing)
            percent=50
            BASE_IMAGE_FLAKE="${type}"
            BASE_IMAGE_RESULT="$PROJECT_DIR/${type}-vm-image/nixos.qcow2"
            log "Browsing VM - Full image (50%)"
            ;;
        comms)
            percent=25
            BASE_IMAGE_FLAKE="${type}"
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
            --user)
                [[ -z "${2:-}" ]] && error "--user requires a value"
                VM_USER="$2"
                shift 2
                ;;
            --hostname)
                [[ -z "${2:-}" ]] && error "--hostname requires a value"
                VM_HOSTNAME="$2"
                shift 2
                ;;
            --password)
                [[ -z "${2:-}" ]] && error "--password requires a value"
                VM_PASSWORD="$2"
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
            --no-shared-store)
                SHARED_STORE=false
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

    # Set defaults for user configuration
    # Detect current user (prefer SUDO_USER if running with sudo, else USER)
    # Use ${VAR:-} syntax to handle unset variables with set -u
    if [[ -z "$VM_USER" ]]; then
        if [[ -n "${SUDO_USER:-}" ]]; then
            VM_USER="$SUDO_USER"
        elif [[ -n "${USER:-}" && "${USER:-}" != "root" ]]; then
            VM_USER="$USER"
        else
            VM_USER="user"
        fi
    fi
    [[ -z "$VM_HOSTNAME" ]] && VM_HOSTNAME="${VM_TYPE}-${VM_NAME}"
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

# ===== Credential and Config Generation Functions =====

prompt_password() {
    log "=== User Configuration ==="
    log "Username: $VM_USER"
    log "Hostname: $VM_HOSTNAME"

    if [[ -z "$VM_PASSWORD" ]]; then
        echo ""
        echo "Enter password for VM user '$VM_USER':"
        read -s -p "Password: " VM_PASSWORD
        echo ""
        read -s -p "Confirm password: " password_confirm
        echo ""

        if [[ "$VM_PASSWORD" != "$password_confirm" ]]; then
            error "Passwords do not match"
        fi

        if [[ -z "$VM_PASSWORD" ]]; then
            log "No password entered, using default password 'user'"
            VM_PASSWORD="user"
        fi
    fi
}

generate_password_hash() {
    log "Generating password hash..."
    # Use mkpasswd to generate SHA-512 hash
    if command -v mkpasswd &>/dev/null; then
        VM_PASSWORD_HASH=$(echo "$VM_PASSWORD" | mkpasswd -m sha-512 -s)
    else
        # Fallback using openssl
        local salt=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
        VM_PASSWORD_HASH=$(openssl passwd -6 -salt "$salt" "$VM_PASSWORD")
    fi

    if [[ -z "$VM_PASSWORD_HASH" ]]; then
        error "Failed to generate password hash"
    fi
}

generate_secrets_file() {
    log "=== Generating Secrets File ==="

    # Ensure directories exist
    mkdir -p "$VMS_DIR"

    local secrets_file="$VMS_DIR/${VM_HOSTNAME}.nix"

    cat > "$secrets_file" << EOF
# VM Secrets - Generated by build-vm.sh
# VM: ${VM_HOSTNAME}
# Type: ${VM_TYPE}
# Display Name: ${VM_NAME}
# Generated: $(date -Iseconds)
#
# This file is LOCAL ONLY - not committed to git
# Used at build time and for VM rebuilds

{
  # VM user account
  username = "${VM_USER}";

  # Password hash (SHA-512)
  hashedPassword = "${VM_PASSWORD_HASH}";

  # VM hostname (set in the VM's /etc/hostname)
  hostname = "${VM_HOSTNAME}";

  # VM type (pentest, browsing, comms, dev)
  vmType = "${VM_TYPE}";

  # Network bridge
  bridge = "${VM_BRIDGE}";
}
EOF

    log "Secrets file created: $secrets_file"
}

generate_instance_config() {
    log "=== Generating Instance Config ==="

    # Create the instance config that profiles import
    local instance_file="$LOCAL_DIR/vm-instance.nix"

    cat > "$instance_file" << EOF
# VM Instance Configuration - Generated by build-vm.sh
# This file is temporary and used during image build
# Generated: $(date -Iseconds)
#
# After build, this file is baked into the VM image
# and can be removed from the host

{
  # VM hostname (sets networking.hostName)
  hostname = "${VM_HOSTNAME}";

  # VM username (used by users-vm.nix)
  username = "${VM_USER}";
}
EOF

    log "Instance config created: $instance_file"
}

stage_local_files() {
    log "=== Staging Local Files for Nix ==="

    # Since local/ is gitignored, we need to stage files with -f for nix to see them
    # This doesn't commit them, just makes them visible to nix flakes
    cd "$PROJECT_DIR"

    local files_to_stage=(
        "local/vm-instance.nix"
        "local/shared.nix"
        "local/host.nix"
        "local/vms/${VM_HOSTNAME}.nix"
    )

    for file in "${files_to_stage[@]}"; do
        if [[ -f "$file" ]]; then
            git add -f "$file" 2>/dev/null || true
            log "Staged: $file"
        fi
    done

    log "Local files staged for nix visibility"
}

unstage_local_files() {
    log "=== Unstaging Local Files ==="

    cd "$PROJECT_DIR"

    # Unstage the temporary files (but keep secrets staged for potential rebuilds)
    git reset HEAD local/vm-instance.nix 2>/dev/null || true

    log "Temporary files unstaged"
}

cleanup_instance_config() {
    local instance_file="$LOCAL_DIR/vm-instance.nix"

    if [[ -f "$instance_file" ]]; then
        log "Cleaning up instance config..."
        rm -f "$instance_file"
    fi
}

save_credentials_reference() {
    log "=== Saving Credentials Reference ==="

    # Create credentials directory
    local creds_dir="$LOCAL_DIR/credentials"
    mkdir -p "$creds_dir"

    local creds_file="$creds_dir/${VM_HOSTNAME}.json"

    cat > "$creds_file" << EOF
{
  "hostname": "${VM_HOSTNAME}",
  "displayName": "${VM_NAME}",
  "vmType": "${VM_TYPE}",
  "username": "${VM_USER}",
  "bridge": "${VM_BRIDGE}",
  "created": "$(date -Iseconds)",
  "secretsFile": "${VMS_DIR}/${VM_HOSTNAME}.nix",
  "note": "Password is stored as hash in secrets file. Original password not saved."
}
EOF

    log "Credentials reference saved: $creds_file"
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

    # Use VM_HOSTNAME for the libvirt domain name (what the host sees)
    local target_image="/var/lib/libvirt/images/${VM_HOSTNAME}.qcow2"

    # Remove existing VM if it exists
    if sudo virsh --connect qemu:///system list --all | grep -q "\\b${VM_HOSTNAME}\\b"; then
        log "Removing existing VM: ${VM_HOSTNAME}"
        sudo virsh --connect qemu:///system destroy "${VM_HOSTNAME}" 2>/dev/null || true
        sudo virsh --connect qemu:///system undefine "${VM_HOSTNAME}" --nvram 2>/dev/null || true
    fi

    # Remove existing disk
    if [[ -f "$target_image" ]]; then
        log "Removing existing disk: $target_image"
        sudo rm -f "$target_image"
    fi

    sudo mkdir -p /var/lib/libvirt/images

    log "Creating VM disk with backing file (instant, saves space)..."
    # Use qcow2 backing file - creates thin overlay instead of full copy
    # The base image stays read-only in nix store, VM writes go to overlay
    sudo qemu-img create -f qcow2 -b "$BASE_IMAGE_RESULT" -F qcow2 "$target_image" "$VM_DISK_SIZE"

    # Hostname is baked into the image via vm-instance.nix
    log "VM hostname (baked in): ${VM_HOSTNAME}"
    log "VM username (baked in): ${VM_USER}"

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

    local target_image="/var/lib/libvirt/images/${VM_HOSTNAME}.qcow2"

    # Check bridge
    if ! sudo virsh net-list --all | grep -q "\\b$VM_BRIDGE\\b" && ! ip link show "$VM_BRIDGE" >/dev/null 2>&1; then
        log "Warning: Bridge $VM_BRIDGE not found, using default network"
        VM_BRIDGE="default"
    fi

    log "VM Configuration:"
    log "  Hostname: $VM_HOSTNAME"
    log "  Username: $VM_USER"
    log "  Type: $VM_TYPE"
    log "  Resources: ${VM_VCPUS}/${HOST_CORES} cores, ${VM_MEMORY}MB/${HOST_RAM_MB}MB RAM"
    log "  Storage: $VM_DISK_SIZE disk"
    log "  Network: $VM_BRIDGE bridge"
    log "  Graphics: SPICE optimized"
    log "  Shared Store: $SHARED_STORE"

    # Build virt-install arguments
    local virt_args=(
        --connect qemu:///system
        --name="$VM_HOSTNAME"
        --memory="$VM_MEMORY"
        --vcpus="$VM_VCPUS"
        --cpu host-passthrough
        --disk "$target_image,device=disk,bus=virtio,cache=writeback"
        --os-variant=nixos-unstable
        --boot=hd
        --graphics spice,listen=127.0.0.1
        --video qxl,ram=65536,vram=65536,vgamem=65536
        --channel spicevmc,target_type=virtio,name=com.redhat.spice.0
        --network bridge="$VM_BRIDGE",model=virtio
        --memballoon virtio
        --rng /dev/urandom
        --features kvm_hidden=on
        --clock offset=utc,rtc_tickpolicy=catchup
        --noautoconsole
        --import
    )

    # Add virtiofs shared /nix/store if enabled
    if [[ "$SHARED_STORE" == true ]]; then
        log "Adding virtiofs shared /nix/store..."
        virt_args+=(
            --memorybacking source.type=memfd,access.mode=shared
            --filesystem source=/nix/store,target=nix-store,driver.type=virtiofs,binary.path=/run/current-system/sw/bin/virtiofsd
        )
    fi

    # Deploy VM
    sudo virt-install "${virt_args[@]}"

    success "VM deployed successfully!"
}

show_info() {
    cat << EOF

=== VM Ready! ===

VM Details:
  Hostname: $VM_HOSTNAME
  Username: $VM_USER
  Type: $VM_TYPE
  Mode: $VM_MODE
  Bridge: $VM_BRIDGE
  Resources: ${VM_VCPUS}/${HOST_CORES} cores, ${VM_MEMORY}MB/${HOST_RAM_MB}MB RAM
  Allocation: $((VM_VCPUS * 100 / HOST_CORES))% CPU, $((VM_MEMORY * 100 / HOST_RAM_MB))% RAM

Baked Configuration:
  - Config location in VM: /home/${VM_USER}/Hydrix
  - Secrets file on host: ${VMS_DIR}/${VM_HOSTNAME}.nix
  - Credentials ref: ${LOCAL_DIR}/credentials/${VM_HOSTNAME}.json

First Boot:
  1. VM boots with all configuration baked in
  2. User '$VM_USER' can login with the password you set
  3. Run 'rebuild' to apply any local config changes

EOF

    # Show shared store status
    if [[ "$SHARED_STORE" == true ]]; then
        echo "Shared /nix/store: ENABLED (virtiofs mount from host)"
        echo "  Updates will use host's cached packages - near-instant rebuilds!"
        echo "  To disable: redeploy with --no-shared-store"
    else
        echo "Shared /nix/store: DISABLED"
        echo "  Updates will download packages from internet"
        echo "  To enable: redeploy without --no-shared-store"
    fi
    echo ""

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
  virt-manager → $VM_HOSTNAME
  virt-viewer qemu:///system $VM_HOSTNAME

Credentials:
  Username: $VM_USER
  Password: (what you entered during setup)

Management:
  Start:   sudo virsh start $VM_HOSTNAME
  Stop:    sudo virsh shutdown $VM_HOSTNAME
  Console: sudo virsh console $VM_HOSTNAME
  Delete:  sudo virsh undefine $VM_HOSTNAME --nvram

EOF
}

main() {
    parse_args "$@"

    log "=== Hydrix VM Deployment System ==="
    log "Deploying: ${VM_TYPE}-${VM_NAME} (hostname: ${VM_HOSTNAME})"

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

    # === Credential and Config Generation (BEFORE build) ===
    # These must be generated before building so they're baked into the image
    prompt_password
    generate_password_hash
    generate_secrets_file
    generate_instance_config

    # Stage local files so nix can see them (they're gitignored)
    stage_local_files

    # === Build Image ===
    # The image will now include the generated secrets and instance config
    get_resource_allocation "$VM_TYPE"

    # Force rebuild since we have new secrets/config
    # TODO: Could be smarter about detecting if secrets changed
    FORCE_REBUILD=true
    check_base_image

    # === Deploy ===
    create_vm_disk
    deploy_vm

    # === Cleanup and Save ===
    # Remove temporary instance config (secrets file is kept)
    cleanup_instance_config
    unstage_local_files
    save_credentials_reference

    show_info

    success "Deployment complete!"
}

main "$@"
