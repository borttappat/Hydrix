#!/usr/bin/env bash
# setup-hydrix.sh - Migrate existing NixOS to Hydrix
#
# This script sets up Hydrix on an existing NixOS installation.
# It generates a config directory that imports Hydrix from GitHub.
#
# Features:
# - Multi-machine support: add new machines to existing config
# - Clone existing repo: bring your config from another system
# - Legacy migration: auto-upgrade old machine.nix format
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/setup-hydrix.sh | bash
#
# Or:
#   nix run git+https://github.com/borttappat/Hydrix.git#setup

set -euo pipefail

# When piped via curl | bash, stdin is the script — redirect reads to the terminal
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    read() { builtin read "$@" < /dev/tty; }
fi

# Source common library for validation functions
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR_LIB=""
fi
if [[ -n "$SCRIPT_DIR_LIB" ]] && [[ -f "$SCRIPT_DIR_LIB/lib/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "$SCRIPT_DIR_LIB/lib/common.sh"
else
    # When running from curl, download common.sh
    COMMON_URL="https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/lib/common.sh"
    COMMON_TEMP=$(mktemp)
    if curl -sL "$COMMON_URL" -o "$COMMON_TEMP" 2>/dev/null; then
        # shellcheck source=/dev/null
        source "$COMMON_TEMP"
        rm -f "$COMMON_TEMP"
    fi
fi

# ========== CONFIGURATION ==========

HYDRIX_REPO="git+https://github.com/borttappat/Hydrix.git"
CONFIG_DIR="${HYDRIX_CONFIG_DIR:-$HOME/hydrix-config}"
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=""
fi

# Mode: "fresh" | "add" | "use-existing"
MODE=""

# Collected configuration
declare -A CONFIG=(
    [username]=""
    [hostname]=""
    [serial]=""
    [timezone]=""
    [locale]=""
    [consoleKeymap]=""
    [xkbLayout]=""
    [xkbVariant]=""
    [platform]=""
    [isAsus]="false"
    [wifiPciAddress]=""
    [wifiPciId]=""
    [wifiSsid]=""
    [wifiPassword]=""
    [routerType]="microvm"
    [colorscheme]="puccy"
    [diskoDevice]=""
    [hardwareConfigPath]=""
    [hydrixSource]="github"
    [hydrixUrl]="git+https://github.com/borttappat/Hydrix.git"
    [hydrixLocalPath]=""
)

# ========== SECURE CLEANUP ==========
# Ensure sensitive data is cleared on exit (normal or error)

secure_cleanup() {
    # Clear sensitive variables from memory
    unset token pass pass1 pass2 password password_confirm key_content
    unset WIFI_PASSWORD

    # Clear SSH command override
    unset GIT_SSH_COMMAND
}

# Register cleanup handler for all exit paths
trap secure_cleanup EXIT

# ========== UTILITY FUNCTIONS ==========

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }
warn() { echo "[WARN] $*"; }

command_exists() { command -v "$1" &>/dev/null; }

# ========== GIT AUTHENTICATION ==========

is_auth_error() {
    local output="$1"
    # Check for common authentication error patterns
    if echo "$output" | grep -qiE "authentication failed|403|401|permission denied|could not read username|terminal prompts disabled|Authentication required"; then
        return 0
    fi
    return 1
}

prompt_auth_method() {
    echo ""
    warn "Authentication required for private repository"
    echo ""
    echo "Options:"
    if command_exists gh; then
        echo "  1) GitHub CLI (gh auth login) - recommended"
    else
        echo "  1) GitHub CLI - not available (install with: nix-shell -p gh)"
    fi
    echo "  2) Personal Access Token (HTTPS)"
    echo "  3) SSH key"
    echo "  4) Cancel"
    echo ""
    read -p "Select authentication method [1-4]: " auth_choice
    echo "$auth_choice"
}

authenticate_gh_cli() {
    if ! command_exists gh; then
        warn "GitHub CLI not available"
        echo ""
        log "Installing gh temporarily..."
        if nix-shell -p gh --run "gh auth login"; then
            return 0
        fi
        return 1
    fi

    log "Authenticating with GitHub CLI..."
    if gh auth login; then
        return 0
    fi
    return 1
}

convert_to_token_url() {
    local url="$1"
    local token="$2"

    # Convert various URL formats to HTTPS with token
    local clean_url="$url"

    # Handle SSH format
    if [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
        clean_url="https://github.com/${BASH_REMATCH[1]}"
    fi

    # Handle plain github.com/user/repo
    if [[ "$url" =~ ^github\.com/(.+)$ ]]; then
        clean_url="https://github.com/${BASH_REMATCH[1]}"
    fi

    # Strip existing https:// prefix
    clean_url="${clean_url#https://}"
    clean_url="${clean_url#http://}"

    # Ensure .git suffix
    [[ "$clean_url" != *.git ]] && clean_url="${clean_url}.git"

    echo "https://${token}@${clean_url}"
}

convert_to_ssh_url() {
    local url="$1"

    # Convert to SSH format: git@github.com:user/repo.git
    local clean_url="$url"

    # Already SSH format
    if [[ "$url" =~ ^git@github\.com: ]]; then
        echo "$url"
        return
    fi

    # Strip protocols
    clean_url="${clean_url#https://}"
    clean_url="${clean_url#http://}"
    clean_url="${clean_url#github.com/}"

    # Ensure .git suffix
    [[ "$clean_url" != *.git ]] && clean_url="${clean_url}.git"

    echo "git@github.com:${clean_url}"
}

setup_ssh_key() {
    echo ""
    log "SSH Key Authentication"
    echo ""
    echo "Options:"
    echo "  1) Use existing SSH key (~/.ssh/id_*)"
    echo "  2) Specify path to key"
    echo ""
    read -p "Select [1-2]: " ssh_choice

    case "$ssh_choice" in
        1)
            # Check for existing keys
            if [[ -f ~/.ssh/id_ed25519 ]]; then
                export GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no"
                success "Using existing SSH key: ~/.ssh/id_ed25519"
                return 0
            elif [[ -f ~/.ssh/id_rsa ]]; then
                export GIT_SSH_COMMAND="ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no"
                success "Using existing SSH key: ~/.ssh/id_rsa"
                return 0
            else
                warn "No SSH keys found in ~/.ssh/"
                return 1
            fi
            ;;
        2)
            read -p "Path to SSH private key: " key_path
            if [[ -f "$key_path" ]]; then
                export GIT_SSH_COMMAND="ssh -i $key_path -o StrictHostKeyChecking=no"
                success "SSH key configured: $key_path"
                return 0
            else
                warn "Key file not found: $key_path"
                return 1
            fi
            ;;
    esac
    return 1
}

try_clone_with_auth() {
    local repo_url="$1"
    local dest_dir="$2"
    local clone_output
    local clone_exit

    # First attempt - try without extra auth
    log "Attempting to clone..."
    clone_output=$(git clone "$repo_url" "$dest_dir" 2>&1) && return 0
    clone_exit=$?

    # Check if it's an auth error
    if ! is_auth_error "$clone_output"; then
        echo "$clone_output"
        return $clone_exit
    fi

    # Auth error - prompt for authentication method
    local auth_method
    auth_method=$(prompt_auth_method)

    case "$auth_method" in
        1)
            # GitHub CLI
            if authenticate_gh_cli; then
                log "Retrying clone with gh auth..."
                if git clone "$repo_url" "$dest_dir" 2>&1; then
                    return 0
                fi
            fi
            warn "GitHub CLI authentication failed"
            return 1
            ;;
        2)
            # Personal Access Token
            echo ""
            echo "Generate a token at: https://github.com/settings/tokens"
            echo "Required scope: repo (for private repos)"
            echo ""
            read -s -p "Enter Personal Access Token: " token
            echo ""

            if [[ -z "$token" ]]; then
                warn "No token provided"
                return 1
            fi

            local token_url
            token_url=$(convert_to_token_url "$repo_url" "$token")
            # Clear token from memory immediately after constructing URL
            unset token
            log "Retrying clone with token..."
            if git clone "$token_url" "$dest_dir" 2>&1; then
                unset token_url  # Clear URL containing token
                return 0
            fi
            unset token_url  # Clear URL containing token
            warn "Token authentication failed"
            return 1
            ;;
        3)
            # SSH key
            if setup_ssh_key; then
                local ssh_url
                ssh_url=$(convert_to_ssh_url "$repo_url")
                log "Retrying clone with SSH..."
                if git clone "$ssh_url" "$dest_dir" 2>&1; then
                    return 0
                fi
            fi
            warn "SSH authentication failed"
            return 1
            ;;
        4|*)
            # Cancel
            return 1
            ;;
    esac
}

# ========== MULTI-MACHINE SUPPORT ==========

