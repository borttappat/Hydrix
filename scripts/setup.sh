#!/run/current-system/sw/bin/bash
# setup.sh - Automated new machine setup for Hydrix
#
# This script automatically:
# 1. Detects hostname, CPU platform (Intel/AMD), and current user
# 2. Creates machine profile at local/machines/host.nix (hostname set inside file)
# 3. Generates user configuration (local/host.nix, local/shared.nix)
# 4. Builds router VM image and installs to libvirt storage
# 5. Stages local files with git add -f (gitignored but needed for nix)
# 6. Builds system configuration (#host - single generic flake entry)
#
# Note: flake.nix is NOT modified - it has ONE generic 'host' entry that
# imports ./local/machines/host.nix. All machine-specific config goes there.
#
# Boot Modes Generated:
#   - Default: Router mode (WiFi passed to VM, bridges active)
#   - Fallback: Emergency WiFi mode (re-enables WiFi, normal NetworkManager)
#   - Lockdown: Full isolation (10.100.x.x, VPN routing, host blocked)
#
# Usage: ./scripts/setup.sh [OPTIONS]
#
# Options:
#   --force-rebuild    Force rebuild of router VM even if it exists
#   --skip-router      Skip router VM build (useful for testing)
#   -h, --help         Show this help

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly GENERATED_DIR="$PROJECT_DIR/generated"
readonly TEMPLATES_DIR="$PROJECT_DIR/templates"

# Options
FORCE_REBUILD=false
SKIP_ROUTER=false

# Logging
log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }
warn() { echo "[WARN] $*"; }

# ========== AUTO-DETECTION FUNCTIONS ==========

detect_hostname() {
    local hostname
    hostname=$(hostnamectl hostname 2>/dev/null || hostname)

    # Sanitize hostname for use in Nix identifiers
    # Remove any characters that aren't alphanumeric or hyphen
    hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')

    if [[ -z "$hostname" ]]; then
        error "Could not detect hostname"
    fi

    echo "$hostname"
}

detect_cpu_platform() {
    # Returns "intel" or "amd" based on CPU vendor
    local cpu_vendor
    cpu_vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')

    case "$cpu_vendor" in
        GenuineIntel)
            echo "intel"
            ;;
        AuthenticAMD)
            echo "amd"
            ;;
        *)
            warn "Unknown CPU vendor: $cpu_vendor - defaulting to intel"
            echo "intel"
            ;;
    esac
}

# ========== WIFI DETECTION FUNCTIONS ==========

detect_wifi_ssid() {
    # Get the currently connected WiFi SSID using nmcli
    local ssid
    ssid=$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d: -f2)

    if [[ -z "$ssid" ]]; then
        # Try alternative method
        ssid=$(iwgetid -r 2>/dev/null)
    fi

    echo "$ssid"
}

prompt_wifi_credentials() {
    local detected_ssid="$1"
    local ssid=""
    local password=""

    log ""
    log "========================================"
    log "  WIFI CONFIGURATION"
    log "========================================"
    log ""
    log "The router VM needs WiFi credentials to connect after reboot."
    log ""

    if [[ -n "$detected_ssid" ]]; then
        log "Detected current WiFi network: $detected_ssid"
        echo ""
        read -p "Use this network? [Y/n]: " -r use_detected
        if [[ ! "$use_detected" =~ ^[Nn]$ ]]; then
            ssid="$detected_ssid"
        fi
    fi

    if [[ -z "$ssid" ]]; then
        read -p "Enter WiFi SSID: " ssid
        if [[ -z "$ssid" ]]; then
            warn "No WiFi SSID provided - router VM will need manual WiFi configuration"
            echo ""
            echo ""
            return 1
        fi
    fi

    # Prompt for password
    while true; do
        read -sp "Enter WiFi password for '$ssid': " password
        echo ""

        if [[ -z "$password" ]]; then
            warn "Password cannot be empty"
            continue
        fi

        if [[ ${#password} -lt 8 ]]; then
            warn "WiFi password must be at least 8 characters (WPA2 requirement)"
            continue
        fi

        read -sp "Confirm WiFi password: " password_confirm
        echo ""

        if [[ "$password" != "$password_confirm" ]]; then
            warn "Passwords do not match, try again"
            continue
        fi

        break
    done

    # Return values via global variables (bash limitation)
    WIFI_SSID="$ssid"
    WIFI_PASSWORD="$password"
    return 0
}

get_iommu_param() {
    local platform="$1"
    case "$platform" in
        intel)
            echo "intel_iommu=on"
            ;;
        amd)
            echo "amd_iommu=on"
            ;;
        *)
            echo "intel_iommu=on"
            ;;
    esac
}

