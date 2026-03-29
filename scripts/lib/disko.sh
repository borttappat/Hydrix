#!/usr/bin/env bash
# disko.sh - Disko-related functions for Hydrix installer
#
# Source this file after common.sh:
#   source "$(dirname "$0")/lib/common.sh"
#   source "$(dirname "$0")/lib/disko.sh"

# Prevent double-sourcing
[[ -n "${_HYDRIX_DISKO_SOURCED:-}" ]] && return
_HYDRIX_DISKO_SOURCED=1

# ========== DISK DETECTION ==========

# List available disks suitable for installation
# Returns: device path, size, model (tab-separated, one per line)
list_disks() {
    lsblk -d -n -o NAME,SIZE,MODEL,TYPE 2>/dev/null | \
        awk '$4 == "disk" { print "/dev/" $1 "\t" $2 "\t" $3 }' | \
        grep -v "loop\|sr\|fd"
}

# Get disk size in bytes
get_disk_size_bytes() {
    local device="$1"
    lsblk -b -d -n -o SIZE "$device" 2>/dev/null
}

# Get disk size in human readable format
get_disk_size() {
    local device="$1"
    lsblk -d -n -o SIZE "$device" 2>/dev/null
}

# Get disk model
get_disk_model() {
    local device="$1"
    lsblk -d -n -o MODEL "$device" 2>/dev/null | xargs
}

# Check if disk is NVMe
is_nvme() {
    local device="$1"
    [[ "$device" == /dev/nvme* ]]
}

# Get partition naming convention for a disk
# NVMe uses p1, p2, etc. SATA uses 1, 2, etc.
get_partition_suffix() {
    local device="$1"
    local part_num="$2"

    if is_nvme "$device"; then
        echo "p${part_num}"
    else
        echo "${part_num}"
    fi
}

# ========== PARTITION DETECTION ==========

# List partitions on a disk
list_partitions() {
    local device="$1"
    lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT "$device" 2>/dev/null | tail -n +2
}

# Detect existing EFI partition on a disk
# Returns the partition device path, or empty if not found
detect_efi_partition() {
    local device="$1"

    # Look for partition with EFI System type or vfat filesystem in EFI location
    local efi_part
    efi_part=$(lsblk -n -o NAME,PARTTYPE "$device" 2>/dev/null | \
        grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | \
        awk '{print $1}' | tr -dc 'a-zA-Z0-9\n_-')

    if [[ -n "$efi_part" ]]; then
        # Handle nvme vs sata naming
        if is_nvme "$device"; then
            echo "/dev/${efi_part}"
        else
            echo "/dev/${efi_part}"
        fi
        return
    fi

    # Fallback: look for vfat partition in first position (common EFI location)
    local first_part
    if is_nvme "$device"; then
        first_part="${device}p1"
    else
        first_part="${device}1"
    fi

    if [[ -b "$first_part" ]]; then
        local fstype
        fstype=$(lsblk -n -o FSTYPE "$first_part" 2>/dev/null)
        if [[ "$fstype" == "vfat" ]]; then
            echo "$first_part"
            return
        fi
    fi

    echo ""
}

# Get free space on disk (unpartitioned space)
# Returns size in bytes, or 0 if no free space
get_free_space() {
    local device="$1"

    # Use parted to get free space
    local free_space
    free_space=$(parted -s "$device" unit B print free 2>/dev/null | \
        grep "Free Space" | tail -1 | awk '{print $3}' | tr -d 'B')

    echo "${free_space:-0}"
}

# Check if disk has sufficient space for Hydrix
# Requires at least 50GB for comfortable use
check_sufficient_space() {
    local device="$1"
    local min_bytes="${2:-53687091200}"  # 50GB default

    local size_bytes
    size_bytes=$(get_disk_size_bytes "$device")

    [[ "$size_bytes" -ge "$min_bytes" ]]
}

# ========== DISK SAFETY CHECKS ==========

# Check if disk contains mounted partitions
has_mounted_partitions() {
    local device="$1"
    mount | grep -q "^${device}"
}

# Check if disk is the current root disk
is_root_disk() {
    local device="$1"

    local root_device
    root_device=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//')

    # Get the base device (remove partition number)
    local root_base
    root_base=$(echo "$root_device" | sed 's/p\?[0-9]*$//')

    [[ "$root_base" == "$device" ]]
}

# Get list of disks safe for installation (not root, not mounted)
list_safe_disks() {
    while IFS=$'\t' read -r device size model; do
        if ! is_root_disk "$device" && ! has_mounted_partitions "$device"; then
            printf "%s\t%s\t%s\n" "$device" "$size" "$model"
        fi
    done < <(list_disks)
}

# ========== DISKO OPERATIONS ==========

# Run disko with appropriate template
# Args: template_path, device, [additional args...]
run_disko() {
    local template="$1"
    local device="$2"
    shift 2

    log "Running disko with template: $(basename "$template")"
    log "Target device: $device"

    if [[ ! -f "$template" ]]; then
        error "Disko template not found: $template"
    fi

    # Build the disko command
    local cmd="disko --mode disko --arg device '\"$device\"'"

    # Add any additional arguments
    for arg in "$@"; do
        cmd="$cmd $arg"
    done

    cmd="$cmd $template"

    log "Executing: $cmd"

    if ! eval "$cmd"; then
        error "Disko failed to partition disk"
    fi

    success "Disk partitioned successfully"
}