list_existing_machines() {
    log "Existing machines in config:"
    shopt -s nullglob
    for f in "$CONFIG_DIR/machines/"*.nix; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" .nix)
        echo "  - $name"
    done
    shopt -u nullglob
}

prompt_existing_repo() {
    echo ""
    log "Existing hydrix-config detected at: $CONFIG_DIR"
    list_existing_machines
    echo ""
    echo "Options:"
    echo "  1) Add this machine (${CONFIG[serial]}) to existing config"
    echo "  2) Clone a different existing repo"
    echo "  3) Start fresh (backup existing)"
    echo ""
    read -p "Select [1-3, default=1]: " choice

    case "${choice:-1}" in
        1) MODE="add" ;;
        2)
            clone_existing_repo
            ;;
        3)
            backup_and_fresh
            ;;
        *)
            MODE="add"
            ;;
    esac
}

clone_existing_repo() {
    echo ""

    while true; do
        read -p "Git URL of your existing hydrix-config: " repo_url

        if [[ -z "$repo_url" ]]; then
            error "No URL provided"
        fi

        # Validate URL format to prevent injection
        if type check_flake_url &>/dev/null && ! check_flake_url "$repo_url"; then
            # Also allow git@ SSH URLs which check_flake_url doesn't handle
            if [[ ! "$repo_url" =~ ^git@[a-zA-Z0-9._-]+:[a-zA-Z0-9._/-]+$ ]]; then
                warn "Try: https://github.com/user/repo or git@github.com:user/repo.git"
                continue
            fi
        fi
        break
    done

    local temp_dir
    temp_dir=$(mktemp -d)

    # Try clone with authentication handling
    if ! try_clone_with_auth "$repo_url" "$temp_dir/hydrix-config"; then
        rm -rf "$temp_dir"
        error "Failed to clone repository"
    fi

    # Validate structure
    if [[ ! -d "$temp_dir/hydrix-config/machines" ]]; then
        rm -rf "$temp_dir"
        error "Invalid hydrix-config: missing machines/ directory"
    fi

    # Backup existing if present
    if [[ -d "$CONFIG_DIR" ]]; then
        local backup_dir="${CONFIG_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
        log "Backing up existing config to: $backup_dir"
        mv "$CONFIG_DIR" "$backup_dir"
    fi

    # Move to config location
    mv "$temp_dir/hydrix-config" "$CONFIG_DIR"
    rm -rf "$temp_dir"

    success "Cloned existing configuration"
    list_existing_machines

    # Check if machine already exists in cloned config
    if [[ -f "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" ]]; then
        log "Machine '${CONFIG[serial]}' already exists in cloned config"
        echo ""
        echo "Options:"
        echo "  1) Use existing machine config (update hardware detection only)"
        echo "  2) Regenerate with current system detection (overwrites customizations)"
        echo "  3) Cancel"
        echo ""
        read -p "Select [1-3, default=1]: " existing_choice

        case "${existing_choice:-1}" in
            1)
                MODE="use-existing"
                log "Will use existing config, regenerate hardware detection"
                ;;
            2)
                MODE="add"
                warn "Existing machine config will be overwritten"
                ;;
            3)
                error "Cancelled by user"
                ;;
            *)
                MODE="use-existing"
                log "Will use existing config, regenerate hardware detection"
                ;;
        esac
    else
        MODE="add"
    fi
}

backup_and_fresh() {
    local backup_dir="${CONFIG_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
    log "Backing up to: $backup_dir"
    mv "$CONFIG_DIR" "$backup_dir"
    MODE="fresh"
}

migrate_legacy_config() {
    log "Detected legacy config format (machine.nix at root)"
    log "Migrating to multi-machine format..."

    # Extract hostname from existing machine.nix
    local legacy_hostname
    legacy_hostname=$(grep -oP 'hostname\s*=\s*"\K[^"]+' "$CONFIG_DIR/machine.nix" 2>/dev/null || echo "unknown")

    if [[ "$legacy_hostname" == "unknown" ]]; then
        # Try alternative patterns
        legacy_hostname=$(grep -oP 'hydrix\.hostname\s*=\s*"\K[^"]+' "$CONFIG_DIR/machine.nix" 2>/dev/null || echo "legacy-host")
    fi

    log "  Found hostname: $legacy_hostname"

    # Create new structure
    mkdir -p "$CONFIG_DIR/machines"
    mv "$CONFIG_DIR/machine.nix" "$CONFIG_DIR/machines/${legacy_hostname}.nix"

    # Check if we need to generate other directories
    local needs_specialisations=false
    local needs_profiles=false

    if [[ ! -d "$CONFIG_DIR/specialisations" ]]; then
        needs_specialisations=true
    fi

    if [[ ! -d "$CONFIG_DIR/profiles" ]]; then
        needs_profiles=true
    fi

    # Copy template structure for missing parts
    if $needs_specialisations; then
        copy_template_specialisations
    fi

    if $needs_profiles; then
        copy_template_profiles
    fi

    # Ensure modules, colorschemes, templates, configs directories exist
    [[ ! -d "$CONFIG_DIR/modules" ]]    && copy_template_modules
    [[ ! -d "$CONFIG_DIR/templates" ]]  && copy_template_templates
    [[ ! -d "$CONFIG_DIR/colorschemes" ]] && create_colorschemes_dir
    [[ ! -d "$CONFIG_DIR/configs" ]]    && copy_template_configs

    # Update flake.nix to use auto-discovery
    generate_flake_nix

    # Commit migration
    (
        cd "$CONFIG_DIR"
        git add .
        git commit -m "Migrate to multi-machine format: machine.nix -> machines/${legacy_hostname}.nix" 2>/dev/null || true
    )

    success "Migration complete: machine.nix -> machines/${legacy_hostname}.nix"

    # Check if current machine is different from migrated one
    if [[ "${CONFIG[serial]}" != "$legacy_hostname" ]]; then
        echo ""
        log "Current serial (${CONFIG[serial]}) differs from migrated config ($legacy_hostname)"
        read -p "Add current machine as new config? [Y/n]: " add_current
        if [[ ! "$add_current" =~ ^[Nn]$ ]]; then
            MODE="add"
        else
            MODE=""  # Done, don't add
        fi
    else
        MODE=""  # Migration only, same machine
        log "Current machine already in config"
    fi
}

prompt_clone_or_fresh() {
    echo ""
    log "Directory exists but is not a valid hydrix-config: $CONFIG_DIR"
    echo ""
    echo "Options:"
    echo "  1) Clone an existing repo"
    echo "  2) Start fresh (backup existing)"
    echo ""
    read -p "Select [1-2, default=2]: " choice

    case "${choice:-2}" in
        1) clone_existing_repo ;;
        2) backup_and_fresh ;;
        *) backup_and_fresh ;;
    esac
}

# ========== HARDWARE VALIDATION ==========

validate_existing_config() {
    local config_file="$1"
    local warnings=0

    log "Validating existing config against detected hardware..."

    # Extract values from existing config
    local existing_platform=$(grep -oP 'platform\s*=\s*"\K[^"]+' "$config_file" 2>/dev/null || echo "")
    local existing_pci=$(grep -oP 'wifiPciAddress\s*=\s*"\K[^"]+' "$config_file" 2>/dev/null || echo "")
    local existing_isAsus=$(grep -oP 'isAsus\s*=\s*\K(true|false)' "$config_file" 2>/dev/null || echo "")

    # Compare with detected
    if [[ -n "$existing_platform" && "$existing_platform" != "${CONFIG[platform]}" ]]; then
        warn "  Platform mismatch: config='$existing_platform', detected='${CONFIG[platform]}'"
        ((warnings++))
    fi

    if [[ -n "$existing_pci" && "$existing_pci" != "${CONFIG[wifiPciAddress]}" ]]; then
        warn "  WiFi PCI address mismatch: config='$existing_pci', detected='${CONFIG[wifiPciAddress]}'"
        warn "    This may cause WiFi passthrough to fail!"
        ((warnings++))
    fi

    if [[ -n "$existing_isAsus" && "$existing_isAsus" != "${CONFIG[isAsus]}" ]]; then
        warn "  ASUS detection mismatch: config='$existing_isAsus', detected='${CONFIG[isAsus]}'"
        ((warnings++))
    fi

    if [[ $warnings -gt 0 ]]; then
        echo ""
        warn "Found $warnings hardware mismatch(es). The existing config may not work correctly."
        read -p "Continue anyway? [y/N]: " cont
        [[ "$cont" =~ ^[Yy]$ ]] || error "Cancelled due to hardware mismatches"
    else
        log "  Hardware validation passed"
    fi
}

