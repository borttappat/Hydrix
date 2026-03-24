#!/usr/bin/env bash
# Build base images for VM deployment
#
# Base images contain the COMPLETE system pre-built.
# Deploying from base images is instant (~5 seconds).
#
# Usage:
#   ./scripts/build-base.sh --type browsing
#   ./scripts/build-base.sh --type pentest --type comms  # Multiple
#   ./scripts/build-base.sh --all                        # All types
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly BASE_IMAGE_DIR="/var/lib/libvirt/base-images"

# Logging
log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }

# Valid VM types
VALID_TYPES=("pentest" "browsing" "comms" "dev" "lurking" "transfer")
BUILD_TYPES=()
BUILD_ALL=false

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build pre-configured base images for instant VM deployment.

Options:
  --type <type>    VM type to build: pentest, browsing, comms, dev
                   Can be specified multiple times
  --all            Build all VM types
  -h, --help       Show this help

Examples:
  $(basename "$0") --type browsing           # Build browsing base image
  $(basename "$0") --type pentest --type dev # Build pentest and dev
  $(basename "$0") --all                     # Build all base images

After building, deploy with:
  ./scripts/deploy-vm.sh --type browsing --name myvm --user traum
EOF
    exit 0
}

parse_args() {
    [[ $# -eq 0 ]] && print_usage

    while [[ $# -gt 0 ]]; do
        case $1 in
            --type)
                [[ -z "${2:-}" ]] && error "Missing value for --type"
                local type="$2"
                # Validate type
                local valid=false
                for t in "${VALID_TYPES[@]}"; do
                    [[ "$t" == "$type" ]] && valid=true && break
                done
                $valid || error "Invalid type: $type (valid: ${VALID_TYPES[*]})"
                BUILD_TYPES+=("$type")
                shift 2
                ;;
            --all)
                BUILD_ALL=true
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

    # If --all, build all types
    if $BUILD_ALL; then
        BUILD_TYPES=("${VALID_TYPES[@]}")
    fi

    if [[ ${#BUILD_TYPES[@]} -eq 0 ]]; then
        error "No types specified. Use --type or --all"
    fi
}

ensure_base_dir() {
    if [[ ! -d "$BASE_IMAGE_DIR" ]]; then
        log "Creating base image directory: $BASE_IMAGE_DIR"
        sudo mkdir -p "$BASE_IMAGE_DIR"
        sudo chown root:libvirtd "$BASE_IMAGE_DIR"
        sudo chmod 775 "$BASE_IMAGE_DIR"
    fi
}

build_base_image() {
    local type="$1"
    local output_name="base-${type}"
    local output_path="$BASE_IMAGE_DIR/${output_name}.qcow2"

    log "Building base image: $output_name"
    log "  This may take several minutes on first build..."

    cd "$PROJECT_DIR"

    # Stage files for nix (including gitignored local/ directory)
    git add -A 2>/dev/null || true
    git add -f local/*.nix local/machines/*.nix 2>/dev/null || true

    # Build the image
    local start_time=$(date +%s)

    # Use nom (nix-output-monitor) if available for better visualization
    if command -v nom &> /dev/null; then
        if ! nom build ".#${output_name}" --out-link "result-${output_name}"; then
            error "Failed to build $output_name"
        fi
    else
        if ! nix build ".#${output_name}" --out-link "result-${output_name}"; then
            error "Failed to build $output_name"
        fi
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Find the built image (path varies between nixos-generators and native building)
    local built_image=""
    local result_dir="result-${output_name}"

    # Check common locations
    for candidate in \
        "$result_dir/nixos.qcow2" \
        "$result_dir/qcow/nixos.qcow2" \
        "$result_dir"/*.qcow2; do
        if [[ -f "$candidate" ]]; then
            built_image="$candidate"
            break
        fi
    done

    if [[ -z "$built_image" ]] || [[ ! -f "$built_image" ]]; then
        log "  Result directory contents:"
        find "$result_dir" -type f 2>/dev/null | head -20 || true
        error "Build succeeded but no qcow2 image found in $result_dir"
    fi

    local size=$(du -h "$built_image" | cut -f1)
    log "  Built in ${duration}s, size: $size"

    # Copy to final location
    log "  Copying to: $output_path"
    sudo cp "$built_image" "$output_path"
    sudo chown root:libvirtd "$output_path"
    sudo chmod 644 "$output_path"

    # Write revision marker for staleness tracking
    local current_rev=""
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        current_rev=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi
    if [[ -n "$current_rev" ]]; then
        echo "$current_rev" | sudo tee "$BASE_IMAGE_DIR/.${output_name}.rev" > /dev/null
        log "  Revision marker: $current_rev"
    fi

    # Write profile revision marker for cross-VM update notification
    # This allows running VMs to detect when their profile was updated
    local vm_config_dir="/var/lib/libvirt/vm-configs"
    if [[ -d "$vm_config_dir" ]]; then
        local timestamp=$(date +%s)
        echo "${timestamp}:${current_rev}" | sudo tee "$vm_config_dir/.profile-rev-${type}" > /dev/null
        log "  Profile marker: $vm_config_dir/.profile-rev-${type}"
    fi

    # Clean up result symlink
    rm -f "result-${output_name}"

    success "Base image ready: $output_path ($size)"
}

main() {
    parse_args "$@"

    log "=== Building Base Images ==="
    log "Types: ${BUILD_TYPES[*]}"
    log ""

    ensure_base_dir

    local failed=()
    for type in "${BUILD_TYPES[@]}"; do
        log "----------------------------------------"
        if build_base_image "$type"; then
            :
        else
            failed+=("$type")
        fi
        log ""
    done

    log "========================================"
    if [[ ${#failed[@]} -eq 0 ]]; then
        success "All base images built successfully!"
        log ""
        log "Deploy VMs with:"
        for type in "${BUILD_TYPES[@]}"; do
            log "  ./scripts/deploy-vm.sh --type $type --name <name> --user <user>"
        done
    else
        error "Failed to build: ${failed[*]}"
    fi
}

main "$@"