detect_asus_system() {
    # Check if this is an ASUS system using hostnamectl
    local vendor
    vendor=$(hostnamectl 2>/dev/null | grep "Hardware Vendor" | cut -d: -f2 | xargs || echo "")

    # Check for ASUS in vendor name (case insensitive)
    if echo "$vendor" | grep -qi "asus"; then
        echo "true"
        return 0
    fi

    echo "false"
    return 1
}

# ========== LOCAL CONFIG DETECTION ==========

# Parse a simple Nix value from configuration.nix
# Usage: parse_nix_value "time.timeZone" "/etc/nixos/configuration.nix"
parse_nix_value() {
    local key="$1"
    local file="${2:-/etc/nixos/configuration.nix}"

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    # Match patterns like: time.timeZone = "Europe/Stockholm";
    # or: layout = "se";
    local value
    value=$(grep -E "^\s*${key}\s*=" "$file" 2>/dev/null | head -1 | sed 's/.*=\s*"\([^"]*\)".*/\1/')
    echo "$value"
}

# Detect locale settings from /etc/nixos/configuration.nix
detect_locale_settings() {
    local config_file="/etc/nixos/configuration.nix"

    # Timezone
    local timezone
    timezone=$(parse_nix_value "time.timeZone" "$config_file")
    if [[ -z "$timezone" ]]; then
        # Fallback to system timezone
        timezone=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
    fi

    # Default locale
    local locale
    locale=$(parse_nix_value "i18n.defaultLocale" "$config_file")
    if [[ -z "$locale" ]]; then
        locale="en_US.UTF-8"
    fi

    # Console keymap
    local console_keymap
    console_keymap=$(parse_nix_value "console.keyMap" "$config_file")
    if [[ -z "$console_keymap" ]]; then
        console_keymap="us"
    fi

    # X11 keyboard layout
    local xkb_layout
    xkb_layout=$(parse_nix_value "layout" "$config_file")
    if [[ -z "$xkb_layout" ]]; then
        xkb_layout="us"
    fi

    # X11 keyboard variant
    local xkb_variant
    xkb_variant=$(parse_nix_value "variant" "$config_file")
    # variant can be empty, that's fine

    # Export for use in generation
    echo "DETECTED_TIMEZONE=$timezone"
    echo "DETECTED_LOCALE=$locale"
    echo "DETECTED_CONSOLE_KEYMAP=$console_keymap"
    echo "DETECTED_XKB_LAYOUT=$xkb_layout"
    echo "DETECTED_XKB_VARIANT=$xkb_variant"
}

