#!/usr/bin/env bash
# Deploy VM from pre-built base image
#
# Instant deployment (~5 seconds) from base images.
# First-boot only configures hostname, user, and password.
#
# Usage:
#   ./scripts/deploy-vm.sh --type browsing --name myvm --user traum
#   ./scripts/deploy-vm.sh --type pentest --name target1 --user hacker --pass secret --bridge br-pentest
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common library for validation functions
if [[ -f "$SCRIPT_DIR/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "$SCRIPT_DIR/lib/common.sh"
fi
readonly BASE_IMAGE_DIR="/var/lib/libvirt/base-images"
readonly VM_IMAGE_DIR="/var/lib/libvirt/images"
readonly VM_CONFIG_DIR="/var/lib/libvirt/vm-configs"
readonly VM_KEYS_DIR="/var/lib/libvirt/keys"
readonly VM_STAGING_DIR="/var/lib/libvirt/vm-staging"
readonly VM_CHANGES_DIR="/var/lib/libvirt/vm-changes"

# Logging (all to stderr to avoid capture in command substitution)
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*" >&2; }

# Secure cleanup on exit
secure_cleanup() {
    # Clear sensitive variables from memory
    unset pass1 pass2 luks_password password
}
trap secure_cleanup EXIT

# Defaults (auto = calculate based on type and host resources)
VM_TYPE=""
VM_NAME=""
VM_USER="${SUDO_USER:-${USER:-user}}"
VM_PASS=""
VM_BRIDGE=""
VM_VCPUS="auto"
VM_MEMORY="auto"
NO_CONNECT=false
FORCE=false
SHARE_STORE=true
ENCRYPT=false
ENCRYPT_SECRET_UUID=""

# Host directories (for profile writeback)
HOST_USER="${SUDO_USER:-${USER}}"
HOST_HOME=$(eval echo "~$HOST_USER")

# Detect config directory: hydrix-config (user mode) or Hydrix (developer mode)
if [[ -d "$HOST_HOME/hydrix-config/profiles" ]]; then
    HYDRIX_DIR="$HOST_HOME/hydrix-config"
elif [[ -d "$HOST_HOME/Hydrix/profiles" ]]; then
    HYDRIX_DIR="$HOST_HOME/Hydrix"
else
    HYDRIX_DIR="$HOST_HOME/hydrix-config"  # Default for new setups
fi

# Valid types and their default bridges
declare -A TYPE_BRIDGES=(
    ["pentest"]="br-pentest"
    ["browsing"]="br-browse"
    ["comms"]="br-comms"
    ["dev"]="br-dev"
    ["lurking"]="br-lurking"
    ["transfer"]="br-shared"
)

# Resource allocation percentages by VM type
# High performance: pentest, dev (75%)
# Moderate: browsing (50%)
# Light: comms, lurking, transfer (25%)
declare -A TYPE_RESOURCES=(
    ["pentest"]="75"
    ["dev"]="75"
    ["browsing"]="50"
    ["comms"]="25"
    ["lurking"]="25"
    ["transfer"]="25"
)

# Host resources (populated by detect_host_resources)
HOST_CORES=""
HOST_RAM_MB=""

# Detect host resources for dynamic allocation
detect_host_resources() {
    HOST_CORES=$(nproc)
    HOST_RAM_MB=$(free -m | grep '^Mem:' | awk '{print $2}')
}

# Calculate VM resources based on type and host capacity
calculate_resources() {
    local percent=${TYPE_RESOURCES[$VM_TYPE]:-50}

    # Only calculate if not overridden by user
    if [[ "$VM_VCPUS" == "auto" ]]; then
        VM_VCPUS=$((HOST_CORES * percent / 100))
        [[ $VM_VCPUS -lt 2 ]] && VM_VCPUS=2
        # Cap at host cores - 1 to leave headroom
        [[ $VM_VCPUS -ge $HOST_CORES ]] && VM_VCPUS=$((HOST_CORES - 1))
        [[ $VM_VCPUS -lt 2 ]] && VM_VCPUS=2
    fi

    if [[ "$VM_MEMORY" == "auto" ]]; then
        VM_MEMORY=$((HOST_RAM_MB * percent / 100))
        [[ $VM_MEMORY -lt 2048 ]] && VM_MEMORY=2048
        # Cap at host RAM - 4GB to leave headroom
        local max_mem=$((HOST_RAM_MB - 4096))
        [[ $VM_MEMORY -gt $max_mem ]] && VM_MEMORY=$max_mem
        [[ $VM_MEMORY -lt 2048 ]] && VM_MEMORY=2048
    fi
    return 0
}

print_usage() {
    cat <<EOF
Usage: $(basename "$0") --type <type> --name <name> [options]

Deploy a VM from a pre-built base image.

Required:
  --type <type>     VM type: pentest, browsing, comms, dev, lurking, transfer
  --name <name>     Instance name (e.g., target1, personal)

Options:
  --user <user>     Username in VM (default: current user)
  --pass <pass>     Password for user (default: prompted or empty)
  --bridge <br>     Network bridge (default: based on type)
  --vcpus <n>       Number of vCPUs (default: auto, based on type)
  --memory <mb>     Memory in MB (default: auto, based on type)
  --no-connect      Don't auto-connect to console after launch
  --force           Overwrite existing VM without prompting
  --no-share-store  Disable host /nix/store sharing (enabled by default)
  --encrypt         Create LUKS-encrypted disk (prompts for password)
  -h, --help        Show this help

Resource allocation by type:
  pentest, dev:     75% of host resources (high performance)
  browsing:         50% of host resources (moderate)
  comms, lurking:   25% of host resources (light)
  transfer:         25% of host resources (light)

Examples:
  $(basename "$0") --type browsing --name personal --user traum
  $(basename "$0") --type pentest --name htb --user hacker
  $(basename "$0") --type dev --name work --vcpus 8 --memory 16384

Build base images first:
  ./scripts/build-base.sh --type browsing
  ./scripts/build-base.sh --all           # Build all in parallel
EOF
    exit 0
}

parse_args() {
    [[ $# -eq 0 ]] && print_usage

    while [[ $# -gt 0 ]]; do
        case $1 in
            --type)
                VM_TYPE="$2"
                shift 2
                ;;
            --name)
                VM_NAME="$2"
                shift 2
                ;;
            --user)
                VM_USER="$2"
                shift 2
                ;;
            --pass)
                VM_PASS="$2"
                shift 2
                ;;
            --bridge)
                VM_BRIDGE="$2"
                shift 2
                ;;
            --vcpus)
                VM_VCPUS="$2"
                shift 2
                ;;
            --memory)
                VM_MEMORY="$2"
                shift 2
                ;;
            --no-connect)
                NO_CONNECT=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --no-share-store)
                SHARE_STORE=false
                shift
                ;;
            --encrypt)
                ENCRYPT=true
                shift
                ;;
            -h|--help)
                print_usage
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done

    # Validate required args
    [[ -z "$VM_TYPE" ]] && error "Missing --type"
    [[ -z "$VM_NAME" ]] && error "Missing --name"

    # Validate VM name format (if validation functions available)
    if type validate_vm_name &>/dev/null; then
        validate_vm_name "$VM_NAME"
    fi

    # Validate username format (if validation functions available)
    if type validate_username &>/dev/null; then
        validate_username "$VM_USER"
    fi

    # Validate type
    [[ -z "${TYPE_BRIDGES[$VM_TYPE]:-}" ]] && error "Invalid type: $VM_TYPE (valid: ${!TYPE_BRIDGES[*]})"

    # Set default bridge if not specified
    [[ -z "$VM_BRIDGE" ]] && VM_BRIDGE="${TYPE_BRIDGES[$VM_TYPE]}"
}

