#!/usr/bin/env bash
# setup-local.sh - Create standalone local Hydrix configuration
#
# This script creates ~/local-hydrix/ with:
# - Symlinks to Hydrix repo (modules, configs, scripts, colorschemes, wallpapers)
# - Generated files (flake.nix, machine profile, secrets)
# - Everything needed to build and manage the system
#
# The local repo is completely standalone after setup.
# Updates to Hydrix propagate automatically via symlinks.
#
# Usage: ./scripts/setup-local.sh [OPTIONS]
#
# Options:
#   --local-dir PATH   Override local directory (default: ~/local-hydrix)
#   --skip-router      Skip router VM build
#   --skip-build       Skip system build (just generate configs)
#   -h, --help         Show this help

set -euo pipefail

# ========== CONFIGURATION ==========

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HYDRIX_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_DIR="${HOME}/local-hydrix"

# Options
SKIP_ROUTER=false
SKIP_BUILD=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ========== LOGGING ==========

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ========== DETECTION FUNCTIONS ==========

detect_hostname() {
    local hostname
    hostname=$(hostnamectl hostname 2>/dev/null || hostname)
    hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
    [[ -z "$hostname" ]] && error "Could not detect hostname"
    echo "$hostname"
}

detect_cpu_platform() {
    local vendor
    vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
    case "$vendor" in
        GenuineIntel) echo "intel" ;;
        AuthenticAMD) echo "amd" ;;
        *) echo "intel" ;;
    esac
}

detect_asus_system() {
    local vendor
    vendor=$(hostnamectl 2>/dev/null | grep "Hardware Vendor" | cut -d: -f2 | xargs || echo "")
    echo "$vendor" | grep -qi "asus" && echo "true" || echo "false"
}

detect_current_user() {
    local user="${SUDO_USER:-$(whoami)}"
    [[ "$user" == "root" ]] && error "Could not detect non-root user"
    echo "$user"
}

get_iommu_param() {
    [[ "$1" == "amd" ]] && echo "amd_iommu=on" || echo "intel_iommu=on"
}

# ========== LOCALE DETECTION ==========

detect_timezone() {
    local tz
    tz=$(grep -E "time\.timeZone\s*=" /etc/nixos/configuration.nix 2>/dev/null | sed 's/.*=\s*"\([^"]*\)".*/\1/' | head -1)
    [[ -z "$tz" ]] && tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
    echo "$tz"
}

detect_locale() {
    local loc
    loc=$(grep -E "i18n\.defaultLocale\s*=" /etc/nixos/configuration.nix 2>/dev/null | sed 's/.*=\s*"\([^"]*\)".*/\1/' | head -1)
    [[ -z "$loc" ]] && loc="en_US.UTF-8"
    echo "$loc"
}

detect_keyboard() {
    local kb
    kb=$(grep -E "^\s*layout\s*=" /etc/nixos/configuration.nix 2>/dev/null | sed 's/.*=\s*"\([^"]*\)".*/\1/' | head -1)
    [[ -z "$kb" ]] && kb="us"
    echo "$kb"
}

detect_luks_device() {
    local luks
    luks=$(grep -E "boot\.initrd\.luks\.devices" /etc/nixos/configuration.nix 2>/dev/null | grep -oP '"/dev/[^"]+' | tr -d '"' | head -1)
    echo "${luks:-}"
}

# ========== HARDWARE DETECTION ==========