regenerate_hardware_config() {
    local hw_file="$CONFIG_DIR/machines/${CONFIG[serial]}-hardware.nix"

    log "Regenerating hardware configuration..."

    if sudo nixos-generate-config --show-hardware-config > "$hw_file" 2>/dev/null; then
        log "  Generated: $hw_file"
    else
        warn "  Failed to generate hardware config"
        warn "  You may need to run: sudo nixos-generate-config --show-hardware-config"
        return
    fi

    # Boot loader is handled by the Hydrix framework (GRUB defaults for non-disko installs)
    # No need to extract from /etc/nixos/configuration.nix
}

# ========== SYSTEM DETECTION ==========

detect_current_config() {
    log "Detecting current NixOS configuration..."

    # Username
    CONFIG[username]="${USER:-$(whoami)}"
    log "  Username: ${CONFIG[username]}"

    # Hardware serial (for config file naming)
    local serial
    serial=$(detect_serial) || true
    if [[ "$serial" == "unknown-machine" ]]; then
        warn "  Could not detect hardware serial"
        serial=$(generate_fallback_id)
        warn "  Using fallback identifier: $serial"
    else
        log "  Hardware serial: $serial"
    fi
    CONFIG[serial]="$serial"

    # Visual hostname is always "hydrix"
    CONFIG[hostname]="hydrix"
    log "  Hostname: ${CONFIG[hostname]} (visual)"

    # Timezone
    if [[ -L /etc/localtime ]]; then
        local tz_path
        tz_path=$(readlink /etc/localtime)
        CONFIG[timezone]="${tz_path#*/zoneinfo/}"
    else
        CONFIG[timezone]="UTC"
    fi
    log "  Timezone: ${CONFIG[timezone]}"

    # Locale
    CONFIG[locale]="${LANG:-en_US.UTF-8}"
    log "  Locale: ${CONFIG[locale]}"

    # Keyboard layout from X11
    if command -v setxkbmap &>/dev/null; then
        local xkb_info
        xkb_info=$(setxkbmap -query 2>/dev/null || echo "")
        CONFIG[xkbLayout]=$(echo "$xkb_info" | grep "layout:" | awk '{print $2}' || echo "us")
        CONFIG[xkbVariant]=$(echo "$xkb_info" | grep "variant:" | awk '{print $2}' || echo "")
    else
        CONFIG[xkbLayout]="us"
        CONFIG[xkbVariant]=""
    fi
    log "  XKB Layout: ${CONFIG[xkbLayout]}"

    # Console keymap
    CONFIG[consoleKeymap]=$(cat /etc/vconsole.conf 2>/dev/null | grep KEYMAP | cut -d= -f2 || echo "us")
    log "  Console keymap: ${CONFIG[consoleKeymap]}"

    # CPU platform
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        CONFIG[platform]="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        CONFIG[platform]="amd"
    else
        CONFIG[platform]="generic"
    fi
    log "  Platform: ${CONFIG[platform]}"

    # ASUS detection
    if [[ -d /sys/module/asus_wmi ]] || grep -qi "asus" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        CONFIG[isAsus]="true"
        log "  ASUS: yes"
    else
        CONFIG[isAsus]="false"
    fi

    # Root disk (for reference, not used by disko in setup)
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / | sed 's/\[.*\]//' | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')
    CONFIG[diskoDevice]="$root_dev"
    log "  Root disk: ${CONFIG[diskoDevice]}"
}

detect_hardware_config() {
    log "Checking for hardware-configuration.nix..."

    CONFIG[hardwareConfigPath]=""

    # Check standard location
    if [[ -f /etc/nixos/hardware-configuration.nix ]]; then
        CONFIG[hardwareConfigPath]="/etc/nixos/hardware-configuration.nix"
        log "  Found: /etc/nixos/hardware-configuration.nix"
    # Check for alternative locations
    elif [[ -f "/etc/nixos/hosts/$(hostname)/hardware-configuration.nix" ]]; then
        CONFIG[hardwareConfigPath]="/etc/nixos/hosts/$(hostname)/hardware-configuration.nix"
        log "  Found: ${CONFIG[hardwareConfigPath]}"
    fi

    if [[ -z "${CONFIG[hardwareConfigPath]}" ]]; then
        warn "  No hardware-configuration.nix found!"
        echo ""
        echo "  The hardware-configuration.nix file contains critical settings:"
        echo "    - Filesystem mounts (/, /boot, swap)"
        echo "    - Kernel modules for your hardware"
        echo "    - Boot configuration"
        echo ""
        echo "  Without it, your system won't boot after switching to Hydrix."
        echo ""
        read -p "  Generate hardware-configuration.nix now? [Y/n]: " gen_hw
        if [[ ! "$gen_hw" =~ ^[Nn]$ ]]; then
            log "  Generating hardware configuration..."
            if sudo nixos-generate-config --dir /tmp/hw-gen 2>/dev/null; then
                CONFIG[hardwareConfigPath]="/tmp/hw-gen/hardware-configuration.nix"
                success "  Generated: ${CONFIG[hardwareConfigPath]}"
            else
                error "Failed to generate hardware-configuration.nix. Please run manually:\n  sudo nixos-generate-config"
            fi
        else
            warn "  Continuing without hardware-configuration.nix - system may not boot!"
        fi
    fi
}

copy_hardware_config() {
    if [[ -n "${CONFIG[hardwareConfigPath]}" ]]; then
        local dest="$CONFIG_DIR/machines/${CONFIG[serial]}-hardware.nix"
        log "Copying hardware configuration..."
        cp "${CONFIG[hardwareConfigPath]}" "$dest"
        log "  Copied to: $dest"
    fi
}

detect_wifi_hardware() {
    log "Detecting WiFi hardware..."

    local pci_addr=""
    local pci_id=""

    # Find WiFi interface
    for iface in /sys/class/net/wl*; do
        [[ -e "$iface" ]] || continue

        if [[ -e "$iface/device" ]]; then
            local pci_path
            pci_path=$(readlink -f "$iface/device" 2>/dev/null || echo "")
            pci_addr=$(basename "$pci_path" 2>/dev/null || echo "")

            if [[ -n "$pci_addr" ]] && [[ "$pci_addr" != "device" ]]; then
                pci_id=$(lspci -nn -s "$pci_addr" 2>/dev/null | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1 || echo "")
                log "  Found: $pci_addr (ID: $pci_id)"
                break
            fi
        fi
    done

    # Fallback: scan PCI
    if [[ -z "$pci_addr" ]]; then
        local wifi_pci
        wifi_pci=$(lspci -nn | grep -iE "wireless|wi-fi|802\.11" | head -1 || true)

        if [[ -n "$wifi_pci" ]]; then
            pci_addr=$(echo "$wifi_pci" | awk '{print $1}')
            pci_id=$(echo "$wifi_pci" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1 || echo "")
        fi
    fi

    if [[ -n "$pci_addr" ]]; then
        CONFIG[wifiPciAddress]="${pci_addr#0000:}"
        CONFIG[wifiPciId]="$pci_id"
        success "WiFi: ${CONFIG[wifiPciAddress]} (${CONFIG[wifiPciId]})"
    else
        CONFIG[wifiPciAddress]="00:14.3"
        CONFIG[wifiPciId]="8086:0000"
        warn "WiFi hardware not detected - using placeholder"
    fi
}

detect_wifi_credentials() {
    log "Detecting WiFi credentials..."

    # Try nmcli
    local wifi_show
    wifi_show=$(nmcli dev wifi show 2>/dev/null || echo "")

    if [[ -n "$wifi_show" ]]; then
        CONFIG[wifiSsid]=$(echo "$wifi_show" | grep -E "^SSID:" | sed 's/^SSID:[[:space:]]*//')
        CONFIG[wifiPassword]=$(echo "$wifi_show" | grep -E "^Password:" | sed 's/^Password:[[:space:]]*//')

        if [[ -n "${CONFIG[wifiSsid]}" ]]; then
            log "  Detected: ${CONFIG[wifiSsid]}"
        fi
    fi
}

# ========== TEMPLATE COPYING ==========

