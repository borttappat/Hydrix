#!/usr/bin/env bash
# install-hydrix.sh - Options-driven Hydrix installer
#
# This script installs Hydrix from a live Linux environment.
# It generates a standalone config directory that imports Hydrix from GitHub.
#
# Features:
# - Fresh installation with full config generation
# - Clone existing repo: bring your config from another system
# - Add machine to cloned repo: multi-machine support
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/borttappat/Hydrix/main/scripts/install-hydrix.sh | bash
#
# The installer creates:
#   ~/hydrix-config/
#   ├── flake.nix             # Imports Hydrix from GitHub
#   ├── machines/<serial>.nix # Machine config (named by hardware serial)
#   ├── profiles/             # VM profile customizations
#   ├── specialisations/      # Boot mode configurations
#   └── shared/common.nix     # Shared settings (locale, timezone)

set -euo pipefail

# When piped via curl | bash, redirect interactive reads to the terminal
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    read() { builtin read "$@" < /dev/tty; }
fi

# Ensure nix experimental features are available (needed on stock NixOS ISO)
export NIX_CONFIG="experimental-features = nix-command flakes"

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

MIN_DISK_SIZE=$((50 * 1024 * 1024 * 1024))  # 50GB
CONFIG_DIR="/mnt/home/USER/hydrix-config"  # Updated with actual username
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=""
fi
HYDRIX_CLONE_DIR=""

# Mode: "fresh" | "add" | "use-existing"
MODE="fresh"
CLONED_REPO=""

# Temp directory for config generation and validation (set during install)
TEMP_CONFIG=""

# ========== HYDRIX SOURCE BOOTSTRAP ==========
# When run via curl|bash, SCRIPT_DIR is empty and repo files are missing.
# Shallow-clone the repo so templates/disko are available.

ensure_hydrix_source() {
    # If SCRIPT_DIR is set and the repo tree looks intact, nothing to do
    if [[ -n "$SCRIPT_DIR" ]] \
        && [[ -d "$SCRIPT_DIR/../templates/user-config" ]] \
        && [[ -d "$SCRIPT_DIR/../disko" ]]; then
        return 0
    fi

    echo "Hydrix source tree not found — fetching via shallow clone..."

    HYDRIX_CLONE_DIR="$(mktemp -d)"

    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        gh repo clone borttappat/Hydrix "$HYDRIX_CLONE_DIR/Hydrix" -- --depth 1 \
            || { echo "gh clone failed, trying git..."; HYDRIX_CLONE_DIR="$(mktemp -d)"; }
    fi

    # Fallback (or primary if gh unavailable)
    if [[ ! -d "$HYDRIX_CLONE_DIR/Hydrix/scripts" ]]; then
        git clone --depth 1 https://github.com/borttappat/Hydrix.git "$HYDRIX_CLONE_DIR/Hydrix" \
            || { echo "ERROR: Failed to clone Hydrix repository."; exit 1; }
    fi

    SCRIPT_DIR="$HYDRIX_CLONE_DIR/Hydrix/scripts"

    # Re-source common.sh from clone if not already loaded
    if ! command -v command_exists &>/dev/null && [[ -f "$SCRIPT_DIR/lib/common.sh" ]]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/lib/common.sh"
    fi

    echo "Hydrix source ready at $HYDRIX_CLONE_DIR/Hydrix"
}

# ========== SECURE CLEANUP ==========
# Ensure sensitive data is cleared on exit (normal or error)

secure_cleanup() {
    # Clear sensitive variables from memory
    unset token pass1 pass2 password password_confirm key_content
    unset WIFI_PASSWORD

    # Securely delete temporary SSH key if it exists
    if [[ -f ~/.ssh/hydrix_temp_key ]]; then
        shred -u ~/.ssh/hydrix_temp_key 2>/dev/null || rm -f ~/.ssh/hydrix_temp_key
    fi

    # Clear SSH command override
    unset GIT_SSH_COMMAND

    # Clean up LUKS password file
    if [[ -f /tmp/luks-password ]]; then
        shred -u /tmp/luks-password 2>/dev/null || rm -f /tmp/luks-password
    fi

    # Clean up temp config directory if set and installation didn't complete
    # (successful install cleans this up explicitly)
    if [[ -n "${TEMP_CONFIG:-}" ]] && [[ -d "${TEMP_CONFIG:-}" ]]; then
        rm -rf "$TEMP_CONFIG"
    fi

    # Clean up shallow clone used for curl|bash bootstrap
    if [[ -n "${HYDRIX_CLONE_DIR:-}" ]] && [[ -d "${HYDRIX_CLONE_DIR:-}" ]]; then
        rm -rf "$HYDRIX_CLONE_DIR"
    fi
}

# Register cleanup handler for all exit paths
trap secure_cleanup EXIT

# Collected configuration
declare -A CONFIG=(
    [username]=""
    [hostname]=""
    [serial]=""
    [device]=""
    [layout]="full-disk-luks"
    [swapSize]="16G"
    [diskPassword]=""
    [efiPartition]=""
    [timezone]="Europe/Stockholm"
    [locale]="en_US.UTF-8"
    [consoleKeymap]="us"
    [xkbLayout]="us"
    [xkbVariant]=""
    [platform]="intel"
    [isAsus]="false"
    [wifiPciAddress]=""
    [wifiPciId]=""
    [wifiSsid]=""
    [wifiPassword]=""
    [routerType]="microvm"
    [colorscheme]="nord"
    [grubGfxmode]="auto"
    [hydrixSource]="github"
    [hydrixUrl]="github:borttappat/Hydrix"
    [hydrixLocalPath]=""
)

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
    echo "  4) Skip - proceed with fresh installation"
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
    # github.com/user/repo -> https://TOKEN@github.com/user/repo.git
    # git@github.com:user/repo.git -> https://TOKEN@github.com/user/repo.git
    # https://github.com/user/repo -> https://TOKEN@github.com/user/repo.git

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
    echo "  1) Paste SSH private key (will be stored temporarily)"
    echo "  2) Specify path to existing key"
    echo ""
    read -p "Select [1-2]: " ssh_choice

    case "$ssh_choice" in
        1)
            echo ""
            echo "Paste your SSH private key (end with Ctrl+D on a new line):"
            local key_content
            key_content=$(cat)
            mkdir -p ~/.ssh
            chmod 700 ~/.ssh
            echo "$key_content" > ~/.ssh/hydrix_temp_key
            chmod 600 ~/.ssh/hydrix_temp_key
            export GIT_SSH_COMMAND="ssh -i ~/.ssh/hydrix_temp_key -o StrictHostKeyChecking=no"
            success "Temporary SSH key configured"
            return 0
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

cleanup_temp_ssh_key() {
    if [[ -f ~/.ssh/hydrix_temp_key ]]; then
        # Securely delete the temporary key (shred overwrites before unlinking)
        shred -u ~/.ssh/hydrix_temp_key 2>/dev/null || rm -f ~/.ssh/hydrix_temp_key
        unset GIT_SSH_COMMAND
    fi
    # Clear key content from memory
    unset key_content
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
                    cleanup_temp_ssh_key
                    return 0
                fi
                cleanup_temp_ssh_key
            fi
            warn "SSH authentication failed"
            return 1
            ;;
        4|*)
            # Skip
            return 1
            ;;
    esac
}

# ========== MULTI-MACHINE SUPPORT ==========

list_existing_machines() {
    local config_dir="$1"
    log "Existing machines in config:"
    shopt -s nullglob
    for f in "$config_dir/machines/"*.nix; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" .nix)
        echo "  - $name"
    done
    shopt -u nullglob
}

select_config_source() {
    echo ""
    log "=== Configuration Source ==="
    echo ""
    echo "Options:"
    echo "  1) Fresh installation (new config)"
    echo "  2) Clone existing hydrix-config repo"
    echo ""
    read -p "Select [1-2, default=1]: " config_choice

    case "${config_choice:-1}" in
        2)
            clone_existing_repo
            ;;
        *)
            MODE="fresh"
            ;;
    esac
}