run_hardware_detection() {
    log "Detecting WiFi hardware for passthrough..."

    # Check if valid hardware-results.env already exists
    if [[ -f "$HYDRIX_DIR/hardware-results.env" ]]; then
        source "$HYDRIX_DIR/hardware-results.env"
        if [[ -n "$PRIMARY_PCI" ]] && [[ -n "$PRIMARY_ID" ]] && [[ -n "$PRIMARY_DRIVER" ]]; then
            log "  Using existing hardware detection:"
            log "  WiFi: $PRIMARY_INTERFACE ($PRIMARY_ID) on $PRIMARY_PCI"
            log "  Driver: $PRIMARY_DRIVER"
            return 0
        fi
    fi

    # Run hardware detection
    if [[ -x "$HYDRIX_DIR/scripts/hardware-identify.sh" ]]; then
        cd "$HYDRIX_DIR"
        "$HYDRIX_DIR/scripts/hardware-identify.sh" || error "Hardware detection failed"
    else
        error "hardware-identify.sh not found"
    fi

    [[ ! -f "$HYDRIX_DIR/hardware-results.env" ]] && error "Hardware detection produced no results"
    source "$HYDRIX_DIR/hardware-results.env"

    [[ -z "$PRIMARY_PCI" ]] && error "No WiFi hardware detected for passthrough"

    log "  WiFi: $PRIMARY_INTERFACE ($PRIMARY_ID) on $PRIMARY_PCI"
    log "  Driver: $PRIMARY_DRIVER"
}

# ========== PASSWORD PROMPT ==========

prompt_password() {
    local prompt_text="$1"
    local password1="" password2="" attempts=0

    echo "" >&2
    log "$prompt_text"

    while [[ "$password1" != "$password2" ]] || [[ -z "$password1" ]]; do
        [[ $attempts -gt 0 ]] && warn "Passwords do not match. Try again."

        read -s -p "Enter password: " password1
        echo "" >&2
        read -s -p "Confirm password: " password2
        echo "" >&2

        ((attempts++))
        [[ $attempts -gt 3 ]] && error "Too many failed attempts"
    done

    # Return plaintext - NixOS initialPassword handles it
    echo "$password1"
}

# ========== DIRECTORY STRUCTURE ==========

create_local_structure() {
    log "Creating local directory structure..."

    # Main directories
    mkdir -p "$LOCAL_DIR"/{machines,profiles}

    # Local-only config (secrets, VM configs, credentials)
    # This mirrors the structure expected by build-vm.sh
    mkdir -p "$LOCAL_DIR"/local/{vms,credentials}

    # Legacy secrets location (for host secrets)
    mkdir -p "$LOCAL_DIR"/secrets

    success "Created: $LOCAL_DIR"
}

create_symlinks() {
    log "Creating symlinks to Hydrix..."

    local dirs_to_link=(
        "modules"
        "configs"
        "scripts"
        "colorschemes"
        "wallpapers"
    )

    for dir in "${dirs_to_link[@]}"; do
        local target="$HYDRIX_DIR/$dir"
        local link="$LOCAL_DIR/$dir"

        if [[ -L "$link" ]]; then
            log "  [skip] $dir (already linked)"
        elif [[ -d "$link" ]]; then
            warn "  [!] $dir exists as directory, skipping"
        elif [[ -d "$target" ]]; then
            ln -s "$target" "$link"
            log "  [+] $dir → $target"
        else
            warn "  [!] $target not found, skipping"
        fi
    done

    # Also link profiles directory (contains VM profiles)
    if [[ ! -L "$LOCAL_DIR/profiles" ]] && [[ -d "$HYDRIX_DIR/profiles" ]]; then
        rm -rf "$LOCAL_DIR/profiles"
        ln -s "$HYDRIX_DIR/profiles" "$LOCAL_DIR/profiles"
        log "  [+] profiles → $HYDRIX_DIR/profiles"
    fi

    success "Symlinks created"
}

# ========== GENERATE SECRETS ==========