# Verify disko mounts are in place
verify_disko_mounts() {
    local expected_mounts=(
        "/mnt"
        "/mnt/boot"
        "/mnt/home"
        "/mnt/nix"
    )

    log "Verifying disk mounts..."

    for mount_point in "${expected_mounts[@]}"; do
        if ! mountpoint -q "$mount_point" 2>/dev/null; then
            error "Expected mount not found: $mount_point"
        fi
        log "  [OK] $mount_point"
    done

    success "All expected mounts verified"
}

# ========== LUKS OPERATIONS ==========

# Write LUKS password to temp file (for disko)
write_luks_password() {
    local password="$1"
    local password_file="/tmp/luks-password"

    echo -n "$password" > "$password_file"
    chmod 600 "$password_file"

    log "LUKS password written to $password_file"
}

# Clean up LUKS password file
cleanup_luks_password() {
    local password_file="/tmp/luks-password"

    if [[ -f "$password_file" ]]; then
        shred -u "$password_file" 2>/dev/null || rm -f "$password_file"
        log "Cleaned up LUKS password file"
    fi
}

# ========== BTRFS DETECTION ==========

# Check if current system was installed with disko BTRFS
is_disko_btrfs_install() {
    # Check for BTRFS root with @ subvolume
    if ! command_exists btrfs; then
        return 1
    fi

    # Check if root is BTRFS
    local root_fs
    root_fs=$(stat -f -c %T / 2>/dev/null)
    if [[ "$root_fs" != "btrfs" ]]; then
        return 1
    fi

    # Check for @ subvolume (disko signature)
    if btrfs subvolume list / 2>/dev/null | grep -q "path @$"; then
        return 0
    fi

    return 1
}

# List BTRFS subvolumes
list_btrfs_subvolumes() {
    btrfs subvolume list / 2>/dev/null | awk '{print $NF}'
}

# ========== SWAP CALCULATION ==========

# Calculate recommended swap size based on RAM
# Returns size string suitable for disko (e.g., "16G")
calculate_swap_size() {
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$((ram_kb / 1024 / 1024))

    # Swap recommendations:
    # - RAM <= 2GB: 2x RAM
    # - RAM 2-8GB: Equal to RAM
    # - RAM 8-64GB: At least 4GB, up to 0.5x RAM
    # - RAM > 64GB: 4GB (hibernation not practical anyway)

    local swap_gb
    if [[ $ram_gb -le 2 ]]; then
        swap_gb=$((ram_gb * 2))
    elif [[ $ram_gb -le 8 ]]; then
        swap_gb=$ram_gb
    elif [[ $ram_gb -le 64 ]]; then
        swap_gb=$((ram_gb / 2))
        [[ $swap_gb -lt 4 ]] && swap_gb=4
    else
        swap_gb=4
    fi

    echo "${swap_gb}G"
}

# ========== INTERACTIVE DISK SELECTION ==========

# Interactive disk selection menu
# Returns selected device path
select_disk_interactive() {
    local prompt="${1:-Select disk for installation}"

    echo ""
    log "========================================"
    log "  DISK SELECTION"
    log "========================================"
    echo ""

    local disks=()
    local i=1

    while IFS=$'\t' read -r device size model; do
        disks+=("$device")
        local status=""
        if is_root_disk "$device"; then
            status=" ${RED}[CURRENT ROOT - DANGEROUS]${NC}"
        elif has_mounted_partitions "$device"; then
            status=" ${YELLOW}[HAS MOUNTED PARTITIONS]${NC}"
        fi
        printf "  %d) %-15s %8s  %s%b\n" "$i" "$device" "$size" "$model" "$status"
        ((i++))
    done < <(list_disks)

    if [[ ${#disks[@]} -eq 0 ]]; then
        error "No disks found"
    fi

    echo ""
    local selection
    while true; do
        read -p "$prompt [1-$((i-1))]: " selection

        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -lt "$i" ]]; then
            local selected_device="${disks[$((selection-1))]}"

            # Warn about dangerous selections
            if is_root_disk "$selected_device"; then
                echo ""
                warn "WARNING: This is your current root disk!"
                warn "Installing here will destroy your running system!"
                read -p "Are you ABSOLUTELY sure? Type 'yes' to confirm: " confirm
                if [[ "$confirm" != "yes" ]]; then
                    continue
                fi
            fi

            echo "$selected_device"
            return
        fi

        warn "Invalid selection. Please enter a number between 1 and $((i-1))"
    done
}

# ========== INSTALLATION TYPE SELECTION ==========

# Interactive installation type selection
# Returns: "full-disk-luks", "full-disk-plain", or "dual-boot-luks"
select_install_type() {
    echo ""
    log "========================================"
    log "  INSTALLATION TYPE"
    log "========================================"
    echo ""
    echo "  1) Full disk with LUKS encryption (Recommended)"
    echo "     - Encrypts entire disk with password"
    echo "     - Most secure option"
    echo ""
    echo "  2) Full disk without encryption"
    echo "     - No disk encryption"
    echo "     - Faster boot, but less secure"
    echo ""
    echo "  3) Dual-boot with LUKS encryption"
    echo "     - Install alongside existing OS"
    echo "     - Requires free space on disk"
    echo "     - Reuses existing EFI partition"
    echo ""

    local selection
    while true; do
        read -p "Select installation type [1-3]: " selection

        case "$selection" in
            1) echo "full-disk-luks"; return ;;
            2) echo "full-disk-plain"; return ;;
            3) echo "dual-boot-luks"; return ;;
            *) warn "Invalid selection. Please enter 1, 2, or 3" ;;
        esac
    done
}