clone_existing_repo() {
    echo ""
    read -p "Git URL of your existing hydrix-config: " repo_url

    if [[ -z "$repo_url" ]]; then
        warn "No URL provided - proceeding with fresh installation"
        MODE="fresh"
        return
    fi

    local temp_dir
    temp_dir=$(mktemp -d)

    # Try clone with authentication handling
    if ! try_clone_with_auth "$repo_url" "$temp_dir/hydrix-config"; then
        rm -rf "$temp_dir"
        warn "Failed to clone repository - proceeding with fresh installation"
        MODE="fresh"
        return
    fi

    # Validate structure
    if [[ ! -d "$temp_dir/hydrix-config/machines" ]]; then
        rm -rf "$temp_dir"
        warn "Invalid hydrix-config (missing machines/) - proceeding with fresh installation"
        MODE="fresh"
        return
    fi

    success "Cloned existing configuration"
    list_existing_machines "$temp_dir/hydrix-config"

    CLONED_REPO="$temp_dir/hydrix-config"

    # Check if machine already exists in cloned config
    if [[ -f "$CLONED_REPO/machines/${CONFIG[serial]}.nix" ]]; then
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
                rm -rf "$temp_dir"
                error "Cancelled by user"
                ;;
            *)
                MODE="use-existing"
                log "Will use existing config, regenerate hardware detection"
                ;;
        esac
    else
        MODE="add"
        echo ""
        log "Your new machine (${CONFIG[serial]:-<serial>}) will be added to this config"
    fi
}

# ========== HARDWARE DETECTION ==========

detect_cpu_platform() {
    log "Detecting CPU platform..."

    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        CONFIG[platform]="intel"
        log "  Detected: Intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        CONFIG[platform]="amd"
        log "  Detected: AMD"
    else
        CONFIG[platform]="generic"
        log "  Detected: Generic"
    fi
}

detect_asus() {
    log "Detecting ASUS hardware..."

    if [[ -d /sys/module/asus_wmi ]] || \
       [[ -d /sys/module/asus_nb_wmi ]] || \
       grep -qi "asus" /sys/class/dmi/id/board_vendor 2>/dev/null || \
       grep -qi "asus" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        CONFIG[isAsus]="true"
        log "  Detected: ASUS laptop"
    else
        CONFIG[isAsus]="false"
        log "  Detected: Non-ASUS"
    fi
}

detect_wifi_hardware() {
    log "Detecting WiFi hardware for VFIO passthrough..."

    local pci_addr=""
    local pci_id=""

    # Strategy 1: Find from network interfaces
    for iface in /sys/class/net/wl*; do
        [[ -e "$iface" ]] || continue
        local iface_name
        iface_name=$(basename "$iface")

        if [[ -e "$iface/device" ]]; then
            local pci_path
            pci_path=$(readlink -f "$iface/device" 2>/dev/null || echo "")
            pci_addr=$(basename "$pci_path" 2>/dev/null || echo "")

            if [[ -n "$pci_addr" ]] && [[ "$pci_addr" != "device" ]]; then
                # Get vendor:device ID
                local device_info
                device_info=$(lspci -nn -s "$pci_addr" 2>/dev/null || echo "")
                pci_id=$(echo "$device_info" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1 || echo "")

                log "  Found: $iface_name"
                log "    PCI: $pci_addr"
                log "    ID: $pci_id"
                break
            fi
        fi
    done

    # Strategy 2: Scan PCI directly
    if [[ -z "$pci_addr" ]]; then
        log "  Scanning PCI devices..."

        local wifi_pci
        wifi_pci=$(lspci -nn | grep -iE "network.*wireless|wireless.*network|wi-fi|802\.11" | head -1 || true)

        if [[ -n "$wifi_pci" ]]; then
            pci_addr=$(echo "$wifi_pci" | awk '{print $1}')
            pci_id=$(echo "$wifi_pci" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1 || echo "")
            log "  Found PCI: $pci_addr (ID: $pci_id)"
        fi
    fi

    # Strategy 3: Any network controller
    if [[ -z "$pci_addr" ]]; then
        local net_pci
        net_pci=$(lspci -nn | grep -i "Network controller" | head -1 || true)

        if [[ -n "$net_pci" ]]; then
            pci_addr=$(echo "$net_pci" | awk '{print $1}')
            pci_id=$(echo "$net_pci" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1 || echo "")
            log "  Found network controller: $pci_addr"
        fi
    fi

    if [[ -n "$pci_addr" ]]; then
        # Strip domain prefix if present (0000:XX:XX.X -> XX:XX.X)
        CONFIG[wifiPciAddress]="${pci_addr#0000:}"
        CONFIG[wifiPciId]="$pci_id"
        success "WiFi hardware detected"
    else
        warn "Could not detect WiFi hardware"
        warn "You can configure this manually after installation"
        CONFIG[wifiPciAddress]="00:14.3"
        CONFIG[wifiPciId]="8086:0000"
    fi
}

detect_display_resolution() {
    log "Detecting display resolution..."

    local res
    res=$(xrandr 2>/dev/null | grep '\*' | head -1 | awk '{print $1}' || echo "")

    if [[ -n "$res" ]]; then
        CONFIG[grubGfxmode]="$res"
        log "  Detected: $res"
    else
        CONFIG[grubGfxmode]="auto"
        log "  Using: auto"
    fi
}

detect_hardware_serial() {
    log "Detecting hardware serial for machine identification..."

    local serial
    serial=$(detect_serial) || true

    if [[ "$serial" == "unknown-machine" ]]; then
        warn "  Could not detect hardware serial"
        serial=$(generate_fallback_id)
        warn "  Using fallback identifier: $serial"
    else
        log "  Detected serial: $serial"
    fi

    CONFIG[serial]="$serial"
    # Visual hostname is always "hydrix" - serial is for config file identification
    CONFIG[hostname]="hydrix"
}

detect_wifi_credentials() {
    log "Attempting to detect current WiFi connection..."

    # Try nmcli dev wifi show first (newer method)
    local wifi_show
    wifi_show=$(nmcli dev wifi show 2>/dev/null || echo "")

    if [[ -n "$wifi_show" ]]; then
        CONFIG[wifiSsid]=$(echo "$wifi_show" | grep -E "^SSID:" | sed 's/^SSID:[[:space:]]*//')
        CONFIG[wifiPassword]=$(echo "$wifi_show" | grep -E "^Password:" | sed 's/^Password:[[:space:]]*//')

        if [[ -n "${CONFIG[wifiSsid]}" ]] && [[ -n "${CONFIG[wifiPassword]}" ]]; then
            success "Auto-detected WiFi: ${CONFIG[wifiSsid]}"
            return 0
        fi
    fi

    # Try older method
    local ssid
    ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2 || echo "")

    if [[ -n "$ssid" ]]; then
        CONFIG[wifiSsid]="$ssid"
        log "  Detected SSID: $ssid (password needed)"
    fi
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

generate_hardware_config() {
    local target_dir="$1"
    local hw_file="$target_dir/machines/${CONFIG[serial]}-hardware.nix"

    log "Generating hardware configuration..."

    local raw_config
    if raw_config=$(nixos-generate-config --show-hardware-config 2>/dev/null); then
        if [[ -n "${CONFIG[layout]:-}" ]]; then
            # Disko manages filesystems and LUKS — strip fileSystems, swapDevices,
            # and boot.initrd.luks to avoid conflicts with disko-generated definitions
            log "  Stripping fileSystems/swapDevices/LUKS (disko will manage these)"
            echo "$raw_config" | sed '/^[[:space:]]*fileSystems\./,/^[[:space:]]*};/d; /^[[:space:]]*swapDevices/d; /^[[:space:]]*boot\.initrd\.luks\./d' > "$hw_file"
        else
            echo "$raw_config" > "$hw_file"
        fi
        log "  Generated: $hw_file"
    else
        warn "  Failed to generate hardware config"
        warn "  You may need to run: sudo nixos-generate-config --show-hardware-config"
    fi
}