check_base_image() {
    local base_image="$BASE_IMAGE_DIR/base-${VM_TYPE}.qcow2"

    if [[ ! -f "$base_image" ]]; then
        error "Base image not found: $base_image

Build it first with:
  ./scripts/build-base.sh --type $VM_TYPE

Or build all base images:
  ./scripts/build-base.sh --all"
    fi

    echo "$base_image"
}

create_vm_config() {
    local config_dir="$VM_CONFIG_DIR/${VM_TYPE}-${VM_NAME}"
    local staging_dir="$VM_STAGING_DIR/${VM_TYPE}-${VM_NAME}"
    local hostname="${VM_TYPE}-${VM_NAME}"

    log "Creating VM config: $config_dir"
    sudo mkdir -p "$config_dir"

    # Create staging directory for profile writeback
    log "Creating staging directory: $staging_dir/profiles"
    sudo mkdir -p "$staging_dir/profiles"

    # Create persist directory for vm-dev/vm-sync workflow
    local persist_dir="$HOME/persist/$VM_TYPE"
    log "Creating persist directory: $persist_dir"
    mkdir -p "$persist_dir/dev/packages"
    mkdir -p "$persist_dir/staging/packages"
    chmod -R 777 "$persist_dir"

    # Copy the profile to staging (VM edits this copy)
    local profile_src="$HYDRIX_DIR/profiles/${VM_TYPE}.nix"
    if [[ -f "$profile_src" ]]; then
        log "Copying profile to staging: ${VM_TYPE}.nix"
        sudo cp "$profile_src" "$staging_dir/profiles/"
        # Make writable by VM - 9p mapped mode needs world-writable for cross-uid access
        sudo chmod -R 777 "$staging_dir"
        sudo chmod 666 "$staging_dir/profiles/"*.nix 2>/dev/null || true
    else
        log "Warning: Profile not found: $profile_src"
    fi

    # Write hostname
    echo "$hostname" | sudo tee "$config_dir/hostname" > /dev/null

    # Write username
    echo "$VM_USER" | sudo tee "$config_dir/username" > /dev/null

    # Write password if provided
    if [[ -n "$VM_PASS" ]]; then
        echo "$VM_PASS" | sudo tee "$config_dir/password" > /dev/null
        sudo chmod 600 "$config_dir/password"
    fi

    success "Config created"
    log "  Hostname: $hostname"
    log "  Username: $VM_USER"
    [[ -n "$VM_PASS" ]] && log "  Password: (set)"

    echo "$config_dir"
}