# Extract extra locale settings as Nix attribute set
extract_extra_locale_settings() {
    local config_file="/etc/nixos/configuration.nix"

    if [[ ! -f "$config_file" ]]; then
        echo "{}"
        return
    fi

    # Check if extraLocaleSettings exists
    if ! grep -q "i18n.extraLocaleSettings" "$config_file"; then
        echo "{}"
        return
    fi

    # Extract the block - this is a simplified extraction
    # It looks for LC_* settings and builds a Nix attrset
    local settings=""
    while IFS= read -r line; do
        if [[ "$line" =~ (LC_[A-Z]+)\s*=\s*\"([^\"]+)\" ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            settings="${settings}    ${key} = \"${value}\";\n"
        fi
    done < "$config_file"

    if [[ -n "$settings" ]]; then
        echo -e "{\n${settings}  }"
    else
        echo "{}"
    fi
}

# Generate local/shared.nix from detected settings
generate_shared_config() {
    local username="$1"
    local local_dir="$PROJECT_DIR/local"
    local shared_file="$local_dir/shared.nix"

    mkdir -p "$local_dir"

    # Source detected values
    eval "$(detect_locale_settings)"
    local extra_locale
    extra_locale=$(extract_extra_locale_settings)

    log "Generating local/shared.nix with detected settings..."
    log "  Username: $username"
    log "  Timezone: $DETECTED_TIMEZONE"
    log "  Locale: $DETECTED_LOCALE"
    log "  Console keymap: $DETECTED_CONSOLE_KEYMAP"
    log "  XKB layout: $DETECTED_XKB_LAYOUT"

    cat > "$shared_file" << EOF
# Shared non-secret configuration
# Auto-generated by setup.sh from /etc/nixos/configuration.nix
# Generated: $(date)
{
  # Username (shared across host and VMs)
  username = "$username";

  # Timezone
  timezone = "$DETECTED_TIMEZONE";

  # Locale settings
  locale = "$DETECTED_LOCALE";

  # Extra locale settings
  extraLocaleSettings = $extra_locale;

  # Console keymap
  consoleKeymap = "$DETECTED_CONSOLE_KEYMAP";

  # X11 keyboard
  xkbLayout = "$DETECTED_XKB_LAYOUT";
  xkbVariant = "$DETECTED_XKB_VARIANT";
}
EOF

    success "Generated: $shared_file"
}

# Generate local/host.nix with user configuration
# Simplified: just username, no password (use system password from NixOS installation)
generate_host_config() {
    local username="$1"
    local local_dir="$PROJECT_DIR/local"
    local host_file="$local_dir/host.nix"

    mkdir -p "$local_dir"

    log "Generating local/host.nix for user: $username"

    # Check if host.nix already exists
    if [[ -f "$host_file" ]]; then
        warn "local/host.nix already exists - skipping (delete to regenerate)"
        return
    fi

    cat > "$host_file" << EOF
# Host configuration - Generated by setup.sh
# Generated: $(date)
#
# This file contains ONLY the username.
# Password is your system password (set during NixOS installation).
{
  username = "$username";
}
EOF

    chmod 600 "$host_file"
    success "Generated: $host_file"
}

# Generate local/vms/ directory structure
generate_vm_secrets_structure() {
    local local_dir="$PROJECT_DIR/local"
    local vms_dir="$local_dir/vms"

    mkdir -p "$vms_dir"

    # Create empty placeholder files for each VM type
    local vm_types=("router" "pentest" "browsing" "office" "dev")

    for vm_type in "${vm_types[@]}"; do
        local vm_file="$vms_dir/${vm_type}.nix"

        if [[ -f "$vm_file" ]]; then
            log "  [skip] $vm_file (already exists)"
            continue
        fi

        cat > "$vm_file" << EOF
# ${vm_type^} VM secrets
# Auto-generated by setup.sh
# Generated: $(date)
#
# This file is ONLY accessible to ${vm_type} VMs, not the host or other VM types.
{
  # VM user password hash (can differ from host)
  # Generate with: mkpasswd -m sha-512
  hashedPassword = null;  # Will use default if null

  # Add ${vm_type}-specific secrets below
}
EOF
        log "  [+] $vm_file"
    done

    success "Generated VM secrets structure in $vms_dir"
}

# Generate local/router.nix with router VM credentials
generate_router_config() {
    local username="$1"
    local local_dir="$PROJECT_DIR/local"
    local router_file="$local_dir/router.nix"

    mkdir -p "$local_dir"

    # Always prompt for password during setup (setup is typically run once)
    if [[ -f "$router_file" ]]; then
        warn "local/router.nix exists - will be overwritten with new credentials"
    fi

    log ""
    log "========================================"
    log "  ROUTER VM CREDENTIALS"
    log "========================================"
    log ""
    log "The router VM needs a password for SSH access."
    log "This is used by: ssh ${username}@192.168.100.253"
    log ""

    # Prompt for password
    local password=""
    local password_confirm=""

    while true; do
        read -sp "Enter router VM password: " password
        echo ""

        if [[ -z "$password" ]]; then
            warn "Password cannot be empty"
            continue
        fi

        if [[ ${#password} -lt 8 ]]; then
            warn "Password must be at least 8 characters"
            continue
        fi

        read -sp "Confirm router VM password: " password_confirm
        echo ""

        if [[ "$password" != "$password_confirm" ]]; then
            warn "Passwords do not match, try again"
            continue
        fi

        break
    done

    # Generate hash
    log "Generating password hash..."
    local hashed_password
    if ! hashed_password=$(echo "$password" | mkpasswd -m sha-512 -s 2>/dev/null); then
        # Fallback if mkpasswd not available
        if command -v openssl &>/dev/null; then
            local salt=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
            hashed_password=$(openssl passwd -6 -salt "$salt" "$password")
        else
            error "Neither mkpasswd nor openssl available - cannot hash password"
        fi
    fi

    # Prompt for WiFi credentials
    local detected_ssid
    detected_ssid=$(detect_wifi_ssid)

    WIFI_SSID=""
    WIFI_PASSWORD=""
    if ! prompt_wifi_credentials "$detected_ssid"; then
        warn "Skipping WiFi configuration - you'll need to configure manually in the router VM"
    fi

    # Generate the file
    cat > "$router_file" << EOF
# Router VM credentials - Generated by setup.sh
# Generated: $(date)
#
# This file is LOCAL ONLY - never commit to version control.
# Access the router via: ssh ${username}@192.168.100.253

{
  # Router VM username (same as host user)
  username = "${username}";

  # Password hash (generated via mkpasswd -m sha-512)
  hashedPassword = "${hashed_password}";

  # WiFi credentials for automatic connection after reboot
  wifiSSID = "${WIFI_SSID}";
  wifiPassword = "${WIFI_PASSWORD}";
}
EOF

    chmod 600 "$router_file"
    success "Generated: $router_file"
    log "  Router SSH: ssh ${username}@192.168.100.253"
}

# Main function to generate all local config
generate_local_config() {
    local username="$1"

    log "Generating local configuration files..."

    generate_shared_config "$username"
    generate_host_config "$username"
    generate_router_config "$username"
    generate_vm_secrets_structure

    success "Local configuration generated in $PROJECT_DIR/local/"
    log "  - shared.nix: Username, locale, timezone, keyboard (from /etc/nixos/configuration.nix)"
    log "  - host.nix: User account"
    log "  - router.nix: Router VM credentials"
    log "  - vms/: Per-VM secrets (empty placeholders)"
}

# ========== USER DETECTION ==========

detect_current_user() {
    # Get the user who invoked the script (even if running with sudo)
    local user
    if [[ -n "${SUDO_USER:-}" ]]; then
        user="$SUDO_USER"
    else
        user="$(whoami)"
    fi

    # Validate user exists and is not root
    if [[ "$user" == "root" ]] || [[ -z "$user" ]]; then
        error "Could not detect a valid non-root user"
    fi

    echo "$user"
}

# Note: update_users_nix is no longer needed
# users.nix now reads dynamically from local/host.nix
# The generate_local_config function creates the host.nix file

# ========== PREREQUISITE CHECKS ==========

check_prerequisites() {
    log "Checking prerequisites..."

    if [[ $EUID -eq 0 ]]; then
        error "Don't run this as root"
    fi

    local missing=()
    for cmd in nix git jq sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
    fi

    # Check we're in the Hydrix directory
    if [[ ! -f "$PROJECT_DIR/flake.nix" ]]; then
        error "flake.nix not found - are you in the Hydrix directory?"
    fi

    # Check template exists
    if [[ ! -f "$TEMPLATES_DIR/machine-profile-full.nix.template" ]]; then
        error "Template not found: $TEMPLATES_DIR/machine-profile-full.nix.template"
    fi

    log "Prerequisites OK"
}

# Note: check_machine_exists() removed - flake.nix now has a single generic #host entry

# ========== HARDWARE DETECTION ==========

run_hardware_detection() {
    log "Running hardware detection..."

    cd "$PROJECT_DIR"

    if [[ -x "$SCRIPT_DIR/hardware-identify.sh" ]]; then
        if ! "$SCRIPT_DIR/hardware-identify.sh"; then
            error "Hardware detection failed"
        fi
    else
        error "hardware-identify.sh not found or not executable"
    fi

    if [[ ! -f "$PROJECT_DIR/hardware-results.env" ]]; then
        error "Hardware detection did not produce results"
    fi

    source "$PROJECT_DIR/hardware-results.env"

    if [[ ${COMPATIBILITY_SCORE:-0} -lt 5 ]]; then
        warn "Hardware compatibility score is low (${COMPATIBILITY_SCORE:-0}/10)"
        warn "Router VM passthrough may not work reliably"
    fi

    log "Hardware: $PRIMARY_INTERFACE ($PRIMARY_ID) on $PRIMARY_PCI"
    log "Driver: $PRIMARY_DRIVER"
    log "Compatibility: ${COMPATIBILITY_SCORE:-0}/10"
}

# ========== GENERATE MACHINE PROFILE FROM TEMPLATE ==========

generate_machine_profile() {
    local machine_name="$1"
    local cpu_platform="$2"
    local is_asus="$3"
    local username="$4"
    # Always output to local/machines/host.nix (generic name, hostname set inside file)
    local profile_path="$PROJECT_DIR/local/machines/host.nix"
    local template_path="$TEMPLATES_DIR/machine-profile-full.nix.template"

    log "Generating machine profile: local/machines/host.nix (hostname: ${machine_name})"

    source "$PROJECT_DIR/hardware-results.env"

    local iommu_param
    iommu_param=$(get_iommu_param "$cpu_platform")

    # Format PCI address (remove leading 0000: for virt-install)
    local pci_short="${PRIMARY_PCI#0000:}"

    mkdir -p "$PROJECT_DIR/local/machines"

    log "  Machine: $machine_name"
    log "  User: $username"
    log "  CPU Platform: $cpu_platform"
    log "  ASUS System: $is_asus"
    log "  IOMMU Param: $iommu_param"
    log "  WiFi Device: $PRIMARY_ID ($PRIMARY_PCI)"
    log "  Driver: $PRIMARY_DRIVER"

    # Build hardware module imports based on detected hardware
    # Note: paths are relative from local/machines/ to modules/
    local hw_imports=""
    if [[ "$cpu_platform" == "intel" ]]; then
        hw_imports="${hw_imports}
    # Intel hardware support (graphics, microcode, thermald)
    ../../modules/base/hardware/intel.nix"
        log "  [+] Including Intel hardware module"
    fi
    if [[ "$is_asus" == "true" ]]; then
        hw_imports="${hw_imports}
    # ASUS hardware support (asusd, battery management)
    ../../modules/base/hardware/asus.nix"
        log "  [+] Including ASUS hardware module"
    fi

    # Copy template and perform substitutions
    cp "$template_path" "$profile_path"

    # Perform all placeholder substitutions
    sed -i "s|{{MACHINE_NAME}}|${machine_name}|g" "$profile_path"
    sed -i "s|{{DATE}}|$(date)|g" "$profile_path"
    sed -i "s|{{CPU_PLATFORM}}|${cpu_platform}|g" "$profile_path"
    sed -i "s|{{IS_ASUS}}|${is_asus}|g" "$profile_path"
    sed -i "s|{{PRIMARY_ID}}|${PRIMARY_ID}|g" "$profile_path"
    sed -i "s|{{PRIMARY_PCI}}|${PRIMARY_PCI}|g" "$profile_path"
    sed -i "s|{{PRIMARY_PCI_SHORT}}|${pci_short}|g" "$profile_path"
    sed -i "s|{{PRIMARY_DRIVER}}|${PRIMARY_DRIVER}|g" "$profile_path"
    sed -i "s|{{PRIMARY_INTERFACE}}|${PRIMARY_INTERFACE}|g" "$profile_path"
    sed -i "s|{{IOMMU_PARAM}}|${iommu_param}|g" "$profile_path"
    sed -i "s|{{USER}}|${username}|g" "$profile_path"

    # Handle multi-line HW_IMPORTS substitution
    # First escape the newlines and special characters in hw_imports
    local escaped_imports
    escaped_imports=$(printf '%s\n' "$hw_imports" | sed 's/[&/\]/\\&/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    sed -i "s|{{HW_IMPORTS}}|${escaped_imports}|g" "$profile_path"

    success "Machine profile created: local/machines/host.nix"
}

# Note: update_flake() has been removed - flake.nix now has a single generic 'host' entry
# that imports ./local/machines/host.nix. No flake modification needed.

# ========== BUILD ROUTER VM ==========

build_router_vm() {
    log "Building router VM image..."

    cd "$PROJECT_DIR"

    local libvirt_image="/var/lib/libvirt/images/router.qcow2"

    # Check if router VM already exists in libvirt storage (unless force rebuild)
    if [[ "$FORCE_REBUILD" != true ]] && [[ -f "$libvirt_image" ]]; then
        local size
        size=$(sudo du -h "$libvirt_image" | cut -f1)
        log "Router VM image already exists in libvirt storage: $size"
        log "Use --force-rebuild to rebuild"
        return
    fi

    # Force rebuild - remove existing image
    if [[ "$FORCE_REBUILD" == true ]]; then
        log "Force rebuild requested - removing cached images..."
        rm -f "router-result" 2>/dev/null || true
        sudo rm -f "$libvirt_image" 2>/dev/null || true
    fi

    # Check if we have a cached build (and not forcing)
    if [[ "$FORCE_REBUILD" != true ]] && [[ -f "router-result/nixos.qcow2" ]]; then
        local size
        size=$(du -h router-result/nixos.qcow2 | cut -f1)
        log "Using cached router VM build: $size"
    else
        log "Building router VM (this may take several minutes)..."

        # Use nix-shell to ensure virtiofsd is available for nixos-generators qcow format
        if ! nix-shell -p virtiofsd --run "nix build .#router --out-link router-result"; then
            error "Router VM build failed"
        fi

        if [[ ! -f "router-result/nixos.qcow2" ]]; then
            error "Router VM build failed - no qcow2 found"
        fi

        local size
        size=$(du -h router-result/nixos.qcow2 | cut -f1)
        success "Router VM built: $size"
    fi

    # Copy to libvirt storage
    log "Installing router VM image to libvirt storage..."
    sudo mkdir -p /var/lib/libvirt/images
    sudo cp "router-result/nixos.qcow2" "$libvirt_image"
    sudo chmod 644 "$libvirt_image"

    local final_size
    final_size=$(sudo du -h "$libvirt_image" | cut -f1)
    success "Router VM installed: $libvirt_image ($final_size)"
}

# ========== GENERATE AUTOSTART SCRIPT ==========

generate_autostart_script() {
    log "Generating autostart script..."

    mkdir -p "$GENERATED_DIR/scripts"

    local script_path="$GENERATED_DIR/scripts/autostart-router.sh"

    # Note: This script is kept for backwards compatibility but the actual
    # autostart logic is now embedded in the specialisation systemd services.
    # The consolidated config generates inline scripts for each mode.

    cat > "$script_path" << 'AUTOSTARTEOF'
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
    elif $VIRSH --connect qemu:///system list --all 2>/dev/null | grep -q "router"; then
        echo "router"
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
AUTOSTARTEOF

    chmod +x "$script_path"
    success "Autostart script generated: $script_path"
}

# ========== PRE-BUILD VM CONFIGURATIONS ==========

prebuild_vm_configs() {
    log "Pre-building VM configurations (for virtiofs shared store)..."

    cd "$PROJECT_DIR"

    # VM configurations to pre-build
    # These populate the host's /nix/store so VMs can use them via virtiofs
    local vm_configs=(
        "vm-pentest"
        "vm-browsing"
        "vm-comms"
        "vm-dev"
    )

    local success_count=0
    local total=${#vm_configs[@]}

    for vm_config in "${vm_configs[@]}"; do
        log "  Building $vm_config toplevel..."
        if nix build ".#nixosConfigurations.${vm_config}.config.system.build.toplevel" --no-link 2>/dev/null; then
            log "    [+] $vm_config cached"
            ((success_count++))
        else
            warn "    [!] $vm_config failed (may not exist)"
        fi
    done

    if [[ $success_count -eq $total ]]; then
        success "All VM configurations pre-built ($success_count/$total)"
    else
        warn "Some VM configurations failed to build ($success_count/$total)"
    fi

    log ""
    log "  VMs will now rebuild quickly using virtiofs shared /nix/store"
    log "  Expected rebuild time: ~1-2 minutes (vs 15+ minutes without cache)"
}

# ========== BUILD SYSTEM ==========

build_system() {
    log "Building system configuration (boot entry only - no immediate switch)..."

    cd "$PROJECT_DIR"

    # Stage local files for nix visibility (gitignored directory)
    log "Staging local files..."
    git add -f local/host.nix local/shared.nix local/machines/host.nix local/router.nix 2>/dev/null || true

    # Use 'boot' instead of 'switch' for initial setup
    # This creates a boot entry without switching immediately, which:
    # - Preserves current network connectivity during setup
    # - Allows the setup to complete without VFIO breaking networking
    # - Requires a reboot to activate (safe transition)
    # Always build #host - machine-specific config is in local/machines/host.nix
    log "Running: nixos-rebuild boot --flake .#host"
    if sudo nixos-rebuild boot --impure --show-trace --option warn-dirty false \
        --flake "$PROJECT_DIR#host"; then
        success "System built successfully - reboot to activate"
    else
        error "System build failed"
    fi
}

# ========== GIT STAGE FILES ==========

git_stage_files() {
    log "Staging generated files in git..."

    cd "$PROJECT_DIR"

    # Stage generated scripts (committed to git)
    if [[ -f "generated/scripts/autostart-router.sh" ]]; then
        git add "generated/scripts/autostart-router.sh" 2>/dev/null && \
            log "  [+] generated/scripts/autostart-router.sh" || true
    fi

    # Stage local files with -f (gitignored but needed for nix)
    for file in local/host.nix local/shared.nix local/machines/host.nix local/router.nix; do
        if [[ -f "$file" ]]; then
            git add -f "$file" 2>/dev/null && log "  [+] $file (staged with -f)" || true
        fi
    done

    log "  [i] local/ is gitignored - staged with -f for nix visibility"
    log "  [i] flake.nix unchanged (uses generic #host entry)"

    success "Files staged in git"
}

# ========== SHOW COMPLETION SUMMARY ==========

show_completion_summary() {
    local machine_name="$1"
    local cpu_platform="$2"
    local is_asus="$3"
    local username="$4"

    echo ""
    success "========================================"
    success "  MACHINE SETUP COMPLETED!"
    success "========================================"
    echo ""
    echo "Configuration:"
    echo "  Hostname:     $machine_name (set in local/machines/host.nix)"
    echo "  User:         $username"
    echo "  CPU Platform: $cpu_platform"
    echo "  ASUS System:  $is_asus"
    echo ""
    echo "Hardware Modules Included:"
    if [[ "$cpu_platform" == "intel" ]]; then
        echo "  [+] modules/base/hardware/intel.nix (graphics, microcode, thermald)"
    fi
    if [[ "$is_asus" == "true" ]]; then
        echo "  [+] modules/base/hardware/asus.nix (asusd, battery management)"
    fi
    echo ""
    echo "Local Config (gitignored, staged with -f for nix):"
    echo "  [+] local/host.nix (username: $username)"
    echo "  [+] local/shared.nix (timezone, locale, keyboard)"
    echo "  [+] local/machines/host.nix (hostname, hardware, VFIO, specialisations)"
    echo "  [+] local/router.nix (router VM credentials)"
    echo "  [+] local/vms/*.nix (per-VM secrets placeholders)"
    echo ""
    echo "Router VM Access:"
    echo "  SSH: ssh ${username}@192.168.100.253"
    echo ""
    echo "Build Command:"
    echo "  [i] Always: ./scripts/nixbuild.sh (builds #host)"
    echo "  [i] flake.nix has ONE generic 'host' entry - no per-machine entries"
    echo ""
    echo "Router VM:"
    if [[ -f "/var/lib/libvirt/images/router.qcow2" ]]; then
        local size
        size=$(sudo du -h "/var/lib/libvirt/images/router.qcow2" | cut -f1)
        echo "  [+] Installed: /var/lib/libvirt/images/router.qcow2 ($size)"
    else
        echo "  [!] Not installed (run setup again or: nix build .#router)"
    fi
    echo "  [i] Auto-starts on first boot into router mode"
    echo ""
    echo "========================================"
    echo "  NEXT STEPS"
    echo "========================================"
    echo ""
    echo "1. Reboot into router mode:"
    echo "   sudo reboot"
    echo ""
    echo "   On reboot:"
    echo "   - System boots into router mode (default)"
    echo "   - NIC driver blacklisted for passthrough"
    echo "   - Bridges created: br-mgmt, br-pentest, br-office, br-browse, br-dev"
    echo "   - Router VM auto-starts with NIC passthrough"
    echo "   - Router provides DHCP on 192.168.100-104.x"
    echo "   - Host gets internet via router (192.168.100.253)"
    echo ""
    echo "2. After setup, rebuild with:"
    echo "   ./scripts/nixbuild.sh"
    echo ""
    echo "========================================"
    echo "  AVAILABLE MODES"
    echo "========================================"
    echo ""
    echo "    [DEFAULT] - Router mode"
    echo "      Router VM handles all networking"
    echo "      Host IP:   192.168.100.1"
    echo "      Router IP: 192.168.100.253"
    echo ""
    echo "    lockdown - Host isolation"
    echo "      Same bridges and router VM as default"
    echo "      Host firewall blocks all outbound traffic"
    echo ""
    echo "    fallback - Emergency escape hatch"
    echo "      Normal WiFi networking, no VFIO, no bridges"
    echo ""
    echo "  Switch modes:"
    echo "    ./scripts/nixbuild.sh                           # stays in current mode"
    echo ""
    echo "  Change mode (requires reboot - kernel params change):"
    echo "    sudo nixos-rebuild boot --flake .#host --impure && sudo reboot"
    echo "    sudo nixos-rebuild boot --flake .#host --specialisation lockdown --impure && sudo reboot"
    echo "    sudo nixos-rebuild boot --flake .#host --specialisation fallback --impure && sudo reboot"
    echo ""
}

# ========== ARGUMENT PARSING ==========

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Automated machine setup for Hydrix VM isolation system.

Options:
  --force-rebuild    Force rebuild of router VM even if it exists
  --skip-router      Skip router VM build (useful for testing)
  -h, --help         Show this help

This script automatically:
  1. Detects hostname, CPU platform (Intel/AMD), and current user
  2. Creates local/machines/host.nix from template (hostname set inside)
  3. Creates local/host.nix and local/shared.nix
  4. Builds and installs router VM to libvirt storage
  5. Stages local files with git add -f (needed for nix)
  6. Builds system with: nixos-rebuild boot --flake .#host

Note: flake.nix is NOT modified - it has ONE generic 'host' entry.
All machine-specific config is in local/machines/host.nix.

After running, reboot to enter router mode (default) with router VM.

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force-rebuild)
                FORCE_REBUILD=true
                shift
                ;;
            --skip-router)
                SKIP_ROUTER=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                error "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

# ========== MAIN ==========

main() {
    parse_args "$@"

    echo ""
    log "========================================"
    log "  HYDRIX MACHINE SETUP"
    log "========================================"
    echo ""

    check_prerequisites

    # Auto-detect machine info
    local machine_name
    local cpu_platform
    local is_asus
    local username

    machine_name=$(detect_hostname)
    cpu_platform=$(detect_cpu_platform)
    is_asus=$(detect_asus_system)
    username=$(detect_current_user)

    log "Detected hostname: $machine_name"
    log "Detected user: $username"
    log "Detected CPU platform: $cpu_platform ($(get_iommu_param "$cpu_platform"))"
    log "Detected ASUS system: $is_asus"
    echo ""

    # Check if local/machines/host.nix already exists
    if [[ -f "$PROJECT_DIR/local/machines/host.nix" ]]; then
        warn "local/machines/host.nix already exists"
        echo ""
        read -p "Overwrite existing configuration? [y/N]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Setup cancelled"
            exit 0
        fi
    fi

    # Run all setup steps
    run_hardware_detection
    generate_local_config "$username"
    generate_machine_profile "$machine_name" "$cpu_platform" "$is_asus" "$username"
    # Note: No flake.nix update needed - uses generic #host entry

    # Stage local/router.nix BEFORE building router VM (nix needs to see it)
    log "Staging router config for nix visibility..."
    git add -f local/router.nix 2>/dev/null || true

    if [[ "$SKIP_ROUTER" == true ]]; then
        log "Skipping router VM build (--skip-router)"
    else
        build_router_vm
    fi

    generate_autostart_script
    git_stage_files
    build_system
    prebuild_vm_configs
    show_completion_summary "$machine_name" "$cpu_platform" "$is_asus" "$username"
}

main "$@"