# ========== DISK OPERATIONS ==========

select_disk() {
    log "Available disks:"
    lsblk -d -p -o NAME,SIZE,MODEL,TYPE | grep disk
    echo ""

    read -p "Enter target disk (e.g., /dev/nvme0n1): " disk

    if [[ ! -b "$disk" ]]; then
        error "Invalid disk: $disk"
    fi

    CONFIG[device]="$disk"
    log "Selected: $disk"
}

select_layout() {
    echo ""
    log "Disk layout options:"
    echo "  1) full-disk-luks   - Full disk with LUKS encryption (recommended)"
    echo "  2) full-disk-plain  - Full disk, no encryption"
    echo "  3) dual-boot-luks   - Dual boot with LUKS encryption"
    echo "  4) dual-boot-plain  - Dual boot, no encryption"
    echo ""

    read -p "Select layout [1-4, default=1]: " choice

    case "${choice:-1}" in
        1) CONFIG[layout]="full-disk-luks" ;;
        2) CONFIG[layout]="full-disk-plain" ;;
        3) CONFIG[layout]="dual-boot-luks" ;;
        4) CONFIG[layout]="dual-boot-plain" ;;
        *) CONFIG[layout]="full-disk-luks" ;;
    esac

    log "Layout: ${CONFIG[layout]}"

    # Collect LUKS password for encrypted layouts
    if [[ "${CONFIG[layout]}" == *luks* ]]; then
        echo ""
        while true; do
            read -s -p "Enter disk encryption password: " pass1
            echo ""
            read -s -p "Confirm disk encryption password: " pass2
            echo ""

            if [[ -z "$pass1" ]]; then
                warn "Password cannot be empty"
            elif [[ "$pass1" != "$pass2" ]]; then
                warn "Passwords do not match"
            else
                CONFIG[diskPassword]="$pass1"
                log "Disk encryption password set"
                break
            fi
        done
    fi

    # Detect EFI partition for dual-boot
    if [[ "${CONFIG[layout]}" == dual-boot-* ]]; then
        echo ""
        log "Detecting existing EFI partition on ${CONFIG[device]}..."

        local detected_efi
        detected_efi=$(lsblk -n -o NAME,PARTTYPE "${CONFIG[device]}" 2>/dev/null | \
            grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print "/dev/"$1}' | head -1)

        if [[ -n "$detected_efi" ]]; then
            log "Detected EFI partition: $detected_efi"
            read -p "Use this EFI partition? [$detected_efi]: " efi_input
            CONFIG[efiPartition]="${efi_input:-$detected_efi}"
        else
            warn "No EFI partition detected automatically"
            echo "Available partitions on ${CONFIG[device]}:"
            lsblk -n -o NAME,SIZE,FSTYPE,PARTTYPE "${CONFIG[device]}"
            echo ""
            read -p "Enter EFI partition device (e.g., /dev/nvme0n1p1): " efi_input
            if [[ -z "$efi_input" ]]; then
                error "EFI partition is required for dual-boot"
            fi
            CONFIG[efiPartition]="$efi_input"
        fi

        if [[ ! -b "${CONFIG[efiPartition]}" ]]; then
            error "EFI partition ${CONFIG[efiPartition]} does not exist"
        fi

        log "EFI partition: ${CONFIG[efiPartition]}"
    fi
}

# ========== CONFIGURATION GATHERING ==========

gather_user_info() {
    echo ""
    log "=== User Configuration ==="

    while true; do
        read -p "Username [default: user]: " username
        username="${username:-user}"
        # Validate username if validation functions are available
        if type check_username &>/dev/null; then
            if check_username "$username"; then
                CONFIG[username]="$username"
                break
            fi
            # check_username returns 1 on failure, loop continues
        else
            CONFIG[username]="$username"
            break
        fi
    done

    # Machine serial identification (for config file naming)
    # Visual hostname is always "hydrix"
    echo ""
    log "Machine identifier: ${CONFIG[serial]}"
    log "  (Used for config filename - reinstalls on same hardware auto-detect this)"
    read -p "Use this identifier? [Y/n/custom]: " serial_choice
    case "${serial_choice:-y}" in
        [Nn])
            while true; do
                read -p "Enter custom identifier: " custom_serial
                if [[ -z "$custom_serial" ]]; then
                    warn "Identifier cannot be empty"
                    continue
                fi
                if type check_serial &>/dev/null && check_serial "$custom_serial"; then
                    CONFIG[serial]="$custom_serial"
                    break
                elif ! type check_serial &>/dev/null; then
                    CONFIG[serial]="$custom_serial"
                    break
                fi
            done
            ;;
        [Yy]|"")
            # Keep detected serial
            ;;
        *)
            # User entered a custom value directly
            if type check_serial &>/dev/null && check_serial "$serial_choice"; then
                CONFIG[serial]="$serial_choice"
            elif ! type check_serial &>/dev/null; then
                CONFIG[serial]="$serial_choice"
            fi
            ;;
    esac

    # Visual hostname is always "hydrix"
    CONFIG[hostname]="hydrix"
    log "Hostname (visual): ${CONFIG[hostname]}"

    # Password
    while true; do
        read -s -p "User password: " pass1
        echo ""
        read -s -p "Confirm password: " pass2
        echo ""

        if [[ "$pass1" == "$pass2" ]] && [[ -n "$pass1" ]]; then
            CONFIG[userPassword]="$pass1"
            # Clear password variables immediately after storing
            unset pass1 pass2
            break
        else
            warn "Passwords don't match or are empty"
            # Clear failed attempt
            unset pass1 pass2
        fi
    done
}

gather_locale() {
    echo ""
    log "=== Locale Configuration ==="
    echo "  1) US English (us)"
    echo "  2) Swedish (se)"
    echo "  3) German (de)"
    echo "  4) UK English (gb)"
    echo "  5) French (fr)"
    echo "  6) Custom"
    echo ""

    read -p "Select locale [1-6, default=1]: " choice

    case "${choice:-1}" in
        1)
            CONFIG[timezone]="America/New_York"
            CONFIG[locale]="en_US.UTF-8"
            CONFIG[consoleKeymap]="us"
            CONFIG[xkbLayout]="us"
            ;;
        2)
            CONFIG[timezone]="Europe/Stockholm"
            CONFIG[locale]="en_US.UTF-8"
            CONFIG[consoleKeymap]="sv-latin1"
            CONFIG[xkbLayout]="se"
            ;;
        3)
            CONFIG[timezone]="Europe/Berlin"
            CONFIG[locale]="de_DE.UTF-8"
            CONFIG[consoleKeymap]="de-latin1"
            CONFIG[xkbLayout]="de"
            ;;
        4)
            CONFIG[timezone]="Europe/London"
            CONFIG[locale]="en_GB.UTF-8"
            CONFIG[consoleKeymap]="uk"
            CONFIG[xkbLayout]="gb"
            ;;
        5)
            CONFIG[timezone]="Europe/Paris"
            CONFIG[locale]="fr_FR.UTF-8"
            CONFIG[consoleKeymap]="fr-latin1"
            CONFIG[xkbLayout]="fr"
            ;;
        6)
            read -p "Timezone [Europe/Stockholm]: " tz
            CONFIG[timezone]="${tz:-Europe/Stockholm}"
            read -p "Locale [en_US.UTF-8]: " loc
            CONFIG[locale]="${loc:-en_US.UTF-8}"
            read -p "Console keymap [us]: " km
            CONFIG[consoleKeymap]="${km:-us}"
            read -p "XKB layout [us]: " xkb
            CONFIG[xkbLayout]="${xkb:-us}"
            ;;
    esac

    log "Locale: ${CONFIG[xkbLayout]} / ${CONFIG[timezone]}"
}