create_vm_disk() {
    local base_image="$1"
    local vm_disk="$VM_IMAGE_DIR/${VM_TYPE}-${VM_NAME}.qcow2"

    if [[ -f "$vm_disk" ]]; then
        if $FORCE; then
            log "Removing existing disk (--force)"
            sudo rm -f "$vm_disk"
        else
            read -p "VM disk exists: $vm_disk. Overwrite? [y/N] " -n 1 -r
            echo >&2
            [[ ! $REPLY =~ ^[Yy]$ ]] && error "Aborted"
            sudo rm -f "$vm_disk"
        fi
    fi

    log "Creating VM disk with backing file..."
    sudo qemu-img create -f qcow2 \
        -b "$base_image" \
        -F qcow2 \
        "$vm_disk" 50G >&2

    success "VM disk created: $vm_disk"
    echo "$vm_disk"
}

check_bridge() {
    if ! ip link show "$VM_BRIDGE" &>/dev/null; then
        log "Warning: Bridge $VM_BRIDGE not found"

        # Try virbr0 as fallback
        if ip link show "virbr0" &>/dev/null; then
            log "  Falling back to virbr0"
            VM_BRIDGE="virbr0"
        else
            error "No valid bridge found. Create $VM_BRIDGE or start libvirtd default network."
        fi
    fi
}