generate_host_secrets() {
    local username="$1"
    local secrets_file="$LOCAL_DIR/secrets/host.nix"

    if [[ -f "$secrets_file" ]]; then
        warn "secrets/host.nix exists - skipping (delete to regenerate)"
        return
    fi

    log "Generating host secrets..."

    # Detect settings
    local timezone locale keyboard luks_device
    timezone=$(detect_timezone)
    locale=$(detect_locale)
    keyboard=$(detect_keyboard)
    luks_device=$(detect_luks_device)

    # Note: No password hash - user's existing password from installation is preserved
    cat > "$secrets_file" << EOF
# Host secrets - Generated by setup-local.sh
# Machine: $(detect_hostname)
# Generated: $(date)
#
# This file is LOCAL ONLY - never commit to version control.
# Note: Password is NOT stored here - user's existing password
# from installation is preserved.

{
  # Primary user account (detected from system)
  username = "$username";

  # SSH public keys (optional)
  sshPublicKeys = [
    # "ssh-ed25519 AAAA... user@host"
  ];

  # System settings
  timezone = "$timezone";
  locale = "$locale";
  keyboardLayout = "$keyboard";

  # LUKS device (if encrypted)
  luksDevice = "$luks_device";
}
EOF

    chmod 600 "$secrets_file"
    success "Generated: secrets/host.nix"
}

generate_router_config() {
    local username="$1"
    local config_file="$LOCAL_DIR/router-vm-config.nix"
    local template="$HYDRIX_DIR/templates/router-vm-config.nix.template"

    if [[ -f "$config_file" ]]; then
        warn "router-vm-config.nix exists - skipping"
        return
    fi

    log "Generating router VM configuration..."

    # Prompt for router password (uses same username as host)
    local password
    password=$(prompt_password "Set password for router VM (user: $username)")

    # Copy template and substitute placeholders using bash (avoids sed escaping issues)
    local content
    content=$(<"$template")
    content="${content//__ROUTER_USER__/$username}"
    content="${content//__ROUTER_PASSWORD__/$password}"
    content="${content//__SSH_PASSWORD_AUTH__/true}"
    content="${content//__SSH_KEYS__/}"
    printf '%s\n' "$content" > "$config_file"

    chmod 600 "$config_file"
    success "Generated: router-vm-config.nix"
}

# ========== GENERATE FLAKE ==========

generate_flake() {
    local hostname="$1"
    local flake_file="$LOCAL_DIR/flake.nix"
    local template="$HYDRIX_DIR/templates/flake.nix.template"

    log "Generating flake.nix..."

    if [[ ! -f "$template" ]]; then
        error "Template not found: $template"
    fi

    # Copy and substitute
    cp "$template" "$flake_file"
    sed -i "s|@@HOSTNAME@@|${hostname}|g" "$flake_file"
    sed -i "s|@@DATE@@|$(date)|g" "$flake_file"

    success "Generated: flake.nix"
}

# ========== GENERATE MACHINE PROFILE ==========