copy_template_specialisations() {
    log "Creating specialisations from template..."

    mkdir -p "$CONFIG_DIR/specialisations"

    local template_dir=""

    if [[ -d "$HOME/Hydrix/templates/user-config/specialisations" ]]; then
        template_dir="$HOME/Hydrix/templates/user-config/specialisations"
    elif [[ -d "$SCRIPT_DIR/../templates/user-config/specialisations" ]]; then
        template_dir="$SCRIPT_DIR/../templates/user-config/specialisations"
    fi

    cp -r "$template_dir"/* "$CONFIG_DIR/specialisations/"
    log "  Copied from template"
}

copy_template_profiles() {
    log "Creating profiles from template..."

    mkdir -p "$CONFIG_DIR/profiles"

    local template_dir=""

    if [[ -d "$HOME/Hydrix/templates/user-config/profiles" ]]; then
        template_dir="$HOME/Hydrix/templates/user-config/profiles"
    elif [[ -d "$SCRIPT_DIR/../templates/user-config/profiles" ]]; then
        template_dir="$SCRIPT_DIR/../templates/user-config/profiles"
    fi

    cp -r "$template_dir"/* "$CONFIG_DIR/profiles/"
    log "  Copied from template"
}

copy_template_shared() {
    log "Creating shared config from template..."

    mkdir -p "$CONFIG_DIR/shared"

    local template_dir=""

    if [[ -d "$HOME/Hydrix/templates/user-config/shared" ]]; then
        template_dir="$HOME/Hydrix/templates/user-config/shared"
    elif [[ -d "$SCRIPT_DIR/../templates/user-config/shared" ]]; then
        template_dir="$SCRIPT_DIR/../templates/user-config/shared"
    fi

    cp -r "$template_dir"/* "$CONFIG_DIR/shared/"
    log "  Copied from template"
}

substitute_shared_locale() {
    local common="$CONFIG_DIR/shared/common.nix"

    # Skip if placeholders are already gone (existing repo has real values)
    if ! grep -q "@TIMEZONE@" "$common" 2>/dev/null; then
        log "  shared/common.nix already configured, skipping locale substitution"
        return
    fi

    log "  Substituting locale placeholders in shared/common.nix..."
    sed -i \
        -e "s|@TIMEZONE@|${CONFIG[timezone]}|g" \
        -e "s|@LOCALE@|${CONFIG[locale]}|g" \
        -e "s|@CONSOLE_KEYMAP@|${CONFIG[consoleKeymap]}|g" \
        -e "s|@XKB_LAYOUT@|${CONFIG[xkbLayout]}|g" \
        -e "s|@XKB_VARIANT@|${CONFIG[xkbVariant]}|g" \
        "$common"
    log "  Locale: tz=${CONFIG[timezone]} lang=${CONFIG[locale]} kb=${CONFIG[xkbLayout]}"
}

copy_template_modules() {
    log "Creating modules from template..."

    mkdir -p "$CONFIG_DIR/modules"

    local template_dir=""

    if [[ -d "$HOME/Hydrix/templates/user-config/modules" ]]; then
        template_dir="$HOME/Hydrix/templates/user-config/modules"
    elif [[ -d "$SCRIPT_DIR/../templates/user-config/modules" ]]; then
        template_dir="$SCRIPT_DIR/../templates/user-config/modules"
    fi

    cp -r "$template_dir"/* "$CONFIG_DIR/modules/"
    log "  Copied from template"
}

copy_template_templates() {
    log "Creating templates from template..."

    mkdir -p "$CONFIG_DIR/templates"

    local template_dir=""

    if [[ -d "$HOME/Hydrix/templates/user-config/templates" ]]; then
        template_dir="$HOME/Hydrix/templates/user-config/templates"
    elif [[ -d "$SCRIPT_DIR/../templates/user-config/templates" ]]; then
        template_dir="$SCRIPT_DIR/../templates/user-config/templates"
    fi

    cp -r "$template_dir"/* "$CONFIG_DIR/templates/"
    log "  Copied from template (new-profile reads these)"
}

copy_template_configs() {
    log "Creating configs directory..."
    mkdir -p "$CONFIG_DIR/configs"

    local template_dir=""
    if [[ -d "$HOME/Hydrix/templates/user-config/configs" ]]; then
        template_dir="$HOME/Hydrix/templates/user-config/configs"
    elif [[ -d "$SCRIPT_DIR/../templates/user-config/configs" ]]; then
        template_dir="$SCRIPT_DIR/../templates/user-config/configs"
    fi

    cp -r "$template_dir"/. "$CONFIG_DIR/configs/"
    log "  Copied program configs from template"
}

create_colorschemes_dir() {
    log "Creating colorschemes directory..."
    mkdir -p "$CONFIG_DIR/colorschemes"
    log "  Created $CONFIG_DIR/colorschemes/ (add custom .json colorschemes here)"
}

copy_wallpapers() {
    log "Setting up wallpapers..."
    local home_dir="$HOME"
    mkdir -p "$home_dir/wallpapers"
    # Copy wallpapers from Hydrix repo (local clone or framework)
    local hydrix_wp=""
    if [[ -d "$HOME/Hydrix/wallpapers" ]]; then
        hydrix_wp="$HOME/Hydrix/wallpapers"
    elif [[ -d "$(dirname "$0")/../wallpapers" ]]; then
        hydrix_wp="$(cd "$(dirname "$0")/.." && pwd)/wallpapers"
    fi
    if [[ -n "$hydrix_wp" ]] && ls "$hydrix_wp"/*.{png,jpg} &>/dev/null; then
        cp "$hydrix_wp"/*.png "$hydrix_wp"/*.jpg "$home_dir/wallpapers/" 2>/dev/null || true
        local count
        count=$(ls "$home_dir/wallpapers/" 2>/dev/null | wc -l)
        log "  Copied $count wallpaper(s) from Hydrix"
    else
        log "  Created $home_dir/wallpapers/ (add wallpapers here)"
    fi
}

copy_template_secrets() {
    log "Creating secrets scaffold..."

    local template_dir=""
    if [[ -d "$HOME/Hydrix/templates/user-config" ]]; then
        template_dir="$HOME/Hydrix/templates/user-config"
    elif [[ -d "$SCRIPT_DIR/../templates/user-config" ]]; then
        template_dir="$SCRIPT_DIR/../templates/user-config"
    fi

    mkdir -p "$CONFIG_DIR/secrets"
    [[ -f "$template_dir/secrets/.sops.yaml" ]] && \
        cp "$template_dir/secrets/.sops.yaml" "$CONFIG_DIR/secrets/.sops.yaml"
    [[ -f "$template_dir/secrets/github.yaml.example" ]] && \
        cp "$template_dir/secrets/github.yaml.example" "$CONFIG_DIR/secrets/github.yaml.example"
    [[ -f "$template_dir/.gitignore" ]] && \
        cp "$template_dir/.gitignore" "$CONFIG_DIR/.gitignore"
    log "  secrets/ scaffold created (see secrets/.sops.yaml for setup instructions)"
}

copy_template_readme() {
    local template_dir=""

    if [[ -d "$HOME/Hydrix/templates/user-config" ]]; then
        template_dir="$HOME/Hydrix/templates/user-config"
    elif [[ -d "$SCRIPT_DIR/../templates/user-config" ]]; then
        template_dir="$SCRIPT_DIR/../templates/user-config"
    fi

    if [[ -f "$template_dir/README.md" ]]; then
        cp "$template_dir/README.md" "$CONFIG_DIR/README.md"
        log "  Copied README.md from template"
    fi
}

# ========== CONFIG GENERATION ==========

generate_flake_nix() {
    log "Generating flake.nix from template..."

    # Find the template file (same search order as other copy_template_* functions)
    local template_file=""
    if [[ -f "$HOME/Hydrix/templates/user-config/flake.nix" ]]; then
        template_file="$HOME/Hydrix/templates/user-config/flake.nix"
    elif [[ -f "$SCRIPT_DIR/../templates/user-config/flake.nix" ]]; then
        template_file="$SCRIPT_DIR/../templates/user-config/flake.nix"
    else
        die "Could not find flake.nix template in Hydrix installation"
    fi

    # Substitute placeholders: use | as delimiter to avoid clashing with / in URLs
    sed \
        -e "s|@HYDRIX_URL@|${CONFIG[hydrixUrl]}|g" \
        -e "s|@USERNAME@|${CONFIG[username]}|g" \
        "$template_file" > "$CONFIG_DIR/flake.nix"

    log "  Created: $CONFIG_DIR/flake.nix"
}

generate_machine_nix() {
    local gen_date
    gen_date=$(date +"%Y-%m-%d %H:%M")

    mkdir -p "$CONFIG_DIR/machines"

    # Config file named by hardware serial for automatic reinstall detection
    cat > "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << MACHINE_EOF
# Machine Configuration
# Serial: ${CONFIG[serial]}
# Generated by setup-hydrix.sh on ${gen_date}
#
# Config file is named by hardware serial for automatic reinstall detection.
# The visual hostname is always "hydrix".
#
# This file contains ALL available hydrix.* options.
# Lines marked with "# DETECTED:" were auto-detected from your system.
# Lines marked with "# DEFAULT:" show the framework default value.
# Uncomment and modify any option to customize your system.
#
# BOOT MODES:
#   DEFAULT (Lockdown):  No host internet, minimal packages, hardened
#   Administrative:      Full functionality, router VM, all packages
#   Fallback:            Emergency direct WiFi, no VMs
#
# Switch modes (rebuild auto-detects this machine by hardware serial):
#   rebuild                    -> Lockdown (default)
#   rebuild administrative     -> Admin mode
#   rebuild fallback           -> Fallback mode

{ config, lib, pkgs, hydrix, ... }:

{
  # =========================================================================
  # SPECIALISATIONS (Boot Modes)
  # =========================================================================
  imports = [
MACHINE_EOF

    # Add hardware import if detected
    if [[ -n "${CONFIG[hardwareConfigPath]}" ]]; then
        echo "    ./${CONFIG[serial]}-hardware.nix" >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix"
    fi

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << 'MACHINE_EOF'
    ../specialisations/lockdown.nix
  ];

  specialisation.administrative.configuration = {
    imports = [ ../specialisations/administrative.nix ];
  };

  specialisation.fallback.configuration = {
    imports = [ ../specialisations/fallback.nix ];
  };

  # =========================================================================
  # USER CREDENTIALS (NixOS native - outside hydrix.*)
  # =========================================================================
  # Generate password hash with: mkpasswd -m sha-512
MACHINE_EOF

    # Add user password line with actual username
    echo "  # users.users.${CONFIG[username]}.hashedPassword = \"\\\$6\\\$...\";  # Recommended" >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix"

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << 'MACHINE_EOF'

  # =========================================================================
  # HYDRIX CONFIGURATION - All Available Options
  # =========================================================================
  hydrix = {

    # -----------------------------------------------------------------------
    # IDENTITY (Required)
    # -----------------------------------------------------------------------
MACHINE_EOF

    # Add detected identity values
    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << MACHINE_EOF
    username = "${CONFIG[username]}";           # DETECTED from system
    hostname = "hydrix";  # Visual hostname (config file identified by serial: ${CONFIG[serial]})
    colorscheme = "${CONFIG[colorscheme]}";     # DEFAULT: "puccy"
    graphical.wallpaper = "\${hydrix}/wallpapers/WindowRain.png";
MACHINE_EOF

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << 'MACHINE_EOF'

    # vmType = null;  # DEFAULT: null (auto-detected, don't set for hosts)

    # -----------------------------------------------------------------------
    # USER OPTIONS
    # -----------------------------------------------------------------------
    # user = {
    #   hashedPassword = null;        # DEFAULT: null - Use mkpasswd -m sha-512
    #   description = "";             # DEFAULT: same as username
    #   sshPublicKeys = [];           # DEFAULT: [] - Add "ssh-rsa AAAA..." strings
    #   extraGroups = [];             # DEFAULT: [] - Additional groups beyond defaults
    # };

    # -----------------------------------------------------------------------
    # PATHS (Auto-calculated from username)
    # -----------------------------------------------------------------------
    # paths = {
    #   configDir = "/home/<username>/hydrix-config";  # DEFAULT: auto
    #   hydrixDir = "/home/<username>/Hydrix";         # DEFAULT: auto (for developers)
    # };

    # -----------------------------------------------------------------------
    # DEFAULT APPLICATIONS
    # -----------------------------------------------------------------------
    # terminal = "alacritty";    # DEFAULT: "alacritty"
    # shell = "fish";            # DEFAULT: "fish" (options: fish, bash, zsh)
    # browser = "firefox";       # DEFAULT: "firefox"
    # editor = "vim";            # DEFAULT: "vim"
    # fileManager = "ranger";    # DEFAULT: "ranger"
    # imageViewer = "feh";       # DEFAULT: "feh"
    # mediaPlayer = "mpv";       # DEFAULT: "mpv"
    # pdfViewer = "zathura";     # DEFAULT: "zathura"

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << 'MACHINE_EOF'

    # -----------------------------------------------------------------------
    # ROUTER VM
    # -----------------------------------------------------------------------
MACHINE_EOF

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << MACHINE_EOF
    router = {
      type = "${CONFIG[routerType]}";  # DETECTED (DEFAULT: "microvm", options: microvm, libvirt, none)
      autostart = false;               # DEFAULT: true - Set false until tested
      # username = "";                 # DEFAULT: same as hydrix.username
      # hashedPassword = null;         # DEFAULT: null

      wifi = {
        ssid = "${CONFIG[wifiSsid]}";          # DETECTED from NetworkManager
        password = "${CONFIG[wifiPassword]}";  # DETECTED from NetworkManager
        # networks = [];                       # DEFAULT: [] - For multiple networks:
        # networks = [
        #   { ssid = "HomeNetwork"; password = "secret"; priority = 100; }
        #   { ssid = "WorkNetwork"; password = "secret2"; priority = 50; }
        # ];
      };

      # vpn.mullvad = {
      #   enable = false;              # DEFAULT: false
      #   privateKey = "";             # Your Mullvad WireGuard private key
      #   address = "";                # Assigned address (e.g., "10.65.x.x/32")
      #   exitNodes = {};              # DEFAULT: {} - Example:
      #   # exitNodes = {
      #   #   se-sto = { server = "se-sto-wg-001.relays.mullvad.net"; publicKey = "..."; };
      #   # };
      # };
    };
MACHINE_EOF

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << 'MACHINE_EOF'

    # -----------------------------------------------------------------------
    # HARDWARE
    # -----------------------------------------------------------------------
MACHINE_EOF

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << MACHINE_EOF
    hardware = {
      platform = "${CONFIG[platform]}";  # DETECTED (DEFAULT: "intel", options: intel, amd, generic)
      isAsus = ${CONFIG[isAsus]};        # DETECTED (DEFAULT: false)

      vfio = {
        enable = true;                          # DEFAULT: true
        pciIds = [ "${CONFIG[wifiPciId]}" ];    # DETECTED - WiFi vendor:device ID
        wifiPciAddress = "${CONFIG[wifiPciAddress]}";  # DETECTED - PCI address (XX:XX.X)
      };

      grub = {
        gfxmodeEfi = "1920x1200";  # DEFAULT: "1920x1200"
      };
    };
MACHINE_EOF

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << 'MACHINE_EOF'

    # -----------------------------------------------------------------------
    # SERVICES
    # -----------------------------------------------------------------------
    services = {
      tailscale.enable = true;        # DEFAULT: true  - Tailscale VPN
      ssh.enable = true;              # DEFAULT: true - OpenSSH daemon
    };

    # -----------------------------------------------------------------------
    # HARDWARE FEATURES
    # -----------------------------------------------------------------------
    # hardware.bluetooth.enable = true;   # DEFAULT: true - Bluetooth + Blueman
    # hardware.i2c.enable = true;         # DEFAULT: true - DDC/CI monitor control
    # hardware.touchpad.enable = true;    # DEFAULT: true - libinput touchpad

    # -----------------------------------------------------------------------
    # DISKO - Disk Partitioning (only for fresh installs)
    # -----------------------------------------------------------------------
MACHINE_EOF

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << MACHINE_EOF
    disko = {
      enable = false;                  # Don't touch existing disk layout
      device = "${CONFIG[diskoDevice]}";  # DEFAULT: "/dev/nvme0n1"
      # swapSize = "16G";              # DEFAULT: "16G"
      # layout = "full-disk-plain";    # DEFAULT: "full-disk-plain"
      #                                # Options: full-disk-plain, full-disk-luks, dual-boot-luks
      # luksPassword = null;           # Required for *-luks layouts
    };
MACHINE_EOF

    cat >> "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" << 'MACHINE_EOF'

    # -----------------------------------------------------------------------
    # NETWORKING
    # -----------------------------------------------------------------------
    # networking = {
    #   bridges = [ "br-mgmt" "br-pentest" "br-comms" "br-browse" "br-dev" "br-shared" "br-builder" "br-lurking" ];  # DEFAULT
    #   hostIp = "192.168.100.1";       # DEFAULT - Host IP on management bridge
    #   routerIp = "192.168.100.253";   # DEFAULT - Router VM IP (default gateway)
    #   subnets = {                     # DEFAULT - Subnet prefixes per bridge
    #     mgmt = "192.168.100";
    #     pentest = "192.168.101";
    #     comms = "192.168.102";
    #     lurking = "192.168.107";
    #     browse = "192.168.103";
    #     dev = "192.168.104";
    #     shared = "192.168.105";
    #     builder = "192.168.106";
    #   };
    # };

    # -----------------------------------------------------------------------
    # SECRETS (sops-nix)
    # -----------------------------------------------------------------------
    # secrets = {
    #   enable = false;                 # DEFAULT: false
    #   github.enable = false;          # DEFAULT: false - Provision GitHub SSH keys to VMs
    # };

    # -----------------------------------------------------------------------
    # POWER MANAGEMENT
    # -----------------------------------------------------------------------
    # power = {
    #   defaultProfile = "balanced";    # DEFAULT: "balanced"
    #                                   # Options: powersave, balanced, performance
    #                                   # Change at runtime: power-mode <profile>
    #   autoCpuFreq = true;             # DEFAULT: true - auto-cpufreq service
    # };

    # -----------------------------------------------------------------------
    # BUILDER VM (for lockdown mode builds)
    # -----------------------------------------------------------------------
    # builder.enable = false;           # DEFAULT: false

    # -----------------------------------------------------------------------
    # GIT-SYNC VM (for lockdown mode git operations)
    # -----------------------------------------------------------------------
    # gitsync.enable = false;           # DEFAULT: false

    # -----------------------------------------------------------------------
    # MICROVM HOST
    # -----------------------------------------------------------------------
    microvmHost = {
      enable = true;
      # defaultBridge = "br-browse";    # DEFAULT: "br-browse"

      # VM name customization (rarely needed)
      # vmNames = {
      #   browse = "microvm-browsing";   # DEFAULT
      #   hack = "microvm-pentest";     # DEFAULT
      #   dev = "microvm-dev";          # DEFAULT
      #   comms = "microvm-comms";      # DEFAULT
      #   lurk = "microvm-lurking";     # DEFAULT
      #   build = "microvm-builder";    # DEFAULT
      #   router = "microvm-router";    # DEFAULT
      # };

      # Enable/configure individual VMs
      vms = {
        "microvm-router" = {
          enable = true;
          # autostart = false;          # DEFAULT: false
          # secrets.github = false;     # DEFAULT: false
        };
        "microvm-browsing" = {
          enable = false;               # Enable when ready
          # autostart = false;
          # secrets.github = false;
        };
        "microvm-pentest" = {
          enable = false;
          # autostart = false;
          # secrets.github = false;
        };
        "microvm-dev" = {
          enable = false;
          # autostart = false;
          # secrets.github = false;
        };
        "microvm-comms" = {
          enable = false;
          # autostart = false;
          # secrets.github = false;
        };
        "microvm-lurking" = {
          enable = false;
          # autostart = false;
          # secrets.github = false;
        };
        "microvm-builder" = {
          enable = true;                # Needed for lockdown mode builds
          # autostart = false;
          # secrets.github = false;
        };
        "microvm-gitsync" = {
          enable = true;                # Needed for lockdown mode git push/pull
          # autostart = false;
        };
      };
    };

    # -----------------------------------------------------------------------
    # COLORSCHEME INHERITANCE (for VMs)
    # -----------------------------------------------------------------------
    # colorschemeInheritance = "dynamic";  # DEFAULT: "dynamic"
    #                                      # Options: full (all from host), dynamic (host bg + VM text), none

    # vmColors = {
    #   enable = false;                 # DEFAULT: false
    #   hostColorscheme = null;         # DEFAULT: null
    # };

    # -----------------------------------------------------------------------
    # GRAPHICAL ENVIRONMENT
    # -----------------------------------------------------------------------
    graphical = {
      enable = true;                    # DEFAULT: false (auto-enabled for hosts)
      # standalone = false;             # DEFAULT: false - For libvirt VMs with virt-manager

      # colorscheme = "nord";           # DEFAULT: inherits from hydrix.colorscheme
      # wallpaper = null;               # DEFAULT: null - Path to wallpaper image
      # polarity = "dark";              # DEFAULT: "dark" (options: dark, light)

      # --- Font Configuration ---
      font = {
        family = "Iosevka";             # DEFAULT: "Iosevka"
        # size = 10;                    # DEFAULT: 10 - Base font size at 96 DPI
        # relations = {                 # Per-app font size multipliers
        #   alacritty = 0.925;          # DEFAULT
        #   polybar = 1.0;              # DEFAULT
        #   rofi = 1.0;                 # DEFAULT
        #   dunst = 1.0;                # DEFAULT
        #   firefox = 1.2;              # DEFAULT
        #   gtk = 1.0;                  # DEFAULT
        # };
        # standaloneRelations = {};     # DEFAULT: {} - Override relations without external monitor
        # familySizes = { "Iosevka" = 10; "Tamzen" = 14; };  # DEFAULT
        # overrides = {};               # DEFAULT: {} - Direct size overrides per app
        # familyOverrides = {};         # DEFAULT: {} - Font family overrides per app
      };

      # --- Keyboard ---
      # keyboard.xmodmap = ''
      #   clear lock
      #   clear control
      #   keycode 66 = Control_L
      #   add control = Control_L Control_R
      # '';

      # --- UI Configuration ---
      ui = {
        # polybarStyle = "modular";      # DEFAULT: "modular" (options: unibar, modular, pills)
        # gaps = 15;                    # DEFAULT: 15 - i3 inner gaps
        # gapsStandaloneRelation = 1.0; # DEFAULT: 1.0
        # border = 2;                   # DEFAULT: 2 - Window border width
        # barHeight = 23;               # DEFAULT: 23
        # barHeightRelation = 1.0;      # DEFAULT: 1.0
        # barHeightFamilyRelations = { "Tamzen" = 0.85; };  # DEFAULT
        # barPadding = 2;               # DEFAULT: 2
        # barGaps = null;               # DEFAULT: null (= gaps/2)
        # barEdgeGapsFactor = 1.0;      # DEFAULT: 1.0
        # outerGapsMatchBar = false;    # DEFAULT: false
        # floatingBar = true;           # DEFAULT: true
        # bottomBar = true;             # DEFAULT: true - VM metrics bar
        # padding = 8;                  # DEFAULT: 8
        # paddingSmall = 5;             # DEFAULT: 5
        # cornerRadius = 2;             # DEFAULT: 2 - Picom corner radius
        # shadowRadius = 18;            # DEFAULT: 18
        # shadowOffset = 17;            # DEFAULT: 17

        # workspaceLabels = {           # DEFAULT - Workspace display labels
        #   "1" = "I"; "2" = "II"; "3" = "III"; "4" = "IV"; "5" = "V";
        #   "6" = "VI"; "7" = "VII"; "8" = "VIII"; "9" = "IX"; "10" = "X";
        # };
        # workspaceDescriptions = {};   # DEFAULT: {}

        # rofiWidth = 800;              # DEFAULT: 800
        # rofiHeight = 400;             # DEFAULT: 400
        # dunstWidth = 300;             # DEFAULT: 300
        # dunstOffset = 300;            # DEFAULT: 300

        # compositor.animations = "modern";  # DEFAULT: "modern" (options: none, modern)

        # opacity = {
        #   active = 1.0;               # DEFAULT: 1.0 (no transparency)
        #   inactive = 1.0;             # DEFAULT: 1.0
        #   exclude = [ "Alacritty" "feh" "Feh" "firefox" "Firefox" "mpv" "vlc" ];  # DEFAULT
        #   alacritty = 0.85;           # DEFAULT: 0.85 (deprecated, use overlay)
        #   overlay = 0.85;             # DEFAULT: 0.85 - Unified for terminals/overlays
        #   overlayOverrides = { alacritty = 0.95; };  # DEFAULT
        #   rules = { "Polybar" = 95; };  # DEFAULT - Custom per-class rules
        # };
      };

      # --- Blue Light Filter (blugon) ---
      # bluelight = {
      #   enable = true;                # DEFAULT: true
      #   defaultTemp = 4500;           # DEFAULT: 4500 - Color temperature in Kelvin
      #   minTemp = 2500;               # DEFAULT: 2500 (warmest)
      #   maxTemp = 6500;               # DEFAULT: 6500 (coolest)
      #   step = 200;                   # DEFAULT: 200 - Adjustment step
      #   schedule = {
      #     dayTemp = 6500;             # DEFAULT: 6500
      #     nightTemp = 3500;           # DEFAULT: 3500
      #     dayStart = 7;               # DEFAULT: 7 (7am)
      #     nightStart = 20;            # DEFAULT: 20 (8pm)
      #   };
      # };

      # --- Scaling ---
      # scaling = {
      #   auto = true;                  # DEFAULT: true - Auto DPI detection
      #   applyOnLogin = true;          # DEFAULT: true
      #   referenceDpi = 96;            # DEFAULT: 96
      #   internalResolution = null;    # DEFAULT: null - e.g., "1920x1200"
      #   standaloneScaleFactor = 1.0;  # DEFAULT: 1.0
      # };

      # --- VM Bar (resource metrics inside VMs) ---
      # vmBar = {
      #   enable = false;               # DEFAULT: false
      #   position = "bottom";          # DEFAULT: "bottom"
      # };

      # --- Lockscreen ---
      # lockscreen = {
      #   idleTimeout = 600;            # DEFAULT: 600 (seconds, null to disable)
      #   font = "";                    # DEFAULT: same as graphical font family
      #   fontSize = 143;               # DEFAULT: 143
      #   clockSize = 104;              # DEFAULT: 104
      #   text = "Enter password";      # DEFAULT
      #   wrongText = "Ah ah ah! You didn't say the magic word!!";  # DEFAULT
      #   verifyText = "Verifying...";  # DEFAULT
      #   blur = true;                  # DEFAULT: true
      # };

      # --- Splash Screen ---
      # splash = {
      #   enable = false;               # DEFAULT: false
      #   title = "HYDRIX";             # DEFAULT
      #   text = "initializing...";     # DEFAULT
      #   maxTimeout = 15;              # DEFAULT: 15 (seconds)
      #   font = null;                  # DEFAULT: null (CozetteVector)
      # };
    };
  };
}
MACHINE_EOF

    log "  Created: $CONFIG_DIR/machines/${CONFIG[serial]}.nix"
}

generate_full_config() {
    log "Generating full Hydrix configuration..."

    mkdir -p "$CONFIG_DIR"

    # Generate all components
    generate_flake_nix
    copy_template_specialisations
    copy_template_profiles
    copy_template_shared
    substitute_shared_locale
    copy_template_modules
    copy_template_templates
    copy_template_configs
    create_colorschemes_dir
    copy_wallpapers
    copy_template_readme
    copy_template_secrets
    generate_machine_nix
    copy_hardware_config

    # Initialize git repo
    log "Initializing git repository..."
    (
        cd "$CONFIG_DIR"
        git init
        git add .
        git commit -m "Initial Hydrix configuration for ${CONFIG[serial]}"
    )

    success "Configuration generated at: $CONFIG_DIR"
}

generate_machine_only() {
    log "Adding machine to existing config..."

    # Check if machine already exists
    if [[ -f "$CONFIG_DIR/machines/${CONFIG[serial]}.nix" ]]; then
        warn "Machine ${CONFIG[serial]} already exists!"
        read -p "Overwrite? [y/N]: " overwrite
        [[ "$overwrite" =~ ^[Yy]$ ]] || error "Cancelled"
    fi

    generate_machine_nix
    copy_hardware_config

    # Commit the new machine
    (
        cd "$CONFIG_DIR"
        git add "machines/${CONFIG[serial]}.nix"
        if [[ -n "${CONFIG[hardwareConfigPath]}" ]]; then
            git add "machines/${CONFIG[serial]}-hardware.nix"
        fi
        git commit -m "Add machine: ${CONFIG[serial]}"
    )

    success "Added: machines/${CONFIG[serial]}.nix"
}

use_existing_machine() {
    log "Using existing machine config..."

    # Validate the existing config against detected hardware
    validate_existing_config "$CONFIG_DIR/machines/${CONFIG[serial]}.nix"

    # Regenerate hardware config from current system
    regenerate_hardware_config

    # Commit the updated hardware config
    (
        cd "$CONFIG_DIR"
        if [[ -f "machines/${CONFIG[serial]}-hardware.nix" ]]; then
            git add "machines/${CONFIG[serial]}-hardware.nix"
            git commit -m "Update hardware config for ${CONFIG[serial]}" 2>/dev/null || true
        fi
    )

    success "Using existing: machines/${CONFIG[serial]}.nix"
    success "Hardware config regenerated: machines/${CONFIG[serial]}-hardware.nix"
}

# ========== INTERACTIVE PROMPTS ==========

prompt_wifi() {
    if [[ -z "${CONFIG[wifiSsid]}" ]]; then
        echo ""
        read -p "WiFi SSID (for router VM): " ssid
        CONFIG[wifiSsid]="$ssid"

        if [[ -n "$ssid" ]]; then
            read -s -p "WiFi password: " pass
            echo ""
            CONFIG[wifiPassword]="$pass"
            unset pass  # Clear password variable
        fi
    else
        echo ""
        log "Detected WiFi: ${CONFIG[wifiSsid]}"
        read -p "Use this network? [Y/n]: " use_detected

        if [[ "$use_detected" =~ ^[Nn]$ ]]; then
            read -p "WiFi SSID: " ssid
            CONFIG[wifiSsid]="$ssid"
            read -s -p "WiFi password: " pass
            echo ""
            CONFIG[wifiPassword]="$pass"
            unset pass  # Clear password variable
        elif [[ -z "${CONFIG[wifiPassword]}" ]]; then
            read -s -p "WiFi password for ${CONFIG[wifiSsid]}: " pass
            echo ""
            CONFIG[wifiPassword]="$pass"
            unset pass  # Clear password variable
        fi
    fi
}

prompt_colorscheme() {
    echo ""
    log "Available colorschemes: puccy, nord, nvid, punk, perp, gruvbox, dracula"
    read -p "Colorscheme [puccy]: " cs
    CONFIG[colorscheme]="${cs:-puccy}"
}

# ========== HYDRIX SOURCE SELECTION ==========

select_hydrix_source() {
    echo ""
    log "=== Hydrix Source Configuration ==="
    echo ""
    echo "How do you want to reference Hydrix?"
    echo ""
    echo "  [1] GitHub (recommended)"
    echo "      Always pulls latest from git+https://github.com/borttappat/Hydrix.git"
    echo "      Best for: end users, automatic updates"
    echo ""
    echo "  [2] Local clone"
    echo "      Uses a local ~/Hydrix directory"
    echo "      Best for: development, offline use, testing changes"
    echo ""
    echo "  [3] Custom URL"
    echo "      Specify your own flake URL (fork, branch, etc.)"
    echo "      Best for: using your own fork or specific branch"
    echo ""

    read -p "Selection [1-3, default=1]: " source_choice

    case "${source_choice:-1}" in
        1)
            CONFIG[hydrixSource]="github"
            CONFIG[hydrixUrl]="git+https://github.com/borttappat/Hydrix.git"
            log "Using GitHub: git+https://github.com/borttappat/Hydrix.git"
            ;;
        2)
            configure_local_clone
            ;;
        3)
            configure_custom_url
            ;;
        *)
            CONFIG[hydrixSource]="github"
            CONFIG[hydrixUrl]="git+https://github.com/borttappat/Hydrix.git"
            log "Using GitHub: git+https://github.com/borttappat/Hydrix.git"
            ;;
    esac
}

configure_local_clone() {
    CONFIG[hydrixSource]="local"
    local default_path="$HOME/Hydrix"

    echo ""
    read -p "Path to Hydrix clone [$default_path]: " clone_path
    clone_path="${clone_path:-$default_path}"
    CONFIG[hydrixLocalPath]="$clone_path"
    CONFIG[hydrixUrl]="path:$clone_path"

    if [[ -d "$clone_path" ]] && [[ -f "$clone_path/flake.nix" ]]; then
        log "Found existing Hydrix clone at: $clone_path"
    else
        echo ""
        echo "No Hydrix clone found at: $clone_path"
        read -p "Clone from GitHub now? [Y/n]: " do_clone

        if [[ ! "$do_clone" =~ ^[Nn]$ ]]; then
            log "Cloning Hydrix to $clone_path..."
            mkdir -p "$(dirname "$clone_path")"
            git clone https://github.com/borttappat/Hydrix.git "$clone_path"
            success "Hydrix cloned successfully"
        else
            warn "No local clone available - falling back to GitHub"
            CONFIG[hydrixSource]="github"
            CONFIG[hydrixUrl]="git+https://github.com/borttappat/Hydrix.git"
            CONFIG[hydrixLocalPath]=""
            return
        fi
    fi

    log "Using local clone: ${CONFIG[hydrixUrl]}"
}

configure_custom_url() {
    CONFIG[hydrixSource]="custom"
    echo ""
    echo "Examples:"
    echo "  git+https://github.com/youruser/Hydrix.git"
    echo "  git+https://github.com/youruser/Hydrix.git?ref=branch-name"
    echo "  git+https://github.com/youruser/Hydrix.git"
    echo ""

    while true; do
        read -p "Enter flake URL: " custom_url

        if [[ -z "$custom_url" ]]; then
            warn "No URL provided - falling back to GitHub"
            CONFIG[hydrixSource]="github"
            CONFIG[hydrixUrl]="git+https://github.com/borttappat/Hydrix.git"
            return
        fi

        # Validate flake URL if validation functions are available
        if type check_flake_url &>/dev/null && ! check_flake_url "$custom_url"; then
            continue
        fi

        CONFIG[hydrixUrl]="$custom_url"
        log "Using custom URL: ${CONFIG[hydrixUrl]}"
        return
    done
}

# ========== MAIN ==========

main() {
    echo ""
    echo "=========================================="
    echo "  Hydrix Setup for Existing NixOS"
    echo "=========================================="
    echo ""

    # Check prerequisites
    if [[ ! -f /etc/NIXOS ]]; then
        error "This script is for NixOS systems only"
    fi

    # Detection (needed for all modes)
    detect_current_config
    detect_wifi_hardware
    detect_wifi_credentials
    detect_hardware_config

    # =========================================================================
    # MODE DETECTION
    # =========================================================================

    if [[ -d "$CONFIG_DIR/machines" ]]; then
        # Valid multi-machine repo
        prompt_existing_repo
    elif [[ -f "$CONFIG_DIR/machine.nix" ]]; then
        # Legacy format - auto-migrate
        migrate_legacy_config
    elif [[ -d "$CONFIG_DIR" ]]; then
        # Directory exists but not valid config
        prompt_clone_or_fresh
    else
        MODE="fresh"
    fi

    # Early exit if migration handled everything
    if [[ -z "$MODE" ]]; then
        echo ""
        success "=========================================="
        success "  Setup Complete!"
        success "=========================================="
        echo ""
        echo "Your config is at: $CONFIG_DIR"
        echo ""
        echo "To rebuild:"
        echo "  cd $CONFIG_DIR"
        echo "  rebuild   # auto-detects this machine by serial"
        echo ""
        exit 0
    fi

    # =========================================================================
    # GATHER CONFIGURATION (for add/fresh modes)
    # =========================================================================

    # Interactive prompts (skip for use-existing mode - using existing config)
    if [[ "$MODE" != "use-existing" ]]; then
        prompt_wifi
        prompt_colorscheme

        # Only ask for Hydrix source if fresh install
        if [[ "$MODE" == "fresh" ]]; then
            select_hydrix_source
        fi
    fi

    # Show summary
    echo ""
    log "=== Configuration Summary ==="
    echo "  Mode: $MODE"
    echo "  Username: ${CONFIG[username]}"
    echo "  Machine ID: ${CONFIG[serial]}"
    echo "  Hostname: ${CONFIG[hostname]} (visual)"
    echo "  Platform: ${CONFIG[platform]}"
    echo "  WiFi PCI: ${CONFIG[wifiPciAddress]}"
    echo "  WiFi SSID: ${CONFIG[wifiSsid]}"
    echo "  Colorscheme: ${CONFIG[colorscheme]}"
    echo "  Config dir: $CONFIG_DIR"
    if [[ "$MODE" == "fresh" ]]; then
        echo "  Hydrix:   ${CONFIG[hydrixUrl]}"
    fi
    if [[ "$MODE" == "use-existing" ]]; then
        echo "  Machine config: EXISTING (from cloned repo)"
        echo "  Hardware config: REGENERATED (from current system)"
    elif [[ -n "${CONFIG[hardwareConfigPath]}" ]]; then
        echo "  Machine config: NEW (auto-detected)"
        echo "  Hardware config: ${CONFIG[hardwareConfigPath]}"
    else
        echo "  Machine config: NEW (auto-detected)"
        echo "  Hardware config: NONE (system may not boot!)"
    fi
    echo ""

    read -p "Generate configuration? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && error "Cancelled"

    # =========================================================================
    # GENERATE BASED ON MODE
    # =========================================================================

    case "$MODE" in
        fresh)
            generate_full_config
            ;;
        add)
            generate_machine_only
            ;;
        use-existing)
            use_existing_machine
            ;;
        *)
            error "Unknown mode: $MODE"
            ;;
    esac

    echo ""
    success "=========================================="
    success "  Configuration Generated!"
    success "=========================================="
    echo ""
    echo "Config directory: $CONFIG_DIR"
    echo ""

    if [[ "$MODE" == "add" ]]; then
        echo "Existing machines in your config:"
        list_existing_machines
        echo ""
    fi

    # =========================================================================
    # BUILD & APPLY
    # =========================================================================

    echo ""
    log "=== Building System ==="
    echo ""
    echo "This will:"
    echo "  1. Validate the configuration"
    echo "  2. Build microvm-router VM"
    echo "  3. Build microvm-builder VM"
    echo "  4. Apply host configuration (nixos-rebuild switch)"
    echo ""
    echo "After completion, a REBOOT is required to:"
    echo "  - Blacklist iwlwifi driver (needed for WiFi passthrough)"
    echo "  - Start the router VM (autostart)"
    echo ""

    read -p "Build and apply now? [Y/n]: " do_build
    if [[ "$do_build" =~ ^[Nn]$ ]]; then
        echo ""
        echo "Skipped. To build manually later:"
        echo "  cd $CONFIG_DIR"
        echo "  nix build .#nixosConfigurations.microvm-router.config.microvm.declaredRunner"
        echo "  nix build .#nixosConfigurations.microvm-builder.config.microvm.declaredRunner"
        echo "  rebuild"
        echo ""
        return 0
    fi

    local flake_ref="path:${CONFIG_DIR}"

    # --- Step 1: Validate ---
    log "Validating configuration..."
    if ! nix flake check "$flake_ref" --no-build 2>&1; then
        error "Flake validation failed. Fix errors in $CONFIG_DIR and rebuild manually."
    fi
    success "Configuration valid"

    log "Evaluating host configuration..."
    if ! nix eval "${flake_ref}#nixosConfigurations.${CONFIG[serial]}.config.system.build.toplevel" \
         --no-write-lock-file >/dev/null 2>&1; then
        error "Host evaluation failed. Check $CONFIG_DIR/machines/${CONFIG[serial]}.nix"
    fi
    success "Host evaluation OK"

    # --- Step 2: Build microvm-router ---
    log "Building microvm-router..."
    local router_out="/tmp/microvm-router"
    if nix build "${flake_ref}#nixosConfigurations.microvm-router.config.microvm.declaredRunner" \
         -o "$router_out" 2>&1; then
        local router_store
        router_store=$(readlink -f "$router_out")
        sudo mkdir -p /var/lib/microvms/microvm-router/config
        sudo chown microvm:kvm /var/lib/microvms/microvm-router 2>/dev/null || true
        sudo chown root:root /var/lib/microvms/microvm-router/config 2>/dev/null || true
        sudo chmod 755 /var/lib/microvms/microvm-router /var/lib/microvms/microvm-router/config
        sudo ln -sfn "$router_store" /var/lib/microvms/microvm-router/current
        success "microvm-router built: $router_store"
    else
        warn "microvm-router build failed (WiFi may not be configured yet)"
    fi

    # --- Step 3: Build microvm-builder ---
    log "Building microvm-builder..."
    local builder_out="/tmp/microvm-builder"
    if nix build "${flake_ref}#nixosConfigurations.microvm-builder.config.microvm.declaredRunner" \
         -o "$builder_out" 2>&1; then
        local builder_store
        builder_store=$(readlink -f "$builder_out")
        sudo mkdir -p /var/lib/microvms/microvm-builder/config
        sudo chown microvm:kvm /var/lib/microvms/microvm-builder 2>/dev/null || true
        sudo chown root:root /var/lib/microvms/microvm-builder/config 2>/dev/null || true
        sudo chmod 755 /var/lib/microvms/microvm-builder /var/lib/microvms/microvm-builder/config
        sudo ln -sfn "$builder_store" /var/lib/microvms/microvm-builder/current
        success "microvm-builder built: $builder_store"
    else
        warn "microvm-builder build failed"
    fi

    # --- Step 4: Apply host configuration ---
    echo ""
    log "Applying host configuration..."
    if sudo nixos-rebuild switch --flake "${flake_ref}#${CONFIG[serial]}" 2>&1; then
        success "Host configuration applied"
    else
        error "nixos-rebuild switch failed. Check errors above."
    fi

    # --- Done ---
    echo ""
    success "=========================================="
    success "  Setup Complete!"
    success "=========================================="
    echo ""
    echo "REBOOT NOW to complete setup:"
    echo "  sudo reboot"
    echo ""
    echo "After reboot:"
    echo "  - iwlwifi will be blacklisted (VFIO passthrough active)"
    echo "  - microvm-router will autostart (internet via router VM)"
    echo "  - System boots into administrative mode"
    echo ""
    echo "Your config: $CONFIG_DIR"
    echo "  Edit:    \$EDITOR $CONFIG_DIR/machines/${CONFIG[serial]}.nix"
    echo "  Rebuild: rebuild"
    echo ""
    echo "Set your wallpaper and colorscheme after reboot:"
    echo "  walrgb ~/wallpapers/WindowRain.png"
    echo "Or pick a random wallpaper from the directory:"
    echo "  randomwalrgb ~/wallpapers"
    echo ""

    if [[ "${CONFIG[hydrixSource]}" == "local" ]]; then
        echo "Local Hydrix clone: ${CONFIG[hydrixLocalPath]}"
        echo "After Hydrix changes: nix flake update && rebuild"
        echo ""
    fi
}

# Brace block forces bash to buffer the entire script before executing,
# which is required when piped via curl | bash
{
    mkdir -p /var/log/hydrix 2>/dev/null || true
    HYDRIX_LOG="/var/log/hydrix/hydrix-setup-$(date +%Y%m%d-%H%M%S).log"
    echo "Logging to: $HYDRIX_LOG"
    exec > >(tee -a "$HYDRIX_LOG") 2>&1
    main "$@"
}