gather_wifi() {
    echo ""
    log "=== WiFi Configuration ==="

    if [[ -n "${CONFIG[wifiSsid]}" ]]; then
        log "Detected SSID: ${CONFIG[wifiSsid]}"
        read -p "Use this network? [Y/n]: " use_detected

        if [[ ! "$use_detected" =~ ^[Nn]$ ]]; then
            # Validate auto-detected SSID
            if type check_wifi_ssid &>/dev/null && ! check_wifi_ssid "${CONFIG[wifiSsid]}"; then
                warn "Auto-detected SSID has invalid characters, please enter manually"
                CONFIG[wifiSsid]=""
            else
                if [[ -z "${CONFIG[wifiPassword]}" ]]; then
                    while true; do
                        read -s -p "WiFi password: " pass
                        echo ""
                        if type check_wifi_password &>/dev/null && ! check_wifi_password "$pass"; then
                            unset pass
                            continue
                        fi
                        CONFIG[wifiPassword]="$pass"
                        unset pass  # Clear password variable
                        break
                    done
                fi
                return
            fi
        fi
    fi

    # Manual SSID entry with validation
    while true; do
        read -p "WiFi SSID: " ssid
        if [[ -z "$ssid" ]]; then
            warn "Skipping WiFi configuration"
            CONFIG[wifiSsid]=""
            CONFIG[wifiPassword]=""
            return
        fi
        if type check_wifi_ssid &>/dev/null && ! check_wifi_ssid "$ssid"; then
            continue
        fi
        CONFIG[wifiSsid]="$ssid"
        break
    done

    # Password entry with validation
    while true; do
        read -s -p "WiFi password: " pass
        echo ""
        if type check_wifi_password &>/dev/null && ! check_wifi_password "$pass"; then
            unset pass
            continue
        fi
        CONFIG[wifiPassword]="$pass"
        unset pass  # Clear password variable
        break
    done
}

# ========== HYDRIX SOURCE SELECTION ==========

select_hydrix_source() {
    echo ""
    log "=== Hydrix Source Configuration ==="
    echo ""
    echo "How do you want to reference Hydrix?"
    echo ""
    echo "  [1] GitHub (recommended)"
    echo "      Always pulls latest from github:borttappat/Hydrix"
    echo "      Best for: end users, automatic updates"
    echo ""
    echo "  [2] Custom URL"
    echo "      Specify your own flake URL (fork, branch, etc.)"
    echo "      Best for: using your own fork or specific branch"
    echo ""

    read -p "Selection [1-2, default=1]: " source_choice

    case "${source_choice:-1}" in
        1)
            CONFIG[hydrixSource]="github"
            CONFIG[hydrixUrl]="github:borttappat/Hydrix"
            log "Using GitHub: github:borttappat/Hydrix"
            ;;
        2)
            configure_custom_url
            ;;
        *)
            CONFIG[hydrixSource]="github"
            CONFIG[hydrixUrl]="github:borttappat/Hydrix"
            log "Using GitHub: github:borttappat/Hydrix"
            ;;
    esac
}