generate_machine_profile() {
    local hostname="$1"
    local cpu_platform="$2"
    local is_asus="$3"
    local username="$4"
    local profile_file="$LOCAL_DIR/machines/${hostname}.nix"
    local template="$HYDRIX_DIR/templates/machine-profile-full.nix.template"

    log "Generating machine profile..."

    source "$HYDRIX_DIR/hardware-results.env"

    local iommu_param pci_short hw_imports
    iommu_param=$(get_iommu_param "$cpu_platform")
    pci_short="${PRIMARY_PCI#0000:}"

    # Build hardware imports
    hw_imports=""
    if [[ "$cpu_platform" == "intel" ]]; then
        hw_imports="${hw_imports}
    ../modules/base/hardware/intel.nix"
    fi
    if [[ "$is_asus" == "true" ]]; then
        hw_imports="${hw_imports}
    ../modules/base/hardware/asus.nix"
    fi

    cp "$template" "$profile_file"

    # Perform substitutions
    sed -i "s|{{MACHINE_NAME}}|${hostname}|g" "$profile_file"
    sed -i "s|{{DATE}}|$(date)|g" "$profile_file"
    sed -i "s|{{CPU_PLATFORM}}|${cpu_platform}|g" "$profile_file"
    sed -i "s|{{IS_ASUS}}|${is_asus}|g" "$profile_file"
    sed -i "s|{{PRIMARY_ID}}|${PRIMARY_ID}|g" "$profile_file"
    sed -i "s|{{PRIMARY_PCI}}|${PRIMARY_PCI}|g" "$profile_file"
    sed -i "s|{{PRIMARY_PCI_SHORT}}|${pci_short}|g" "$profile_file"
    sed -i "s|{{PRIMARY_DRIVER}}|${PRIMARY_DRIVER}|g" "$profile_file"
    sed -i "s|{{PRIMARY_INTERFACE}}|${PRIMARY_INTERFACE}|g" "$profile_file"
    sed -i "s|{{IOMMU_PARAM}}|${iommu_param}|g" "$profile_file"
    sed -i "s|{{USER}}|${username}|g" "$profile_file"

    # Handle multi-line HW_IMPORTS
    local escaped_imports
    escaped_imports=$(printf '%s\n' "$hw_imports" | sed 's/[&/\]/\\&/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    sed -i "s|{{HW_IMPORTS}}|${escaped_imports}|g" "$profile_file"

    success "Generated: machines/${hostname}.nix"
}

# ========== BUILD ROUTER VM ==========

build_router_vm() {
    log "Building router VM..."

    cd "$LOCAL_DIR"

    local libvirt_image="/var/lib/libvirt/images/router-vm.qcow2"

    if [[ -f "$libvirt_image" ]]; then
        log "Router VM already installed at $libvirt_image"
        return
    fi

    log "Building router VM image (this may take several minutes)..."

    if ! nix-shell -p virtiofsd --run "nix build .#router --out-link router-result"; then
        error "Router VM build failed"
    fi

    if [[ ! -f "router-result/nixos.qcow2" ]]; then
        error "Router VM build produced no image"
    fi

    log "Installing to libvirt storage..."
    sudo mkdir -p /var/lib/libvirt/images
    sudo cp "router-result/nixos.qcow2" "$libvirt_image"
    sudo chmod 644 "$libvirt_image"

    success "Router VM installed: $libvirt_image"
}

# ========== BUILD SYSTEM ==========

build_system() {
    local hostname="$1"

    log "Building system configuration..."

    cd "$LOCAL_DIR"

    log "Running: nixos-rebuild boot --flake .#${hostname}"

    if sudo nixos-rebuild boot --impure --flake ".#${hostname}"; then
        success "System built - reboot to activate"
    else
        error "System build failed"
    fi
}

# ========== INIT GIT ==========

init_git() {
    log "Initializing git repository..."

    cd "$LOCAL_DIR"

    if [[ -d ".git" ]]; then
        log "Git already initialized"
        return
    fi

    git init

    # Create .gitignore
    cat > .gitignore << 'EOF'
# Secrets - NEVER commit
secrets/
router-vm-config.nix

# Local VM config (secrets, credentials)
local/

# Build artifacts
result
*-result

# Editor files
*.swp
*~
.vscode/
.idea/
EOF

    git add .
    git commit -m "Initial local-hydrix setup"

    success "Git repository initialized"
}

# ========== COMPLETION SUMMARY ==========

show_summary() {
    local hostname="$1"
    local username="$2"

    echo ""
    echo -e "${GREEN}========================================"
    echo "  LOCAL HYDRIX SETUP COMPLETE!"
    echo -e "========================================${NC}"
    echo ""
    echo "Local Repository: $LOCAL_DIR"
    echo ""
    echo "Structure:"
    echo "  modules/      → $HYDRIX_DIR/modules/     (symlink)"
    echo "  configs/      → $HYDRIX_DIR/configs/     (symlink)"
    echo "  scripts/      → $HYDRIX_DIR/scripts/     (symlink)"
    echo "  colorschemes/ → $HYDRIX_DIR/colorschemes/ (symlink)"
    echo "  wallpapers/   → $HYDRIX_DIR/wallpapers/   (symlink)"
    echo "  profiles/     → $HYDRIX_DIR/profiles/     (symlink)"
    echo ""
    echo "  flake.nix                 (generated)"
    echo "  machines/${hostname}.nix  (generated)"
    echo "  router-vm-config.nix      (generated, contains credentials)"
    echo "  secrets/host.nix          (generated, local only)"
    echo ""
    echo "  local/vms/                (VM secrets, generated by build-vm.sh)"
    echo "  local/credentials/        (VM credential references)"
    echo ""
    echo "Build Commands (from $LOCAL_DIR):"
    echo "  nix build .#pentest    # Build pentest VM"
    echo "  nix build .#router     # Build router VM"
    echo "  ./scripts/build-vm.sh --type pentest --name myvm"
    echo ""
    echo "Next Steps:"
    echo "  1. Review secrets in $LOCAL_DIR/secrets/"
    echo "  2. Reboot to activate: sudo reboot"
    echo ""
    echo "After reboot:"
    echo "  - Router VM auto-starts with WiFi passthrough"
    echo "  - Bridges created: br-mgmt, br-pentest, br-office, br-browse, br-dev"
    echo "  - Host gets internet via router (192.168.100.253)"
    echo ""
}

# ========== ARGUMENT PARSING ==========

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Create standalone local Hydrix configuration.

Options:
  --local-dir PATH   Override local directory (default: ~/local-hydrix)
  --skip-router      Skip router VM build
  --skip-build       Skip system build (just generate configs)
  -h, --help         Show this help

This creates ~/local-hydrix/ with symlinks to Hydrix and generated configs.
The local repo is completely standalone after setup.
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --local-dir)
                LOCAL_DIR="$2"
                shift 2
                ;;
            --skip-router)
                SKIP_ROUTER=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
}