create_luks_secret() {
    # Create a libvirt secret for the LUKS password
    # Returns the secret UUID
    local vm_name="$1"
    local password="$2"
    local secret_uuid

    # Generate a UUID for this secret
    secret_uuid=$(uuidgen)

    # Create secret XML
    local secret_xml=$(cat <<EOF
<secret ephemeral='no' private='yes'>
  <uuid>${secret_uuid}</uuid>
  <description>LUKS key for ${vm_name}</description>
  <usage type='volume'>
    <volume>/var/lib/libvirt/images/${vm_name}.qcow2</volume>
  </usage>
</secret>
EOF
)

    # Define the secret
    echo "$secret_xml" | sudo virsh --connect qemu:///system secret-define /dev/stdin >&2

    # Set the secret value (base64 encoded)
    local password_b64
    password_b64=$(echo -n "$password" | base64)
    sudo virsh --connect qemu:///system secret-set-value "$secret_uuid" "$password_b64" >&2

    echo "$secret_uuid"
}

create_encrypted_vm_xml() {
    # Create VM definition via XML for encrypted disks
    # virt-install doesn't support LUKS encryption directly
    local vm_name="$1"
    local vm_disk="$2"
    local config_dir="$3"
    local staging_dir="$VM_STAGING_DIR/$vm_name"

    # Generate VM XML with encryption support
    local vm_xml=$(cat <<EOF
<domain type='kvm'>
  <name>${vm_name}</name>
  <memory unit='MiB'>${VM_MEMORY}</memory>
  <vcpu>${VM_VCPUS}</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough'/>
  <devices>
    <emulator>/run/current-system/sw/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='${vm_disk}'>
        <encryption format='luks'>
          <secret type='passphrase' uuid='${ENCRYPT_SECRET_UUID}'/>
        </encryption>
      </source>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='bridge'>
      <source bridge='${VM_BRIDGE}'/>
      <model type='virtio'/>
    </interface>
    <graphics type='spice'>
      <listen type='none'/>
    </graphics>
    <video>
      <model type='qxl'/>
    </video>
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>
    <vsock>
      <cid auto='yes'/>
    </vsock>
    <filesystem type='mount' accessmode='squash'>
      <source dir='${config_dir}'/>
      <target dir='vm-config'/>
      <readonly/>
    </filesystem>
    <filesystem type='mount' accessmode='mapped'>
      <source dir='${staging_dir}/profiles'/>
      <target dir='hydrix-profiles'/>
    </filesystem>
EOF
)

    # Add virtiofs for shared store if enabled
    if [[ "$SHARE_STORE" == true ]]; then
        vm_xml+="
    <filesystem type='mount'>
      <driver type='virtiofs'/>
      <binary path='/run/current-system/sw/bin/virtiofsd'/>
      <source dir='/nix/store'/>
      <target dir='nix-store'/>
    </filesystem>
  </devices>
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>
</domain>"
    else
        vm_xml+="
  </devices>
</domain>"
    fi

    # Define and start the VM
    echo "$vm_xml" | sudo virsh --connect qemu:///system define /dev/stdin >&2
    sudo virsh --connect qemu:///system start "$vm_name" >&2

    success "Encrypted VM launched: $vm_name"
    log "  Secret UUID: $ENCRYPT_SECRET_UUID"
    log ""
    log "  NOTE: VM will prompt for LUKS password on each start."
    log "  The password is stored in libvirt secrets (RAM only while running)."
}

