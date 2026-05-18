#!/usr/bin/env bash
# vm-sync - Host-side package sync for microVMs
#
# Queries running VMs via vsock to list and pull staged packages.
# Packages are staged via: vm-sync push --name <pkg> (inside VM)
#
# Usage:
#   vm-sync list                              # List staged packages from all VMs
#   vm-sync pull <pkg> [--from <vm>]          # Pull package to profile(s)
#   vm-sync status                            # Show installed packages per profile
#
set -euo pipefail

# Auto-detect flake location (user config takes priority)
if [[ -n "${HYDRIX_FLAKE_DIR:-}" && -f "$HYDRIX_FLAKE_DIR/flake.nix" ]]; then
  PROJECT_DIR="$HYDRIX_FLAKE_DIR"
elif [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
  PROJECT_DIR="$HOME/hydrix-config"
elif [[ -f "$HOME/Hydrix/flake.nix" ]]; then
  PROJECT_DIR="$HOME/Hydrix"
else
  echo "Error: No Hydrix config found at ~/hydrix-config or ~/Hydrix" >&2
  exit 1
fi

# User packages go in user's profiles directory
readonly PROFILES_DIR="$PROJECT_DIR/profiles"
readonly STAGING_PORT=14502

# VM types: read from registry if available, otherwise fall back to defaults
VM_REGISTRY="/etc/hydrix/vm-registry.json"
if [[ -f "$VM_REGISTRY" ]]; then
    readarray -t VM_TYPES < <(jq -r 'keys[]' "$VM_REGISTRY" 2>/dev/null)
else
    VM_TYPES=("browsing" "pentest" "dev" "comms" "lurking")
fi
readonly VM_TYPES

# Colors
readonly RED=$'\e[31m'
readonly GREEN=$'\e[32m'
readonly YELLOW=$'\e[33m'
readonly CYAN=$'\e[36m'
readonly MAGENTA=$'\e[35m'
readonly NC=$'\e[0m'
readonly BOLD=$'\e[1m'
readonly DIM=$'\e[38;5;8m'

log() { echo -e "$*"; }
error() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}$*${NC}"; }

# Get vsock CID - registry lookup, fallback to nix eval
get_cid() {
    local vm_name="$1"
    if [[ -f "$VM_REGISTRY" ]]; then
        local profile="${vm_name#microvm-}"
        local cid
        cid=$(jq -r --arg p "$profile" '.[$p].cid // empty' "$VM_REGISTRY" 2>/dev/null || echo "")
        [[ -n "$cid" ]] && echo "$cid" && return
    fi
    nix eval --json "$PROJECT_DIR#nixosConfigurations.${vm_name}.config.hydrix.microvm.vsockCid" 2>/dev/null || echo ""
}

# Check if VM is running
is_running() {
    local vm_name="$1"
    systemctl is-active --quiet "microvm@${vm_name}.service" 2>/dev/null
}

# Query VM staging server
query_vm() {
    local cid="$1"
    local cmd="$2"
    echo "$cmd" | socat -t5 - "VSOCK-CONNECT:${cid}:${STAGING_PORT}" 2>/dev/null || echo ""
}

# Get list of running microVMs
get_running_vms() {
    local declared
    declared=$(nix eval "$PROJECT_DIR#nixosConfigurations" --apply 'builtins.attrNames' --json 2>/dev/null | jq -r '.[]' | grep '^microvm-' | grep -v 'router' || true)

    local running=()
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        if is_running "$vm"; then
            running+=("$vm")
        fi
    done <<< "$declared"

    printf '%s\n' "${running[@]}"
}