configure_local_clone() {
    CONFIG[hydrixSource]="local"
    local default_path="/home/${CONFIG[username]}/Hydrix"

    echo ""
    read -p "Path to Hydrix clone [$default_path]: " clone_path
    clone_path="${clone_path:-$default_path}"
    CONFIG[hydrixLocalPath]="$clone_path"

    # The path as it will appear after reboot (without /mnt prefix)
    CONFIG[hydrixUrl]="path:$clone_path"

    # Check if we need to clone to /mnt during install
    local mnt_path="/mnt$clone_path"

    if [[ -d "$mnt_path" ]] && [[ -f "$mnt_path/flake.nix" ]]; then
        log "Found existing Hydrix clone at: $mnt_path"
    elif [[ -d "$clone_path" ]] && [[ -f "$clone_path/flake.nix" ]]; then
        # Clone exists in live environment, copy to /mnt
        log "Copying existing clone to installed system..."
        mkdir -p "$(dirname "$mnt_path")"
        cp -r "$clone_path" "$mnt_path"
    else
        echo ""
        echo "No Hydrix clone found."
        read -p "Clone from GitHub now? [Y/n]: " do_clone

        if [[ ! "$do_clone" =~ ^[Nn]$ ]]; then
            log "Cloning Hydrix to $mnt_path..."
            mkdir -p "$(dirname "$mnt_path")"
            git clone https://github.com/borttappat/Hydrix.git "$mnt_path"
            success "Hydrix cloned successfully"
        else
            warn "No local clone available - falling back to GitHub"
            CONFIG[hydrixSource]="github"
            CONFIG[hydrixUrl]="github:borttappat/Hydrix"
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
    echo "  github:youruser/Hydrix"
    echo "  github:youruser/Hydrix/branch-name"
    echo "  git+https://github.com/youruser/Hydrix.git"
    echo ""

    while true; do
        read -p "Enter flake URL: " custom_url

        if [[ -z "$custom_url" ]]; then
            warn "No URL provided - falling back to GitHub"
            CONFIG[hydrixSource]="github"
            CONFIG[hydrixUrl]="github:borttappat/Hydrix"
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

# ========== TEMPLATE COPYING ==========

copy_template_specialisations() {
    local config_dir="$1"
    log "Creating specialisations..."

    mkdir -p "$config_dir/specialisations"

    local template_dir="$SCRIPT_DIR/../templates/user-config/specialisations"

    cp -r "$template_dir"/* "$config_dir/specialisations/"
    log "  Copied from template"
}

copy_template_profiles() {
    local config_dir="$1"
    log "Creating profiles..."

    mkdir -p "$config_dir/profiles"

    local template_dir="$SCRIPT_DIR/../templates/user-config/profiles"

    cp -r "$template_dir"/* "$config_dir/profiles/"
    log "  Copied from template"
}

copy_template_shared() {
    local config_dir="$1"
    log "Creating shared config..."

    mkdir -p "$config_dir/shared"

    local template_dir="$SCRIPT_DIR/../templates/user-config/shared"

    cp -r "$template_dir"/* "$config_dir/shared/"
    log "  Copied from template"
}

copy_template_modules() {
    local config_dir="$1"
    log "Creating modules..."

    mkdir -p "$config_dir/modules"

    local template_dir="$SCRIPT_DIR/../templates/user-config/modules"

    cp -r "$template_dir"/* "$config_dir/modules/"
    log "  Copied from template"
}

copy_template_fonts() {
    local config_dir="$1"
    log "Creating font profiles..."
    mkdir -p "$config_dir/fonts"
    local template_dir="$SCRIPT_DIR/../templates/user-config/fonts"
    cp -r "$template_dir"/* "$config_dir/fonts/"
    log "  Copied from template"
}

copy_template_colorschemes() {
    local config_dir="$1"
    log "Creating colorschemes directory..."
    mkdir -p "$config_dir/colorschemes"
    local template_dir="$SCRIPT_DIR/../templates/user-config/colorschemes"
    cp -r "$template_dir"/* "$template_dir"/.[!.]* "$config_dir/colorschemes/" 2>/dev/null || true
    log "  Copied from template"
}

copy_template_readme() {
    local config_dir="$1"
    local template_dir="$SCRIPT_DIR/../templates/user-config"

    if [[ -f "$template_dir/README.md" ]]; then
        cp "$template_dir/README.md" "$config_dir/README.md"
        log "  Copied README.md from template"
    fi
}

# ========== CONFIG GENERATION AND VALIDATION ==========

generate_config_to_temp() {
    # Generate configuration to a temporary directory for validation
    # before any destructive disk operations

    TEMP_CONFIG=$(mktemp -d -t hydrix-config-XXXXXX)
    log "Generating configuration to temp directory..."

    mkdir -p "$TEMP_CONFIG/machines"
    mkdir -p "$TEMP_CONFIG/specialisations"
    mkdir -p "$TEMP_CONFIG/profiles"

    if [[ "$MODE" == "use-existing" ]] && [[ -n "$CLONED_REPO" ]]; then
        # Use existing machine config, only regenerate hardware
        log "  Using existing machine config from cloned repo..."
        cp -r "$CLONED_REPO"/* "$TEMP_CONFIG/"

        # Validate the existing config
        validate_existing_config "$TEMP_CONFIG/machines/${CONFIG[serial]}.nix"

        # Always regenerate hardware-configuration.nix
        generate_hardware_config "$TEMP_CONFIG"

    elif [[ "$MODE" == "add" ]] && [[ -n "$CLONED_REPO" ]]; then
        # Clone mode with overwrite: copy cloned repo and generate new machine config
        log "  Using cloned configuration (generating new machine config)..."
        cp -r "$CLONED_REPO"/* "$TEMP_CONFIG/"
        generate_machine_nix "$TEMP_CONFIG"
        generate_hardware_config "$TEMP_CONFIG"
    else
        # Fresh installation: generate everything
        generate_flake_nix "$TEMP_CONFIG"
        copy_template_specialisations "$TEMP_CONFIG"
        copy_template_profiles "$TEMP_CONFIG"
        copy_template_shared "$TEMP_CONFIG"
        copy_template_modules "$TEMP_CONFIG"
        copy_template_fonts "$TEMP_CONFIG"
        copy_template_colorschemes "$TEMP_CONFIG"
        copy_template_readme "$TEMP_CONFIG"
        generate_machine_nix "$TEMP_CONFIG"
        generate_hardware_config "$TEMP_CONFIG"
    fi

    success "Configuration generated to: $TEMP_CONFIG"
}

validate_generated_config() {
    # Validate the generated configuration BEFORE partitioning
    # This prevents data loss from invalid configurations

    log "Validating generated configuration..."
    echo ""

    # Step 1: Fetch flake inputs and verify outputs parse
    log "  Fetching flake inputs..."
    local lock_output
    if ! lock_output=$(nix flake lock "$TEMP_CONFIG" --refresh 2>&1); then
        echo "" >&2
        echo "==========================================" >&2
        echo "  FAILED TO FETCH FLAKE INPUTS" >&2
        echo "==========================================" >&2
        echo "" >&2
        echo "$lock_output" | grep -v '^warning: creating lock file' | head -30 >&2
        echo "" >&2
        echo "Your disk has NOT been modified." >&2
        echo "The generated config is saved at: $TEMP_CONFIG" >&2
        echo "" >&2
        echo "Common causes:" >&2
        echo "  - Invalid Hydrix URL (typo, private repo without auth)" >&2
        echo "  - Network issues fetching flake inputs" >&2
        echo "" >&2
        echo "To debug, run:" >&2
        echo "  nix flake lock $TEMP_CONFIG" >&2
        echo "" >&2
        TEMP_CONFIG=""
        exit 1
    fi
    success "  Flake inputs fetched"

    # Step 2: Evaluate the system configuration
    log "  Evaluating system configuration for ${CONFIG[serial]}..."

    # Diagnostic: check if disko is generating filesystem declarations
    local disko_check
    disko_check=$(nix eval "$TEMP_CONFIG#nixosConfigurations.${CONFIG[serial]}.config.disko.devices.disk" \
                  --no-write-lock-file 2>&1) || true
    if [[ "$disko_check" == "{ }" ]] || [[ -z "$disko_check" ]]; then
        warn "  Disko devices appear empty — fileSystems will not be generated"
        warn "  Check hydrix.vmType and hydrix.disko.* settings"
    else
        log "  Disko devices: populated"
    fi

    local eval_output
    if ! eval_output=$(nix eval "$TEMP_CONFIG#nixosConfigurations.${CONFIG[serial]}.config.system.build.toplevel" \
                       --no-write-lock-file --show-trace 2>&1); then
        echo ""
        echo "==========================================" >&2
        echo "  SYSTEM EVALUATION FAILED" >&2
        echo "==========================================" >&2
        echo "" >&2
        echo "Evaluation errors (last 80 lines):" >&2
        echo "$eval_output" | tail -80 >&2
        echo "" >&2
        echo "Your disk has NOT been modified." >&2
        echo "The generated config is saved at: $TEMP_CONFIG" >&2
        echo "" >&2
        echo "Common causes:" >&2
        echo "  - Invalid option values (typo in colorscheme, bad PCI address format)" >&2
        echo "  - Missing required options" >&2
        echo "  - Module import errors" >&2
        echo "" >&2
        echo "To debug, run:" >&2
        echo "  nix eval $TEMP_CONFIG#nixosConfigurations.${CONFIG[serial]}.config.system.build.toplevel" >&2
        echo "" >&2
        # Preserve temp dir for debugging (prevent secure_cleanup from removing it)
        TEMP_CONFIG=""
        exit 1
    fi
    success "  System evaluation: OK"

    # Step 3: Quick sanity check on microvm-router (critical for first boot)
    log "  Checking microvm-router configuration..."
    if ! nix eval "$TEMP_CONFIG#nixosConfigurations.microvm-router.config.system.build.toplevel" \
         --no-write-lock-file >/dev/null 2>&1; then
        warn "  microvm-router evaluation failed (may be expected if WiFi not configured)"
    else
        success "  microvm-router configuration: OK"
    fi

    echo ""
    success "=========================================="
    success "  Configuration validated successfully!"
    success "=========================================="
    echo ""
    echo "Your configuration has been verified:"
    echo "  ✓ Flake syntax is correct"
    echo "  ✓ Hydrix framework is accessible"
    echo "  ✓ System configuration evaluates without errors"
    echo ""
}

cleanup_temp_config() {
    # Clean up temp config directory
    if [[ -n "$TEMP_CONFIG" ]] && [[ -d "$TEMP_CONFIG" ]]; then
        rm -rf "$TEMP_CONFIG"
    fi
}

# ========== CONFIG GENERATION ==========

generate_flake_nix() {
    local config_dir="$1"
    local gen_date
    gen_date=$(date +"%Y-%m-%d %H:%M")

    # Generate source comment based on selection
    local source_comment=""
    case "${CONFIG[hydrixSource]}" in
        github)
            source_comment="# Source: GitHub (default)"
            ;;
        local)
            source_comment="# Source: Local clone at ${CONFIG[hydrixLocalPath]}"
            ;;
        custom)
            source_comment="# Source: Custom URL"
            ;;
    esac

    cat > "$config_dir/flake.nix" << FLAKE_EOF
# Hydrix User Configuration
# Generated by Hydrix installer on ${gen_date}
#
${source_comment}
# Fork support: change to github:<youruser>/Hydrix
# To change source, edit hydrix.url below and run: nix flake update
#
# Auto-discovers machines from machines/*.nix (named by hardware serial)
# Add a new machine: create machines/<serial>.nix

{
  description = "My Hydrix Machines";

  inputs = {
    hydrix.url = "${CONFIG[hydrixUrl]}";
    nixpkgs.follows = "hydrix/nixpkgs";
  };

  outputs = { self, hydrix, nixpkgs, ... }@inputs:
  let
    # Host username for builder VM to mount ~/hydrix-config
    hostUsername = "${CONFIG[username]}";

    userProfiles = ./profiles;

    # Custom colorschemes (pywal JSON format) - extend framework built-ins
    # Your schemes take priority over framework ones with the same name
    userColorschemesDir = ./colorschemes;

    # VM theme sync module (shared between host and VMs)
    vmThemeSyncModule = ./modules/vm-theme-sync.nix;

    # Host config for microVMs to inherit (username, font family, etc.)
    hostConfig = { ... }: {
      imports = [ ./shared/fonts.nix ];
      hydrix.username = hostUsername;
    };

    # WiFi PCI address for router VM (auto-detected from machine configs)
    # Override manually if needed: wifiPciAddress = "00:14.3";
    wifiPciAddress = let
      configs = builtins.attrValues machineConfigs;
      addresses = map (c: c.config.hydrix.hardware.vfio.wifiPciAddress) configs;
      nonEmpty = builtins.filter (a: a != "") addresses;
    in if nonEmpty != [] then builtins.head nonEmpty else "";

    # Auto-discover all machines from machines/*.nix
    # Excludes *-hardware.nix files (they're imported by the main machine config)
    machineConfigs = let
      machinesDir = ./machines;
      allNixFiles = builtins.filter
        (name: builtins.match ".*\\\\.nix" name != null)
        (builtins.attrNames (builtins.readDir machinesDir));
      # Filter out hardware configs (imported by machine configs, not standalone)
      machineFiles = builtins.filter
        (name: builtins.match ".*-hardware\\\\.nix" name == null)
        allNixFiles;
    in builtins.listToAttrs (map (file: {
      name = builtins.replaceStrings [ ".nix" ] [ "" ] file;
      value = hydrix.lib.mkHost {
        specialArgs = { inherit self; };
        inherit userColorschemesDir;
        modules = [
          (machinesDir + "/\${file}")
          ./shared/wifi.nix
          ./shared/fonts.nix
          ./shared/i3.nix
          vmThemeSyncModule
          { hydrix.vmThemeSync.enable = true; }
        ];
      };
    }) machineFiles);

  in {
    nixosConfigurations = machineConfigs // {
      # MicroVMs
      "microvm-browsing" = hydrix.lib.mkMicroVM {
        profile = "browsing";
        hostname = "microvm-browsing";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-pentest" = hydrix.lib.mkMicroVM {
        profile = "pentest";
        hostname = "microvm-pentest";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-dev" = hydrix.lib.mkMicroVM {
        profile = "dev";
        hostname = "microvm-dev";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-comms" = hydrix.lib.mkMicroVM {
        profile = "comms";
        hostname = "microvm-comms";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-lurking" = hydrix.lib.mkMicroVM {
        profile = "lurking";
        hostname = "microvm-lurking";
        modules = [ vmThemeSyncModule { hydrix.vmThemeSync.enable = true; } ];
        inherit userProfiles hostConfig userColorschemesDir;
      };

      "microvm-router" = hydrix.lib.mkMicrovmRouter {
        inherit wifiPciAddress;
        modules = [ ./shared/wifi.nix ];
      };
      "microvm-builder" = hydrix.lib.mkMicrovmBuilder { inherit hostUsername; };
      "microvm-gitsync" = hydrix.lib.mkMicrovmGitSync { inherit hostUsername; repos = [
        { name = "hydrix-config"; source = "/home/${CONFIG[username]}/hydrix-config"; }
      ]; };
    };

    packages.x86_64-linux = {
      vm-browsing = (hydrix.lib.mkVM { profile = "browsing"; inherit userProfiles hostConfig userColorschemesDir; }).config.system.build.image;
      vm-pentest = (hydrix.lib.mkVM { profile = "pentest"; inherit userProfiles hostConfig userColorschemesDir; }).config.system.build.image;
      vm-dev = (hydrix.lib.mkVM { profile = "dev"; inherit userProfiles hostConfig userColorschemesDir; }).config.system.build.image;
      vm-comms = (hydrix.lib.mkVM { profile = "comms"; inherit userProfiles hostConfig userColorschemesDir; }).config.system.build.image;
    };
  };
}
FLAKE_EOF

    log "Generated: $config_dir/flake.nix"
}

generate_machine_nix() {
    local config_dir="$1"
    local gen_date
    gen_date=$(date +"%Y-%m-%d %H:%M")

    # Create directories
    mkdir -p "$config_dir/machines"

    # Generate password hash
    local password_hash
    password_hash=$(echo "${CONFIG[userPassword]}" | mkpasswd -m sha-512 -s)

    # Machine config with specialisations
    # Filename is serial-based for hardware identification
    cat > "$config_dir/machines/${CONFIG[serial]}.nix" << MACHINE_EOF
# Machine Configuration
# Serial: ${CONFIG[serial]}
# Generated by Hydrix installer on ${gen_date}
#
# Config file is named by hardware serial for automatic reinstall detection.
# The visual hostname is always "hydrix".
#
# BOOT MODES:
#   DEFAULT (Lockdown):  No host internet, minimal packages, hardened
#   Administrative:      Full functionality, router VM, all packages
#   Fallback:            Emergency direct WiFi, no VMs
#
# Switch modes (rebuild script auto-detects this machine by serial):
#   rebuild                    -> Lockdown
#   rebuild administrative     -> Admin
#   rebuild fallback           -> Fallback

{ config, lib, pkgs, ... }:

{
  # =========================================================================
  # SPECIALISATIONS
  # =========================================================================
  # Base config = Lockdown (default boot mode)
  imports = [
    ./${CONFIG[serial]}-hardware.nix
    ../specialisations/lockdown.nix
  ];

  # Administrative mode - full functionality
  specialisation.administrative.configuration = {
    imports = [ ../specialisations/administrative.nix ];
  };

  # Fallback mode - emergency direct network
  specialisation.fallback.configuration = {
    imports = [ ../specialisations/fallback.nix ];
  };

  # =========================================================================
  # USER CREDENTIALS
  # =========================================================================
  users.users.${CONFIG[username]}.hashedPassword = "${password_hash}";

  # =========================================================================
  # HYDRIX CONFIGURATION
  # =========================================================================
  hydrix = {
    # System type (host machine, not a VM)
    vmType = "host";

    # Identity
    username = "${CONFIG[username]}";
    hostname = "hydrix";  # Visual hostname (config file identified by serial: ${CONFIG[serial]})
    colorscheme = "${CONFIG[colorscheme]}";

    # Locale
    locale = {
      timezone = "${CONFIG[timezone]}";
      language = "${CONFIG[locale]}";
      consoleKeymap = "${CONFIG[consoleKeymap]}";
      xkbLayout = "${CONFIG[xkbLayout]}";
      xkbVariant = "${CONFIG[xkbVariant]}";
    };

    # Disko
    disko = {
      enable = true;
      device = "${CONFIG[device]}";
      swapSize = "${CONFIG[swapSize]}";
      layout = "${CONFIG[layout]}";
    };

    # Router
    router = {
      type = "${CONFIG[routerType]}";
      autostart = true;
      wifi = {
        ssid = "${CONFIG[wifiSsid]}";
        password = "${CONFIG[wifiPassword]}";
      };
    };

    # Hardware
    hardware = {
      platform = "${CONFIG[platform]}";
      isAsus = ${CONFIG[isAsus]};
      vfio = {
        enable = true;
        pciIds = [ "${CONFIG[wifiPciId]}" ];
        wifiPciAddress = "${CONFIG[wifiPciAddress]}";
      };
      grub.gfxmodeEfi = "${CONFIG[grubGfxmode]}";
    };

    # Services
    services = {
      tailscale.enable = false;
      ssh.enable = true;
    };

    # Power
    power = {
      autoCpuFreq = true;
    };

    # Secrets
    secrets = {
      enable = false;
      github.enable = false;
    };

    # MicroVM Host
    microvmHost = {
      enable = true;
      infrastructureOnly = true;  # Removed after install — first rebuild builds all VMs
      vms = {
        "microvm-router".enable = true;
        "microvm-router".autostart = true;
        "microvm-browsing".enable = true;
        "microvm-pentest".enable = false;
        "microvm-dev".enable = false;
        "microvm-comms".enable = false;
        "microvm-lurking".enable = false;
        "microvm-builder".enable = true;
        "microvm-gitsync".enable = true;
      };
    };

    # Builder for lockdown mode
    builder.enable = true;

    # Git-sync for lockdown mode
    gitsync.enable = true;

    # Graphical
    graphical = {
      enable = true;
      font = { family = "Iosevka"; size = 10; };
      ui = { gaps = 10; floatingBar = false; polybarStyle = "unibar"; };
      scaling = { internalResolution = null; standaloneScaleFactor = 1.0; };
      # keyboard.xmodmap = ''
      #   clear lock
      #   clear control
      #   keycode 66 = Control_L
      #   add control = Control_L Control_R
      # '';
    };
  };
}
MACHINE_EOF

    log "Generated: $config_dir/machines/${CONFIG[serial]}.nix"
}

# ========== INSTALLATION ==========

partition_and_mount() {
    log "Partitioning disk with disko..."

    local layout="${CONFIG[layout]}"
    local disko_file="$SCRIPT_DIR/../disko/${layout}.nix"

    if [[ ! -f "$disko_file" ]]; then
        error "Disko layout file not found: $disko_file"
    fi

    log "Using disko layout: $layout"

    # Write LUKS password for encrypted layouts
    if [[ "$layout" == *luks* ]]; then
        echo -n "${CONFIG[diskPassword]}" > /tmp/luks-password
        chmod 600 /tmp/luks-password
        log "LUKS password written to /tmp/luks-password"
    fi

    # Build disko arguments based on layout
    local -a disko_args=(
        --arg device "\"${CONFIG[device]}\""
        --arg swapSize "\"${CONFIG[swapSize]}\""
    )

    if [[ "$layout" == dual-boot-* ]]; then
        disko_args+=(--arg efiDevice "\"${CONFIG[efiPartition]}\"")
    fi

    # Run disko
    log "Running disko..."
    nix run github:nix-community/disko -- --mode disko "${disko_args[@]}" "$disko_file"

    # Clean up LUKS password
    if [[ -f /tmp/luks-password ]]; then
        shred -u /tmp/luks-password 2>/dev/null || rm -f /tmp/luks-password
    fi

    success "Disk partitioned and mounted"
}

install_nixos() {
    local config_dir="/mnt/home/${CONFIG[username]}/hydrix-config"

    # Copy pre-validated configuration from temp directory
    # (Config was already generated and validated before partitioning)
    log "Copying validated configuration to target..."
    mkdir -p "$(dirname "$config_dir")"
    cp -r "$TEMP_CONFIG" "$config_dir"

    # Initialize/update git repo
    log "Initializing git repository..."
    (
        cd "$config_dir"
        if [[ ! -d .git ]]; then
            git init
        fi
        git -c user.name="Hydrix Installer" -c user.email="installer@hydrix" add .
        if [[ "$MODE" == "add" ]]; then
            git -c user.name="Hydrix Installer" -c user.email="installer@hydrix" commit -m "Add machine: ${CONFIG[serial]}"
        else
            git -c user.name="Hydrix Installer" -c user.email="installer@hydrix" commit -m "Initial Hydrix configuration for ${CONFIG[serial]}"
        fi
    )

    # Create user home
    mkdir -p "/mnt/home/${CONFIG[username]}"

    log "Running nixos-install..."
    local mem_gb
    mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    local max_jobs=1 cores=2
    if (( mem_gb >= 32 )); then
        max_jobs=4; cores=4
    elif (( mem_gb >= 24 )); then
        max_jobs=2; cores=4
    elif (( mem_gb >= 16 )); then
        max_jobs=2; cores=2
    fi
    log "  System has ${mem_gb}GB RAM — using --max-jobs $max_jobs --cores $cores"
    nixos-install --flake "$config_dir#${CONFIG[serial]}" --no-root-passwd \
        --max-jobs "$max_jobs" --cores "$cores"

    # Remove infrastructureOnly — first rebuild will build all enabled VMs
    log "Removing infrastructureOnly from machine config..."
    sed -i '/infrastructureOnly/d' "$config_dir/machines/${CONFIG[serial]}.nix"
    (
        cd "$config_dir"
        git -c user.name="Hydrix Installer" -c user.email="installer@hydrix" add .
        git -c user.name="Hydrix Installer" -c user.email="installer@hydrix" commit --amend --no-edit
    )

    # Fix ownership
    local uid gid
    uid=$(nixos-enter -c "id -u ${CONFIG[username]}" 2>/dev/null || echo "1000")
    gid=$(nixos-enter -c "id -g ${CONFIG[username]}" 2>/dev/null || echo "100")
    chown -R "$uid:$gid" "/mnt/home/${CONFIG[username]}"

    success "NixOS installed"

    # Pre-build essential microVMs (router, builder)
    # This ensures they're in the store and ready on first boot
    prebuild_microvms "$config_dir"
}

prebuild_microvms() {
    local config_dir="$1"

    echo ""
    log "=== Pre-building Essential MicroVMs ==="
    log "This will take some time but ensures VMs are ready on first boot..."
    echo ""

    # Check available disk space before building
    local available_gb
    available_gb=$(df /mnt --output=avail 2>/dev/null | tail -1 | awk '{print int($1/1024/1024)}')
    if [[ $available_gb -lt 20 ]]; then
        warn "Low disk space: ${available_gb}GB available (recommend 50GB+)"
        warn "MicroVM builds may fail due to insufficient space"
        echo ""
    fi

    # Critical VMs - required for lockdown mode
    local critical_vms=(
        "microvm-router:Router VM (WiFi passthrough)"
        "microvm-builder:Builder VM (lockdown mode builds)"
    )

    # Optional VMs - can be built later (empty for faster install)
    # Add "microvm-browsing:Browsing VM" here to pre-build during install
    local optional_vms=()

    local critical_failed=()
    local optional_failed=0

    # Build critical VMs first
    for vm_entry in "${critical_vms[@]}"; do
        local vm_name="${vm_entry%%:*}"
        local vm_desc="${vm_entry#*:}"

        log "Building ${vm_desc} [REQUIRED]..."

        if nix build "$config_dir#nixosConfigurations.${vm_name}.config.microvm.declaredRunner" \
            --no-link \
            --print-build-logs; then
            success "  ${vm_name} built successfully"
        else
            warn "  ${vm_name} build FAILED"
            critical_failed+=("$vm_name")
        fi
        echo ""
    done

    # Build optional VMs
    for vm_entry in "${optional_vms[@]}"; do
        local vm_name="${vm_entry%%:*}"
        local vm_desc="${vm_entry#*:}"

        log "Building ${vm_desc} [optional]..."

        if nix build "$config_dir#nixosConfigurations.${vm_name}.config.microvm.declaredRunner" \
            --no-link \
            --print-build-logs; then
            success "  ${vm_name} built successfully"
        else
            warn "  ${vm_name} build failed (can be built later)"
            ((optional_failed++))
        fi
        echo ""
    done

    # Report results
    if [[ ${#critical_failed[@]} -eq 0 ]] && [[ $optional_failed -eq 0 ]]; then
        success "All essential microVMs pre-built!"
    elif [[ ${#critical_failed[@]} -gt 0 ]]; then
        echo ""
        echo "========================================"
        echo "  WARNING: CRITICAL VM BUILD FAILURE"
        echo "========================================"
        echo ""
        echo "The following VMs failed to build:"
        for vm in "${critical_failed[@]}"; do
            echo "  - $vm"
        done
        echo ""
        echo "LOCKDOWN MODE WILL NOT WORK until these are built."
        echo ""
        echo "Common causes:"
        echo "  - Insufficient disk space (need ~50GB free, have ${available_gb}GB)"
        echo "  - Network issues during package download"
        echo "  - Insufficient memory (need ~8GB)"
        echo ""
        echo "To fix after installation:"
        echo "  1. Select 'fallback' from the boot menu (has direct WiFi)"
        echo "  2. Run: microvm build microvm-router"
        echo "  3. Run: microvm build microvm-builder"
        echo "  4. Reboot and select 'lockdown' mode"
        echo ""
        echo "========================================"
        echo ""
        read -p "Continue with installation anyway? [y/N]: " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            error "Installation aborted. Please resolve the issue and re-run."
        fi
    else
        warn "$optional_failed optional VM(s) failed - can be built after first boot"
    fi

    log "Other VMs (microvm-browsing, microvm-pentest, microvm-dev, microvm-comms, microvm-lurking) can be built on-demand:"
    log "  microvm build <name>"
}

# ========== MAIN ==========

main() {
    echo ""
    echo "=========================================="
    echo "  Hydrix Installer (Options-Driven)"
    echo "=========================================="
    echo ""

    # Ensure Hydrix source tree is available (handles curl|bash mode)
    ensure_hydrix_source

    # Disk partitioning and nixos-install require root
    if [[ $EUID -ne 0 ]]; then
        error "This installer must be run as root. Use: sudo bash $0"
    fi

    # Set up nix access tokens for private repo access under sudo
    # The original user's gh token lets nix fetch private GitHub repos
    if [[ -n "${SUDO_USER:-}" ]]; then
        local gh_token
        gh_token=$(sudo -u "$SUDO_USER" gh auth token 2>/dev/null) || true
        if [[ -n "$gh_token" ]]; then
            export NIX_CONFIG="${NIX_CONFIG:-}
access-tokens = github.com=$gh_token"
            log "Using GitHub token from $SUDO_USER for private repo access"
        fi
    fi

    # Check we have required tools
    for cmd in nix lsblk mkpasswd; do
        command_exists "$cmd" || error "Required command not found: $cmd"
    done

    # Hardware detection (needed early for display in prompts)
    detect_cpu_platform
    detect_asus
    detect_wifi_hardware
    detect_display_resolution
    detect_wifi_credentials
    detect_hardware_serial

    # User configuration (needed before config source selection)
    gather_user_info

    # Config source selection (fresh or clone)
    select_config_source

    # Continue with remaining configuration
    gather_locale
    gather_wifi

    # Only ask for Hydrix source if fresh install
    if [[ "$MODE" == "fresh" ]]; then
        select_hydrix_source
    fi

    select_disk
    select_layout

    # Show summary
    echo ""
    log "=== Installation Summary ==="
    echo "  Mode: $MODE"
    echo "  Username: ${CONFIG[username]}"
    echo "  Machine ID: ${CONFIG[serial]}"
    echo "  Hostname: ${CONFIG[hostname]} (visual)"
    if [[ "$MODE" == "fresh" ]]; then
        echo "  Hydrix:   ${CONFIG[hydrixUrl]}"
        echo "  Machine config: NEW (auto-detected)"
        echo "  Hardware config: NEW (auto-detected)"
    elif [[ "$MODE" == "use-existing" ]]; then
        echo "  Config:   cloned from existing repo"
        echo "  Machine config: EXISTING (from cloned repo)"
        echo "  Hardware config: REGENERATED (from current system)"
    else
        echo "  Config:   cloned from existing repo"
        echo "  Machine config: NEW (auto-detected, overwrites existing)"
        echo "  Hardware config: NEW (auto-detected)"
    fi
    echo "  Disk:     ${CONFIG[device]} (${CONFIG[layout]})"
    [[ "${CONFIG[layout]}" == *luks* ]] && echo "  Encryption: LUKS (password set)"
    [[ -n "${CONFIG[efiPartition]}" ]] && echo "  EFI partition: ${CONFIG[efiPartition]} (existing, not formatted)"
    echo "  Platform: ${CONFIG[platform]}"
    echo "  WiFi PCI: ${CONFIG[wifiPciAddress]}"
    echo "  Router:   ${CONFIG[routerType]}"
    echo ""

    while true; do
        read -p "Proceed with installation? [y/n]: " confirm
        case "$confirm" in
            [Yy]) break ;;
            [Nn]) error "Installation cancelled" ;;
            *) echo "Please enter y or n." ;;
        esac
    done

    # =========================================================================
    # PHASE 1: Generate and validate configuration BEFORE touching the disk
    # =========================================================================
    # This ensures we catch any configuration errors before data loss
    echo ""
    log "=== Phase 1: Configuration Generation & Validation ==="

    generate_config_to_temp
    validate_generated_config

    # If we get here, configuration is valid. Safe to proceed with disk operations.

    # =========================================================================
    # PHASE 2: Disk partitioning and NixOS installation
    # =========================================================================
    echo ""
    log "=== Phase 2: Disk Partitioning & Installation ==="
    echo ""
    log "Configuration validated. Now partitioning disk..."
    echo ""

    partition_and_mount
    install_nixos

    # Cleanup temp directories
    cleanup_temp_config
    if [[ -n "$CLONED_REPO" ]]; then
        rm -rf "$(dirname "$CLONED_REPO")"
    fi

    echo ""
    success "=========================================="
    success "  Installation Complete!"
    success "=========================================="
    echo ""
    echo "Your config is at: /home/${CONFIG[username]}/hydrix-config/"
    echo "  ├── machines/${CONFIG[serial]}.nix   (identified by hardware serial)"
    echo "  ├── profiles/"
    echo "  └── specialisations/"
    echo ""

    if [[ "$MODE" == "fresh" ]]; then
        echo "Hydrix source: ${CONFIG[hydrixUrl]}"
        echo ""
    fi

    echo "=========================================="
    echo "                 BOOT MODES              "
    echo "=========================================="
    echo "  DEFAULT (Lockdown):  No host internet, minimal, hardened"
    echo "  Administrative:      Full functionality, router VM, all pkgs"
    echo "  Fallback:            Emergency direct WiFi, no VMs"
    echo ""
    echo "  The rebuild command auto-detects this machine by hardware serial."
    echo "  Switch modes after boot:"
    echo "    rebuild                    (lockdown)"
    echo "    rebuild administrative     (admin mode)"
    echo "    rebuild fallback           (fallback mode)"
    echo "  Or select at boot from GRUB menu"
    echo "=========================================="
    echo ""

    if [[ "${CONFIG[hydrixSource]}" == "local" ]]; then
        echo "Local Hydrix clone at: ${CONFIG[hydrixLocalPath]}"
        echo "After making Hydrix changes, run:"
        echo "  nix flake update && rebuild"
        echo ""
    fi

    if [[ "$MODE" == "add" ]]; then
        echo "Other machines in your config:"
        list_existing_machines "/mnt/home/${CONFIG[username]}/hydrix-config"
        echo ""
        echo "Push your updated config to sync across machines:"
        echo "  cd ~/hydrix-config && git push"
        echo ""
    else
        echo "To add another machine to this config:"
        echo "  1. Push config to git: cd ~/hydrix-config && git remote add origin <url> && git push"
        echo "  2. On new machine: run installer and select 'Clone existing repo'"
        echo ""
    fi
}

# Brace block forces bash to buffer the entire script before executing,
# which is required when piped via curl | bash
{
    HYDRIX_LOG="/tmp/hydrix-install-$(date +%Y%m%d-%H%M%S).log"
    echo "Logging to: $HYDRIX_LOG"
    exec > >(tee -a "$HYDRIX_LOG") 2>&1
    main "$@"
    # Copy log to installed system so it survives reboot
    if [[ -d "/mnt/var/log" ]]; then
        mkdir -p /mnt/var/log/hydrix
        cp "$HYDRIX_LOG" /mnt/var/log/hydrix/
        echo "Install log saved to /var/log/hydrix/$(basename "$HYDRIX_LOG")"
    fi
}