create_encrypted_disk() {
    local base_image="$1"
    local vm_disk="$VM_IMAGE_DIR/${VM_TYPE}-${VM_NAME}.qcow2"
    local password="$2"

    if [[ -f "$vm_disk" ]]; then
        if $FORCE; then
            log "Removing existing disk (--force)"
            sudo rm -f "$vm_disk"
        else
            read -p "VM disk exists: $vm_disk. Overwrite? [y/N] " -n 1 -r
            echo >&2
            [[ ! $REPLY =~ ^[Yy]$ ]] && error "Aborted"
            sudo rm -f "$vm_disk"
        fi
    fi

    log "Creating LUKS-encrypted standalone disk..."
    log "  (This copies the full base image, may take a moment)"

    # First, create an unencrypted copy of the base image
    local temp_disk="/tmp/${VM_TYPE}-${VM_NAME}-temp.qcow2"
    sudo qemu-img convert -f qcow2 -O qcow2 "$base_image" "$temp_disk" >&2

    # Now convert to LUKS-encrypted format
    # Use --object to provide password securely
    sudo qemu-img convert -f qcow2 -O qcow2 \
        --object "secret,id=sec0,data=$password" \
        -o encrypt.format=luks,encrypt.key-secret=sec0 \
        "$temp_disk" "$vm_disk" >&2

    # Clean up temp file
    sudo rm -f "$temp_disk"

    # Resize to 50G (LUKS images need explicit resize)
    sudo qemu-img resize --object "secret,id=sec0,data=$password" \
        --image-opts "driver=qcow2,encrypt.key-secret=sec0,file.driver=file,file.filename=$vm_disk" \
        +40G >&2 || log "  Warning: resize failed, using base size"

    success "Encrypted VM disk created: $vm_disk"
    echo "$vm_disk"
}

launch_vm() {
    local vm_disk="$1"
    local config_dir="$2"
    local vm_name="${VM_TYPE}-${VM_NAME}"
    local staging_dir="$VM_STAGING_DIR/${VM_TYPE}-${VM_NAME}"

    log "Launching VM: $vm_name"

    # Remove existing VM if present
    if sudo virsh --connect qemu:///system dominfo "$vm_name" &>/dev/null; then
        log "Removing existing VM definition..."
        sudo virsh --connect qemu:///system destroy "$vm_name" 2>/dev/null || true
        sudo virsh --connect qemu:///system undefine "$vm_name" 2>/dev/null || true
    fi

    # Check bridge
    check_bridge

    # Build virt-install command
    local disk_opts="path=$vm_disk,format=qcow2,bus=virtio,cache=writeback"

    # For encrypted disks, we need to use XML definition instead of virt-install
    # because virt-install doesn't support LUKS encryption directly
    if $ENCRYPT && [[ -n "$ENCRYPT_SECRET_UUID" ]]; then
        log "Creating encrypted VM via XML definition..."
        create_encrypted_vm_xml "$vm_name" "$vm_disk" "$config_dir"
        return
    fi

    local virt_install_args=(
        --connect qemu:///system
        --name "$vm_name"
        --memory "$VM_MEMORY"
        --vcpus "$VM_VCPUS"
        --disk "$disk_opts"
        --network "bridge=$VM_BRIDGE,model=virtio"
        --graphics spice,listen=none
        --video qxl
        --channel spicevmc
        --vsock cid.auto=yes
        --os-variant nixos-unstable
        --boot hd
        --noautoconsole
        --filesystem "source=$config_dir,target=vm-config,mode=squash,readonly=on"
        --filesystem "source=$staging_dir/profiles,target=hydrix-profiles,mode=mapped"
        --filesystem "source=$HOME/.config/hydrix,target=hydrix-config,mode=squash,readonly=on"
        --filesystem "source=$HOME/persist/$VM_TYPE,target=vm-persist,mode=mapped"
    )

    # Add virtiofs for shared /nix/store if enabled
    if [[ "$SHARE_STORE" == true ]]; then
        log "Enabling shared /nix/store via virtiofs..."
        # virtiofs requires shared memory backing and explicit binary path
        virt_install_args+=(
            --memorybacking source.type=memfd,access.mode=shared
            --filesystem source=/nix/store,target=nix-store,driver.type=virtiofs,binary.path=/run/current-system/sw/bin/virtiofsd
        )
    fi

    # Launch with virt-install
    sudo virt-install "${virt_install_args[@]}"

    success "VM launched: $vm_name"
    if [[ "$SHARE_STORE" == true ]]; then
        log "  Shared store: enabled (host /nix/store mounted)"
    fi
}