# List staged packages from all running VMs
cmd_list() {
    log "${BOLD}Querying running VMs for staged packages...${NC}"
    echo ""

    local found=false
    local running_vms
    readarray -t running_vms < <(get_running_vms)

    if [[ ${#running_vms[@]} -eq 0 ]]; then
        log "  ${DIM}No VMs running${NC}"
        echo ""
        log "Start a VM with: microvm start <vm>"
        return
    fi

    for vm in "${running_vms[@]}"; do
        [[ -z "$vm" ]] && continue
        local cid
        cid=$(get_cid "$vm")
        [[ -z "$cid" ]] && continue

        local response
        response=$(query_vm "$cid" "list")
        [[ -z "$response" ]] && continue

        # Parse JSON response
        local packages vm_type
        packages=$(echo "$response" | jq -r '.packages[]?' 2>/dev/null || true)
        vm_type=$(echo "$response" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")

        if [[ -n "$packages" ]]; then
            log "  ${CYAN}${vm}${NC} (${vm_type}):"
            while IFS= read -r pkg; do
                [[ -n "$pkg" ]] && log "    ${YELLOW}$pkg${NC}" && found=true
            done <<< "$packages"
        fi
    done

    if [[ "$found" == "false" ]]; then
        log "  ${DIM}No staged packages found${NC}"
        echo ""
        log "Stage packages from inside a VM:"
        log "  vm-dev build <github-url>"
        log "  vm-dev run <name>"
        log "  vm-sync push --name <name>"
    fi
}

# Show dev packages (not yet staged)
cmd_dev() {
    log "${BOLD}Development packages in running VMs:${NC}"
    echo ""

    local running_vms
    readarray -t running_vms < <(get_running_vms)

    if [[ ${#running_vms[@]} -eq 0 ]]; then
        log "  ${DIM}No VMs running${NC}"
        return
    fi

    for vm in "${running_vms[@]}"; do
        [[ -z "$vm" ]] && continue
        local cid
        cid=$(get_cid "$vm")
        [[ -z "$cid" ]] && continue

        local response
        response=$(query_vm "$cid" "dev")
        [[ -z "$response" ]] && continue

        local packages vm_type
        packages=$(echo "$response" | jq -r '.packages[]?' 2>/dev/null || true)
        vm_type=$(echo "$response" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")

        if [[ -n "$packages" ]]; then
            log "  ${CYAN}${vm}${NC} (${vm_type}):"
            echo "$response" | jq -r '.packages[] | "    \(.name) \(if .staged then "[staged]" else "" end)"' 2>/dev/null || true
        fi
    done
}

# Show installed packages per profile
cmd_status() {
    log "${BOLD}User packages ($PROFILES_DIR):${NC}"

    for vm_type in "${VM_TYPES[@]}"; do
        local packages_dir="$PROFILES_DIR/$vm_type/packages"
        log ""
        log "${CYAN}$vm_type${NC}:"

        if [[ -d "$packages_dir" ]]; then
            local found=false
            for pkg_file in "$packages_dir"/*.nix; do
                [[ ! -f "$pkg_file" ]] && continue
                [[ "$(basename "$pkg_file")" == "default.nix" ]] && continue
                log "  $(basename "$pkg_file" .nix)"
                found=true
            done
            [[ "$found" == "false" ]] && log "  ${DIM}(none)${NC}"
        else
            log "  ${DIM}(none)${NC}"
        fi
    done
}

# Regenerate default.nix for a profile's packages
regenerate_default() {
    local vm_type="$1"
    local packages_dir="$PROFILES_DIR/$vm_type/packages"
    local default_file="$packages_dir/default.nix"

    # Ensure directory exists
    mkdir -p "$packages_dir"

    # Collect package files
    local package_files=()
    for pkg_file in "$packages_dir"/*.nix; do
        [[ ! -f "$pkg_file" ]] && continue
        [[ "$(basename "$pkg_file")" == "default.nix" ]] && continue
        package_files+=("$(basename "$pkg_file" .nix)")
    done

    # Write default.nix as a NixOS module
    cat > "$default_file" << 'EOF'
# Custom packages for PROFILE profile
# Managed by vm-sync - regenerated when packages are added/removed
#
# Workflow:
#   1. In VM:  vm-dev build https://github.com/owner/repo
#   2. In VM:  vm-sync push --name repo
#   3. On host: vm-sync pull repo --target PROFILE
#   4. Rebuild: microvm build micro<name>
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = [
EOF
    # Replace PROFILE placeholder
    sed -i "s/PROFILE/$vm_type/g" "$default_file"

    for pkg_name in "${package_files[@]}"; do
        echo "    (import ./${pkg_name}.nix { inherit pkgs; })" >> "$default_file"
    done

    echo "  ];" >> "$default_file"
    echo "}" >> "$default_file"
}

# Find VM with staged package
find_vm_with_package() {
    local pkg_name="$1"
    local running_vms
    readarray -t running_vms < <(get_running_vms)

    for vm in "${running_vms[@]}"; do
        [[ -z "$vm" ]] && continue
        local cid
        cid=$(get_cid "$vm")
        [[ -z "$cid" ]] && continue

        local response
        response=$(query_vm "$cid" "info $pkg_name")
        if [[ -n "$response" ]] && ! echo "$response" | jq -e '.error' >/dev/null 2>&1; then
            echo "$vm"
            return 0
        fi
    done
    return 1
}

# Pull package from VM
cmd_pull() {
    local pkg_name=""
    local from_vm=""
    local targets=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from|-f)
                from_vm="$2"
                shift 2
                ;;
            --target|-t)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    targets+=("$1")
                    shift
                done
                ;;
            *)
                [[ -z "$pkg_name" ]] && pkg_name="$1"
                shift
                ;;
        esac
    done

    [[ -z "$pkg_name" ]] && error "Usage: vm-sync pull <pkg> [--from <vm>] [--target <type>...]"

    # Find VM with package
    if [[ -z "$from_vm" ]]; then
        if ! from_vm=$(find_vm_with_package "$pkg_name"); then
            error "Package '$pkg_name' not found in any running VM"
        fi
        log "Found ${BOLD}$pkg_name${NC} in ${CYAN}$from_vm${NC}"
    fi

    # Get CID
    local cid
    cid=$(get_cid "$from_vm")
    [[ -z "$cid" ]] && error "Cannot get CID for $from_vm"

    # Get package info for target suggestion
    local info
    info=$(query_vm "$cid" "info $pkg_name")
    local vm_type
    vm_type=$(echo "$info" | jq -r '.type // "browsing"' 2>/dev/null)

    # If no targets specified, use the VM's type
    if [[ ${#targets[@]} -eq 0 ]]; then
        log "Target profile(s)? (default: $vm_type)"
        log "Available: ${VM_TYPES[*]}"
        read -p "> " -a targets
        [[ ${#targets[@]} -eq 0 ]] && targets=("$vm_type")
    fi

    # Pull via vsock
    log "Pulling ${BOLD}$pkg_name${NC} from ${from_vm}..."
    local temp_dir
    temp_dir=$(mktemp -d)

    if ! query_vm "$cid" "get $pkg_name" | tar xf - -C "$temp_dir" 2>/dev/null; then
        rm -rf "$temp_dir"
        error "Failed to pull package from VM"
    fi

    # Copy to user's profile packages directory
    for target in "${targets[@]}"; do
        # Validate target
        local valid=false
        for vt in "${VM_TYPES[@]}"; do
            [[ "$target" == "$vt" ]] && valid=true && break
        done
        [[ "$valid" == "false" ]] && { log "${YELLOW}Skipping invalid target: $target${NC}"; continue; }

        local packages_dir="$PROFILES_DIR/$target/packages"
        mkdir -p "$packages_dir"

        if [[ -f "$temp_dir/$pkg_name/package.nix" ]]; then
            cp "$temp_dir/$pkg_name/package.nix" "$packages_dir/${pkg_name}.nix"
            log "  Copied to ${CYAN}profiles/$target/packages/${pkg_name}.nix${NC}"
            regenerate_default "$target"
            # Track in git so Nix flake can see them
            git -C "$PROJECT_DIR" add "$packages_dir/${pkg_name}.nix" "$packages_dir/default.nix" 2>/dev/null || true
        else
            log "  ${YELLOW}No package.nix found for $pkg_name${NC}"
        fi
    done

    rm -rf "$temp_dir"

    # Tell the VM to remove the package from its staging area
    query_vm "$cid" "unstage $pkg_name" >/dev/null

    success "Pulled $pkg_name to: ${targets[*]}"
    log ""
    log "Rebuild to apply:"
    log "  microvm build microvm-${targets[0]}"
}

# Remove package from user's profile packages
cmd_remove() {
    local pkg_name=""
    local targets=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target|-t)
                shift
                while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                    targets+=("$1")
                    shift
                done
                ;;
            *)
                [[ -z "$pkg_name" ]] && pkg_name="$1"
                shift
                ;;
        esac
    done

    [[ -z "$pkg_name" ]] && error "Usage: vm-sync remove <pkg> --target <type>"
    [[ ${#targets[@]} -eq 0 ]] && error "Must specify --target"

    for target in "${targets[@]}"; do
        local pkg_file="$PROFILES_DIR/$target/packages/${pkg_name}.nix"
        local default_file="$PROFILES_DIR/$target/packages/default.nix"
        if [[ -f "$pkg_file" ]]; then
            rm "$pkg_file"
            log "Removed from profiles/$target/packages"
            regenerate_default "$target"
            # Update git tracking
            git -C "$PROJECT_DIR" rm --cached "$pkg_file" 2>/dev/null || true
            git -C "$PROJECT_DIR" add "$default_file" 2>/dev/null || true
        else
            log "$pkg_name not in profiles/$target/packages"
        fi
    done
}

# Show staged package content
cmd_show() {
    local pkg_name="${1:-}"
    local from_vm="${2:-}"
    [[ -z "$pkg_name" ]] && error "Usage: vm-sync show <pkg> [--from <vm>]"

    # Find VM with package
    if [[ -z "$from_vm" ]]; then
        if ! from_vm=$(find_vm_with_package "$pkg_name"); then
            error "Package '$pkg_name' not found in any running VM"
        fi
    fi

    local cid
    cid=$(get_cid "$from_vm")
    [[ -z "$cid" ]] && error "Cannot get CID for $from_vm"

    log "${BOLD}$pkg_name${NC} (from $from_vm)"
    log ""

    # Pull and display
    local temp_dir
    temp_dir=$(mktemp -d)
    if query_vm "$cid" "get $pkg_name" | tar xf - -C "$temp_dir" 2>/dev/null; then
        if [[ -f "$temp_dir/$pkg_name/package.nix" ]]; then
            cat "$temp_dir/$pkg_name/package.nix"
        else
            error "No package.nix found"
        fi
    else
        rm -rf "$temp_dir"
        error "Failed to fetch package"
    fi
    rm -rf "$temp_dir"
}

print_usage() {
    cat << 'EOF'
vm-sync - Package sync for microVMs (vsock-based)

Commands:
  list                          List staged packages from running VMs
  dev                           List dev packages (not yet staged)
  pull <pkg> [--from <vm>]      Pull package from VM to profile(s)
      [--target <types>]
  remove <pkg> --target <types> Remove from profile(s)
  status                        Show installed packages per profile
  show <pkg> [--from <vm>]      Show staged package content

Workflow (in VM):
  vm-dev build https://github.com/owner/repo
  vm-dev run repo
  vm-sync push --name repo

Workflow (on host):
  vm-sync list
  vm-sync pull repo --target browsing
  microvm build microvm-browsing

EOF
}

main() {
    case "${1:-}" in
        list|ls)       cmd_list ;;
        dev)           cmd_dev ;;
        pull)          shift; cmd_pull "$@" ;;
        remove|rm)     shift; cmd_remove "$@" ;;
        status)        cmd_status ;;
        show)          shift; cmd_show "$@" ;;
        -h|--help|"")  print_usage ;;
        *)             error "Unknown: $1" ;;
    esac
}

main "$@"