# ========== PREREQUISITES ==========

check_prerequisites() {
    log "Checking prerequisites..."

    [[ $EUID -eq 0 ]] && error "Don't run as root (use sudo when needed)"

    for cmd in nix git sed; do
        command -v "$cmd" >/dev/null 2>&1 || error "Missing: $cmd"
    done

    [[ ! -f "$HYDRIX_DIR/flake.nix" ]] && error "Not in Hydrix directory"
    [[ ! -f "$HYDRIX_DIR/templates/flake.nix.template" ]] && error "Missing flake template"
    [[ ! -f "$HYDRIX_DIR/templates/machine-profile-full.nix.template" ]] && error "Missing machine template"
    [[ ! -f "$HYDRIX_DIR/templates/router-vm-config.nix.template" ]] && error "Missing router template"

    success "Prerequisites OK"
}

# ========== MAIN ==========

main() {
    parse_args "$@"

    echo ""
    log "========================================"
    log "  HYDRIX LOCAL SETUP"
    log "========================================"
    echo ""
    log "Hydrix source: $HYDRIX_DIR"
    log "Local target:  $LOCAL_DIR"
    echo ""

    check_prerequisites

    # Detect machine info
    local hostname cpu_platform is_asus username
    hostname=$(detect_hostname)
    cpu_platform=$(detect_cpu_platform)
    is_asus=$(detect_asus_system)
    username=$(detect_current_user)

    log "Hostname: $hostname"
    log "User: $username"
    log "CPU: $cpu_platform"
    log "ASUS: $is_asus"
    echo ""

    # Run hardware detection
    run_hardware_detection
    echo ""

    # Create structure and symlinks
    create_local_structure
    create_symlinks
    echo ""

    # Generate configs
    generate_host_secrets "$username"
    generate_router_config "$username"
    generate_flake "$hostname"
    generate_machine_profile "$hostname" "$cpu_platform" "$is_asus" "$username"
    echo ""

    # Initialize git
    init_git
    echo ""

    # Build
    if [[ "$SKIP_ROUTER" != true ]]; then
        build_router_vm
        echo ""
    fi

    if [[ "$SKIP_BUILD" != true ]]; then
        build_system "$hostname"
        echo ""
    fi

    show_summary "$hostname" "$username"
}

main "$@"