connect_console() {
    local vm_name="${VM_TYPE}-${VM_NAME}"

    log ""
    log "Connecting to console..."
    log "  (Press Ctrl+] to detach)"
    log ""

    # Small delay to let VM start
    sleep 2

    sudo virsh --connect qemu:///system console "$vm_name"
}

main() {
    parse_args "$@"

    # Detect host resources and calculate VM allocation
    detect_host_resources
    calculate_resources

    local vm_name="${VM_TYPE}-${VM_NAME}"
    local resource_percent=${TYPE_RESOURCES[$VM_TYPE]:-50}

    log "=== Deploying VM ==="
    log "Name: $vm_name"
    log "Type: $VM_TYPE"
    log "User: $VM_USER"
    log "Bridge: $VM_BRIDGE"
    log "Resources: ${VM_VCPUS} vCPUs, ${VM_MEMORY}MB RAM (${resource_percent}% of ${HOST_CORES} cores, ${HOST_RAM_MB}MB)"
    $ENCRYPT && log "Encryption: LUKS (standalone image)"
    log ""

    # Check base image exists
    local base_image
    base_image=$(check_base_image)
    log "Base image: $base_image"

    # Create config directory
    local config_dir
    config_dir=$(create_vm_config)

    # Create disk (encrypted or overlay)
    local vm_disk
    local luks_password=""

    if $ENCRYPT; then
        log ""
        log "=== LUKS Encryption ==="
        log "Enter password for encrypted VM disk."
        log "You will need this password each time the VM starts."
        log ""

        # Prompt for password (twice for confirmation)
        local pass1 pass2
        read -s -p "Enter encryption password: " pass1
        echo >&2
        read -s -p "Confirm encryption password: " pass2
        echo >&2

        if [[ "$pass1" != "$pass2" ]]; then
            error "Passwords do not match"
        fi
        if [[ -z "$pass1" ]]; then
            error "Password cannot be empty"
        fi

        luks_password="$pass1"
        # Clear confirmation variables immediately
        unset pass1 pass2

        # Create libvirt secret for the password
        log "Creating libvirt secret..."
        ENCRYPT_SECRET_UUID=$(create_luks_secret "${VM_TYPE}-${VM_NAME}" "$luks_password")
        success "Secret created: $ENCRYPT_SECRET_UUID"

        # Create encrypted disk (standalone, full copy)
        # NOTE: Password is briefly visible in qemu-img command line (ps aux)
        # This is a known limitation - libvirt secret stores it securely after creation
        vm_disk=$(create_encrypted_disk "$base_image" "$luks_password")
        # Clear password from memory after use
        unset luks_password
    else
        # Create overlay disk (thin, uses backing file)
        vm_disk=$(create_vm_disk "$base_image")
    fi

    # Launch VM
    launch_vm "$vm_disk" "$config_dir"

    log ""
    log "VM is starting. First boot will configure hostname and user."
    if $ENCRYPT; then
        log ""
        log "=== Encrypted VM ==="
        log "This VM uses LUKS encryption."
        log "You must enter the password each time the VM starts."
        log "Secret UUID: $ENCRYPT_SECRET_UUID"
        log ""
        log "To start later:"
        log "  sudo virsh start ${VM_TYPE}-${VM_NAME}"
        log ""
        log "To remove the secret (when deleting VM):"
        log "  sudo virsh secret-undefine $ENCRYPT_SECRET_UUID"
    fi
    log ""

    if $NO_CONNECT; then
        log "Connect manually with:"
        log "  sudo virsh --connect qemu:///system console $vm_name"
        log "  virt-manager (system connection)"
    else
        connect_console
    fi
}

main "$@"
