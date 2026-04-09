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
trap 'echo "[ERR] Script exited unexpectedly at line $LINENO (exit $?)" >&2' ERR

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
    [nixosPartition]=""
    [grubExtraEntries]=""
    [oldLuksDevs]=""
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
    [colorscheme]="puccy"
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
    local _gh_check_cmd="gh"
    [[ -n "${SUDO_USER:-}" ]] && _gh_check_cmd="sudo -u $SUDO_USER gh"
    if command_exists gh || (eval "$_gh_check_cmd auth status" &>/dev/null 2>&1); then
        echo "  1) GitHub CLI (gh auth login) - recommended"
    else
        echo "  1) GitHub CLI - not installed (run: nix-shell -p gh, then gh auth login)"
    fi
    echo "  2) Personal Access Token (type or paste)"
    echo "  3) SSH key"
    echo "  4) Read token from file (e.g. USB drive)"
    echo "  5) Skip - proceed with fresh installation"
    echo ""
    read -p "Select authentication method [1-5]: " auth_choice
    echo "$auth_choice"
}

authenticate_gh_cli() {
    # Detect graphical environment — present on GUI live ISOs (GNOME etc.)
    local has_gui=false
    if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        has_gui=true
    fi

    # Under sudo, authenticate as the original user so they get browser access
    # and their existing gh config. After auth we extract a token for git.
    local gh_cmd="gh"
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        if sudo -u "$SUDO_USER" which gh &>/dev/null 2>&1; then
            gh_cmd="sudo -u $SUDO_USER gh"
        fi
    fi

    if ! command_exists gh && [[ "$gh_cmd" == "gh" ]]; then
        warn "GitHub CLI not installed"
        echo ""
        echo "Open a second terminal and run:"
        echo "  nix-shell -p gh"
        echo "  gh auth login"
        echo ""
        echo "Then return here and press Enter to retry."
        read -p "" _
        # Re-check after user authenticates externally
        if command_exists gh && gh auth status &>/dev/null 2>&1; then
            return 0
        fi
        if [[ -n "${SUDO_USER:-}" ]] && sudo -u "$SUDO_USER" gh auth status &>/dev/null 2>&1; then
            gh_cmd="sudo -u $SUDO_USER gh"
            return 0
        fi
        return 1
    fi

    log "Authenticating with GitHub CLI..."
    if $has_gui; then
        echo "  A browser window will open for authentication."
        $gh_cmd auth login --hostname github.com --git-protocol https --web
    else
        echo ""
        echo "  No graphical display detected. Inside the gh prompt you can:"
        echo "    - Select 'Login with a web browser' — gh shows a one-time code;"
        echo "      open github.com/login/device on any device (phone, another machine)"
        echo "    - Select 'Paste an authentication token'"
        echo "      generate one at: github.com/settings/tokens  (scope: repo)"
        echo ""
        $gh_cmd auth login --hostname github.com --git-protocol https
    fi
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
            # GitHub CLI — after auth, extract token so clone works under root
            if authenticate_gh_cli; then
                local gh_token
                if [[ -n "${SUDO_USER:-}" ]]; then
                    gh_token=$(sudo -u "$SUDO_USER" gh auth token 2>/dev/null) || true
                else
                    gh_token=$(gh auth token 2>/dev/null) || true
                fi
                if [[ -n "$gh_token" ]]; then
                    local token_url
                    token_url=$(convert_to_token_url "$repo_url" "$gh_token")
                    unset gh_token
                    log "Retrying clone with gh token..."
                    if git clone "$token_url" "$dest_dir" 2>&1; then
                        unset token_url
                        return 0
                    fi
                    unset token_url
                else
                    log "Retrying clone with gh auth..."
                    if git clone "$repo_url" "$dest_dir" 2>&1; then
                        return 0
                    fi
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
            unset token
            log "Retrying clone with token..."
            if git clone "$token_url" "$dest_dir" 2>&1; then
                unset token_url
                return 0
            fi
            unset token_url
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
        4)
            # Read token from file (e.g. USB drive)
            echo ""
            read -p "Path to token file: " token_file
            if [[ ! -f "$token_file" ]]; then
                warn "File not found: $token_file"
                return 1
            fi
            local file_token
            file_token=$(tr -d '[:space:]' < "$token_file")
            if [[ -z "$file_token" ]]; then
                warn "Token file is empty"
                return 1
            fi
            local token_url
            token_url=$(convert_to_token_url "$repo_url" "$file_token")
            unset file_token
            log "Retrying clone with token from file..."
            if git clone "$token_url" "$dest_dir" 2>&1; then
                unset token_url
                return 0
            fi
            unset token_url
            warn "Token authentication failed"
            return 1
            ;;
        5|*)
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
    echo "  2) Clone existing hydrix-config repo (from git remote)"
    echo "  3) Use local hydrix-config directory (e.g. USB drive, reinstall)"
    echo ""
    read -p "Select [1-3, default=1]: " config_choice

    case "${config_choice:-1}" in
        2)
            clone_existing_repo
            ;;
        3)
            use_local_repo
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

detect_usb_mounts() {
    # Return a list of likely removable/external media mount points.
    # Sources: udisks2 automounts (/run/media), legacy (/media),
    # and /proc/mounts for any /dev/sd[b-z] that isn't a system path.
    local -a mounts=()

    # udisks2 automount (GNOME live ISOs)
    if [[ -d /run/media ]]; then
        while IFS= read -r -d '' mp; do
            [[ -d "$mp" ]] && mounts+=("$mp")
        done < <(find /run/media -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
    fi

    # Legacy automount
    if [[ -d /media ]]; then
        while IFS= read -r -d '' mp; do
            [[ -d "$mp" ]] && mounts+=("$mp")
        done < <(find /media -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null)
    fi

    # /proc/mounts — external drives mounted manually (skip sda = install target)
    while IFS=' ' read -r dev mp _rest; do
        [[ "$dev" =~ ^/dev/sd[b-z] ]] || continue
        [[ "$mp" == /boot* ]] || [[ "$mp" == /nix* ]] || [[ "$mp" == /run/media* ]] && continue
        [[ -d "$mp" ]] && mounts+=("$mp")
    done < /proc/mounts

    # Deduplicate and print
    printf '%s\n' "${mounts[@]}" | sort -u
}

use_local_repo() {
    echo ""
    log "=== Use Local hydrix-config ==="
    echo ""

    local config_path=""

    # Try to detect removable media
    local -a usb_mounts=()
    mapfile -t usb_mounts < <(detect_usb_mounts)

    if [[ ${#usb_mounts[@]} -gt 0 ]]; then
        echo "Detected removable media:"
        local i
        for i in "${!usb_mounts[@]}"; do
            echo "  $((i+1))) ${usb_mounts[$i]}"
        done
        echo "  $((${#usb_mounts[@]}+1))) Enter path manually"
        echo ""
        read -p "Select [1-$((${#usb_mounts[@]}+1))]: " media_choice

        if [[ "$media_choice" =~ ^[0-9]+$ ]] \
            && [[ "$media_choice" -ge 1 ]] \
            && [[ "$media_choice" -le "${#usb_mounts[@]}" ]]; then
            local mount="${usb_mounts[$((media_choice-1))]}"
            # Look for hydrix-config in common locations on the mount
            if [[ -d "$mount/hydrix-config/machines" ]]; then
                config_path="$mount/hydrix-config"
            elif [[ -d "$mount/machines" ]]; then
                config_path="$mount"
            else
                echo ""
                read -p "Path to hydrix-config within $mount (leave blank for root): " subpath
                config_path="$mount/${subpath#/}"
            fi
        fi
    fi

    if [[ -z "$config_path" ]]; then
        read -p "Full path to hydrix-config directory: " config_path
    fi

    if [[ -z "$config_path" ]]; then
        warn "No path provided - proceeding with fresh installation"
        MODE="fresh"
        return
    fi

    if [[ ! -d "$config_path/machines" ]]; then
        warn "Invalid hydrix-config at '$config_path' (missing machines/) - proceeding with fresh installation"
        MODE="fresh"
        return
    fi

    # Copy to temp dir so the config is available after USB is unmounted
    local temp_dir
    temp_dir=$(mktemp -d)
    log "Copying configuration from $config_path..."
    cp -r "$config_path/." "$temp_dir/hydrix-config"

    success "Configuration loaded from local path"
    list_existing_machines "$temp_dir/hydrix-config"

    CLONED_REPO="$temp_dir/hydrix-config"

    # Same machine-serial detection as clone_existing_repo
    if [[ -f "$CLONED_REPO/machines/${CONFIG[serial]}.nix" ]]; then
        log "Machine '${CONFIG[serial]}' already exists in config"
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
        log "Scanning ${CONFIG[device]} for existing EFI partition..."

        local detected_efi
        detected_efi=$(lsblk -rn -o NAME,PARTTYPE "${CONFIG[device]}" 2>/dev/null | \
            grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print "/dev/"$1}' | head -1) || true

        if [[ -n "$detected_efi" ]]; then
            log "Found EFI partition: $detected_efi"
            echo ""
            echo "  This partition will be reused as /boot alongside the existing OS."
            echo "  It will NOT be reformatted."
            echo ""
            read -p "Use $detected_efi as /boot? [Y/n]: " efi_input </dev/tty
            efi_input="${efi_input:-y}"
            if [[ "${efi_input,,}" == "y" ]]; then
                CONFIG[efiPartition]="$detected_efi"
            else
                read -p "Enter EFI partition to use (e.g. /dev/nvme0n1p1): " efi_input </dev/tty
                [[ -z "$efi_input" ]] && error "EFI partition is required"
                [[ -b "$efi_input" ]] || error "$efi_input is not a block device"
                CONFIG[efiPartition]="$efi_input"
            fi
        else
            echo ""
            warn "No EFI partition found on ${CONFIG[device]}."
            echo ""
            echo "  Current partitions:"
            lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "${CONFIG[device]}" 2>/dev/null || true
            echo ""
            echo "  This is normal for full-disk Linux installs, BIOS systems, or fresh disks."
            echo "  A 512MB EFI partition will be created automatically in the freed space."
            echo "  (If you DO have an EFI partition on a different disk, enter it below.)"
            echo ""
            read -p "Enter existing EFI partition, or press Enter to create a new one: " efi_input </dev/tty
            if [[ -n "$efi_input" ]]; then
                [[ -b "$efi_input" ]] || error "$efi_input is not a block device"
                CONFIG[efiPartition]="$efi_input"
            fi
            # efiPartition stays empty → prepare_dual_boot_space will create one
        fi

        log "EFI partition: ${CONFIG[efiPartition]:-'(will be created)'}"

        # Show disk layout and offer to shrink an existing partition if needed
        prepare_dual_boot_space

        # After partition creation, generate GRUB menu entries for any remaining
        # encrypted partitions (other OS installs the user may want to boot into).
        _detect_existing_os_entries
    fi
}

# Scan for LUKS partitions that are neither the new NixOS partition nor the EFI
# partition and record them for _finalize_dual_boot_entries, which runs after
# partition_and_mount when the EFI is mounted and can extract the actual kernel
# files.  No GRUB entries are generated here — writing placeholder entries that
# reference files which may not exist causes broken boot entries in GRUB.
_detect_existing_os_entries() {
    local device="${CONFIG[device]}"
    local devname="${device##*/}"
    local sector_size
    sector_size=$(cat "/sys/class/block/$devname/queue/logical_block_size" 2>/dev/null || echo 512)

    for part_sys in "/sys/class/block/$devname/"/*/; do
        local part_name="${part_sys%/}"; part_name="${part_name##*/}"
        [[ "$part_name" == "${devname}"* ]] || continue
        [[ -f "${part_sys}partition" ]] || continue
        local devpath="/dev/$part_name"
        [[ -b "$devpath" ]] || continue
        # Skip the partitions we just created
        [[ "$devpath" == "${CONFIG[nixosPartition]}" ]] && continue
        [[ "$devpath" == "${CONFIG[efiPartition]}" ]] && continue

        # Use cryptsetup isLuks — more reliable than blkid in live environments
        cryptsetup isLuks "$devpath" 2>/dev/null || continue

        # Get LUKS UUID — try blkid first, fall back to cryptsetup luksDump
        local uuid uuid_nodash
        uuid=$(timeout 10 blkid -o value -s UUID "$devpath" 2>/dev/null || true)
        if [[ -z "$uuid" ]]; then
            uuid=$(cryptsetup luksDump "$devpath" 2>/dev/null | awk '/^UUID:/ {print $2}' || true)
        fi
        [[ -z "$uuid" ]] && continue
        uuid_nodash="${uuid//-/}"

        local part_sectors size_gb
        part_sectors=$(cat "${part_sys}size" 2>/dev/null || echo 0)
        size_gb=$(( part_sectors * sector_size / 1073741824 ))

        log "Found existing encrypted partition: $devpath ($size_gb GB, UUID $uuid)"

        # Record for _finalize_dual_boot_entries (runs after partition_and_mount).
        CONFIG[oldLuksDevs]+="$devpath:$uuid:$uuid_nodash "
    done
}

# Called after partition_and_mount, when the old EFI content is accessible at
# /mnt/boot. Builds GRUB entries for every previous install without any
# GRUB-level crypto, so Argon2id and PBKDF2 LUKS issues are irrelevant:
#
# Plain previous installs (and new-installer LUKS installs whose kernels are
# already on the EFI):
#   - Copy /boot/kernels/ → /boot/old-nixos/kernels/ (survives nixos-install cleanup)
#   - Save a rewritten grub.cfg to /boot/old-nixos/grub.cfg
#   - One `configfile` entry gives the full old menu (all specialisations,
#     all generations); press Escape to return to the top-level menu.
#
# Old-installer LUKS installs (kernels are inside the LUKS container):
#   - Detected by `cryptomount` lines in the old grub.cfg referencing a known UUID
#   - Prompt for the LUKS passphrase, open the container, mount the BTRFS @
#     subvolume, copy kernel+initrd out to /boot/old-nixos/<uuid_short>/
#   - Generate a standalone EFI-based entry; the preserved initrd handles LUKS
#     decryption (Argon2id fully supported there)
_finalize_dual_boot_entries() {
    [[ "${CONFIG[layout]}" == dual-boot-* ]] || return

    local grub_cfg="/mnt/boot/grub/grub.cfg"
    local efi_uuid
    efi_uuid=$(blkid -o value -s UUID "${CONFIG[efiPartition]}" 2>/dev/null || true)
    if [[ -z "$efi_uuid" ]]; then
        # blkid cache may be stale immediately after mount — probe the device directly
        efi_uuid=$(blkid --probe -o value -s UUID "${CONFIG[efiPartition]}" 2>/dev/null || true)
    fi
    if [[ -z "$efi_uuid" ]]; then
        warn "_finalize_dual_boot_entries: cannot determine EFI UUID — previous install will not appear in GRUB menu"
        generate_grub_entries_nix "$TEMP_CONFIG"
        return
    fi

    local new_entries=""

    # --- Old-installer LUKS: extract kernel/initrd from inside the container ---
    # Identified by a cryptomount line in the old grub.cfg that matches a known
    # LUKS UUID. The kernel cmdline is taken from the corresponding linux line in
    # the old grub.cfg (it already contains rd.luks.uuid= / root= / rootflags=).
    if [[ -n "${CONFIG[oldLuksDevs]:-}" && -f "$grub_cfg" ]]; then
        for entry in ${CONFIG[oldLuksDevs]}; do
            local devpath="${entry%%:*}"
            local rest="${entry#*:}"
            local uuid="${rest%%:*}"
            local uuid_nodash="${rest#*:}"
            local uuid_short="${uuid:0:8}"

            grep -q "cryptomount.*$uuid_nodash\|cryptomount.*$uuid" "$grub_cfg" || continue

            # Kernel cmdline: the linux line in the old grub.cfg has the full set
            # of parameters (rd.luks.uuid=, root=, rootfstype=, etc.).  Strip the
            # command name and kernel path; keep everything after.
            local linux_line kernel_cmdline
            linux_line=$(grep -m1 '^\s*linux ' "$grub_cfg" | sed 's/^\s*//')
            kernel_cmdline=$(awk '{$1=$2=""; sub(/^ +/,""); print}' <<< "$linux_line")

            echo ""
            log "LUKS partition $devpath: kernel is inside the container — extracting to EFI."
            echo "  Enter the passphrase for this partition to allow extraction."
            echo ""

            local pass tmpkey mapper mntpoint
            tmpkey=$(mktemp); chmod 600 "$tmpkey"
            while true; do
                read -s -p "  Passphrase for $devpath: " pass </dev/tty; echo
                printf '%s' "$pass" > "$tmpkey"
                cryptsetup open --test-passphrase --key-file "$tmpkey" "$devpath" 2>/dev/null \
                    && break
                warn "  Incorrect passphrase — try again"
            done

            mapper="hydrix-extract-$$"
            mntpoint=$(mktemp -d)

            if cryptsetup open --key-file "$tmpkey" "$devpath" "$mapper" 2>/dev/null; then
                if mount -t btrfs -o subvol=@,ro /dev/mapper/"$mapper" "$mntpoint" 2>/dev/null; then
                    local dest="/mnt/boot/old-nixos/$uuid_short"
                    mkdir -p "$dest"
                    # system/kernel and system/initrd are symlinks into /nix/store
                    if cp -L "$mntpoint/nix/var/nix/profiles/system/kernel" "$dest/vmlinuz" 2>/dev/null \
                    && cp -L "$mntpoint/nix/var/nix/profiles/system/initrd"  "$dest/initrd"  2>/dev/null; then
                        log "Extracted kernel/initrd for $devpath → /old-nixos/$uuid_short/"
                        new_entries+="menuentry 'Previous NixOS - LUKS ($devpath)' {\n"
                        new_entries+="  insmod part_gpt\n"
                        new_entries+="  insmod fat\n"
                        new_entries+="  search --no-floppy --fs-uuid --set=root $efi_uuid\n"
                        new_entries+="  linux /old-nixos/$uuid_short/vmlinuz $kernel_cmdline\n"
                        new_entries+="  initrd /old-nixos/$uuid_short/initrd\n"
                        new_entries+="}\n"
                    else
                        warn "Failed to copy kernel/initrd from $devpath — no entry generated"
                    fi
                    umount "$mntpoint" 2>/dev/null || true
                else
                    warn "Failed to mount BTRFS @ subvolume from $devpath"
                fi
                cryptsetup close "$mapper" 2>/dev/null || true
            else
                warn "Failed to open LUKS container $devpath"
            fi

            rm -rf "$mntpoint"
            shred -u "$tmpkey" 2>/dev/null || true
            pass=""
        done
    fi

    # --- Previous Hydrix/NixOS install: kernels are already on the EFI partition ---
    #
    # Strategy (two-tier):
    #
    #  Tier 1 — direct entry (zero EFI writes, always possible):
    #    Parse the old grub.cfg for the first linux/initrd pair and create a
    #    direct GRUB entry.  The kernel files are already at /kernels/ on the
    #    EFI; no copying needed.  Risk: NixOS's bootloader activation step
    #    removes kernel files it doesn't recognise, so these paths may vanish
    #    after the first `rebuild` of this new install.
    #
    #  Tier 2 — configfile (EFI writes, survives GC):
    #    If the EFI has enough free space, copy all kernel files to
    #    /old-nixos/kernels/ (which NixOS's GC never touches) and write a
    #    path-rewritten grub.cfg there.  If this succeeds, upgrade the entry
    #    to a configfile that exposes the full old menu (all generations,
    #    all specialisations).
    #
    #  Third-or-later install: /old-nixos/ already exists from the previous
    #    dual-boot install — just chain the existing grub.cfg.

    if [[ -f "$grub_cfg" ]]; then
        # Detect whether this is a NixOS EFI-kernel install
        local _has_kernels_path _has_old_nixos_path
        grep -qE '^\s*linux\s+/kernels/'     "$grub_cfg" 2>/dev/null && _has_kernels_path=true  || _has_kernels_path=false
        grep -qE '^\s*linux\s+/old-nixos/'   "$grub_cfg" 2>/dev/null && _has_old_nixos_path=true || _has_old_nixos_path=false

        if [[ "$_has_kernels_path" == true || "$_has_old_nixos_path" == true ]]; then
            log "Found previous Hydrix/NixOS install on EFI — generating boot entries"

            # --- Tier 1: direct entry (no copies needed) ---
            local _linux_line _initrd_line
            _linux_line=$(grep  -m1 -E '^\s*linux\s+/(kernels|old-nixos)/' "$grub_cfg" 2>/dev/null || true)
            _initrd_line=$(grep -m1 -E '^\s*initrd\s+/(kernels|old-nixos)/' "$grub_cfg" 2>/dev/null || true)

            local _direct_entry=""
            if [[ -n "$_linux_line" && -n "$_initrd_line" ]]; then
                local _kpath _kcmd _ipath
                _kpath=$(awk '{print $2}' <<< "$_linux_line")
                _kcmd=$(awk '{$1=$2=""; sub(/^[[:space:]]+/,""); print}' <<< "$_linux_line")
                _ipath=$(awk '{print $2}' <<< "$_initrd_line")
                log "  Default kernel: $_kpath"
                _direct_entry="menuentry 'Previous Hydrix/NixOS Install' {\n"
                _direct_entry+="  insmod part_gpt\n"
                _direct_entry+="  insmod fat\n"
                _direct_entry+="  search --no-floppy --fs-uuid --set=root $efi_uuid\n"
                _direct_entry+="  linux $_kpath $_kcmd\n"
                _direct_entry+="  initrd $_ipath\n"
                _direct_entry+="}\n"
            fi

            # --- Tier 2: configfile (full menu, GC-safe) ---
            local _configfile_entry=""
            if [[ "$_has_old_nixos_path" == true && -f "/mnt/boot/old-nixos/grub.cfg" ]]; then
                # Third-or-later install: /old-nixos/ already set up
                log "  Third-or-later install — chaining existing /old-nixos/grub.cfg"
                _configfile_entry="menuentry 'Previous Hydrix/NixOS Install (full menu \xe2\x86\x92)' {\n"
                _configfile_entry+="  insmod part_gpt\n"
                _configfile_entry+="  insmod fat\n"
                _configfile_entry+="  search --no-floppy --fs-uuid --set=root $efi_uuid\n"
                _configfile_entry+="  configfile /old-nixos/grub.cfg\n"
                _configfile_entry+="}\n"

            elif [[ "$_has_kernels_path" == true ]]; then
                # First dual-boot: try to copy kernels + write rewritten grub.cfg
                if mkdir -p "/mnt/boot/old-nixos/kernels" 2>/dev/null \
                && sed 's| /kernels/| /old-nixos/kernels/|g' \
                       "$grub_cfg" > "/mnt/boot/old-nixos/grub.cfg" 2>/dev/null; then
                    # Copy each referenced kernel file individually (ignore failures)
                    local _kf _kname
                    while IFS= read -r _kf; do
                        _kname="${_kf##*/}"
                        [[ -f "/mnt/boot/kernels/$_kname" ]] && \
                            cp "/mnt/boot/kernels/$_kname" "/mnt/boot/old-nixos/kernels/$_kname" 2>/dev/null || true
                    done < <(grep -oE '/kernels/[^[:space:]]+' "$grub_cfg" | sort -u)
                    log "  Kernels preserved to /old-nixos/kernels/ (GC-safe)"
                    _configfile_entry="menuentry 'Previous Hydrix/NixOS Install (full menu \xe2\x86\x92)' {\n"
                    _configfile_entry+="  insmod part_gpt\n"
                    _configfile_entry+="  insmod fat\n"
                    _configfile_entry+="  search --no-floppy --fs-uuid --set=root $efi_uuid\n"
                    _configfile_entry+="  configfile /old-nixos/grub.cfg\n"
                    _configfile_entry+="}\n"
                else
                    warn "  EFI write failed (full or read-only) — using direct entry"
                    warn "  Note: this entry references /kernels/ which may be cleaned up on first rebuild"
                fi
            fi

            # Prefer configfile (full menu) over direct entry; fall back to direct
            if [[ -n "$_configfile_entry" ]]; then
                new_entries+="$_configfile_entry"
            elif [[ -n "$_direct_entry" ]]; then
                new_entries+="$_direct_entry"
            else
                warn "  Could not generate any entry for previous NixOS install"
            fi
        fi
    fi

    # --- EFI chainload entries for non-NixOS OSes (Ubuntu, Windows, etc.) ---
    # Scan /EFI/ for subdirectories that contain an EFI binary and generate a
    # chainload entry for each. This works regardless of whether the OS uses
    # encryption — we just hand control to its own EFI bootloader and let it
    # handle everything from there (LUKS prompt, kernel, the lot).
    #
    # Preference order for EFI binary: shim (Secure Boot) > grub > anything else.
    # Checks one subdirectory level deep so Microsoft/Boot/bootmgfw.efi is found.
    if [[ -d "/mnt/boot/EFI" ]]; then
        declare -A _efi_labels=(
            [ubuntu]="Ubuntu"           [microsoft]="Windows"
            [fedora]="Fedora"           [arch]="Arch Linux"
            [manjaro]="Manjaro"         [opensuse]="openSUSE"
            [debian]="Debian"           [linuxmint]="Linux Mint"
            [pop]="Pop!_OS"             [elementary]="elementary OS"
            [steamos]="SteamOS"         [garuda]="Garuda Linux"
            [endeavouros]="EndeavourOS" [cachyos]="CachyOS"
            [zorin]="Zorin OS"          [kali]="Kali Linux"
            [parrot]="Parrot OS"
        )

        for efi_subdir in /mnt/boot/EFI/*/; do
            [[ -d "$efi_subdir" ]] || continue
            local dn; dn="${efi_subdir%/}"; dn="${dn##*/}"
            local dn_lower="${dn,,}"

            # Skip generic fallback, NixOS (handled above), and the new Hydrix install
            [[ "$dn_lower" == "boot" ]]   && continue
            [[ "$dn_lower" == "nixos" ]]  && continue
            [[ "$dn_lower" == hydrix* ]]  && continue

            # Find the best EFI binary at this level, then one level deeper
            local efi_bin=""
            for _c in \
                    "$efi_subdir"shim*.efi  "$efi_subdir"Shim*.efi \
                    "$efi_subdir"grub*.efi  "$efi_subdir"Grub*.efi \
                    "$efi_subdir"boot*.efi  "$efi_subdir"Boot*.efi \
                    "$efi_subdir"*.efi      "$efi_subdir"*.EFI \
                    "$efi_subdir"*/shim*.efi "$efi_subdir"*/Shim*.efi \
                    "$efi_subdir"*/grub*.efi "$efi_subdir"*/Grub*.efi \
                    "$efi_subdir"*/boot*.efi "$efi_subdir"*/Boot*.efi \
                    "$efi_subdir"*/*.efi     "$efi_subdir"*/*.EFI; do
                [[ -f "$_c" ]] && { efi_bin="$_c"; break; }
            done
            [[ -n "$efi_bin" ]] || continue

            local rel_path="${efi_bin#/mnt/boot}"
            local label="${_efi_labels[$dn_lower]:-${dn^}}"

            log "Found EFI binary for $label: $rel_path"

            new_entries+="menuentry '$label' {\n"
            new_entries+="  insmod part_gpt\n"
            new_entries+="  insmod fat\n"
            new_entries+="  insmod chain\n"
            new_entries+="  search --no-floppy --fs-uuid --set=root $efi_uuid\n"
            new_entries+="  chainloader $rel_path\n"
            new_entries+="}\n"
        done
        unset _efi_labels
    fi

    CONFIG[grubExtraEntries]="$(printf '%b' "$new_entries")"
    generate_grub_entries_nix "$TEMP_CONFIG"
    log "Finalized dual-boot GRUB entries in temp config"
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

    # Populate common.nix with locale settings detected by installer
    sed -i \
        -e "s|@TIMEZONE@|${CONFIG[timezone]}|g" \
        -e "s|@LOCALE@|${CONFIG[locale]}|g" \
        -e "s|@CONSOLE_KEYMAP@|${CONFIG[consoleKeymap]}|g" \
        -e "s|@XKB_LAYOUT@|${CONFIG[xkbLayout]}|g" \
        -e "s|@XKB_VARIANT@|${CONFIG[xkbVariant]}|g" \
        "$config_dir/shared/common.nix"

    # Populate wifi.nix with actual credentials from installer
    if [[ -n "${CONFIG[wifiSsid]}" ]]; then
        cat > "$config_dir/shared/wifi.nix" << 'WIFI_HEADER'
# WiFi Configuration - Shared across all machines
#
# This file is read by router VMs during build.
# Update these credentials to connect to your network.
#
# IMPORTANT: If using a private git repo, this is safe to commit.
# If using a public repo, consider using sops-nix for encryption.

{ config, lib, pkgs, ... }:

{
WIFI_HEADER
        cat >> "$config_dir/shared/wifi.nix" << WIFI_BODY
  hydrix.router.wifi = {
    ssid = "${CONFIG[wifiSsid]}";
    password = "${CONFIG[wifiPassword]}";
  };
}
WIFI_BODY
        log "  WiFi credentials written to shared/wifi.nix"
    fi

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

copy_template_templates() {
    local config_dir="$1"
    log "Creating templates..."
    mkdir -p "$config_dir/templates"
    local template_dir="$SCRIPT_DIR/../templates/user-config/templates"
    cp -r "$template_dir"/* "$config_dir/templates/"
    log "  Copied from template (new-profile reads these)"
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

copy_wallpapers() {
    local home_dir="$1"
    log "Setting up wallpapers..."
    mkdir -p "$home_dir/wallpapers"
    # Copy wallpapers from Hydrix repo (bundled in nix store or local clone)
    local hydrix_wp="$SCRIPT_DIR/../wallpapers"
    if [[ -d "$hydrix_wp" ]] && ls "$hydrix_wp"/*.{png,jpg} &>/dev/null; then
        cp "$hydrix_wp"/*.png "$hydrix_wp"/*.jpg "$home_dir/wallpapers/" 2>/dev/null || true
        local count
        count=$(ls "$home_dir/wallpapers/" 2>/dev/null | wc -l)
        log "  Copied $count wallpaper(s) from Hydrix"
    else
        log "  Created $home_dir/wallpapers/ (add wallpapers here)"
    fi
}

copy_template_configs() {
    local config_dir="$1"
    log "Creating configs directory..."
    mkdir -p "$config_dir/configs"
    local template_dir="$SCRIPT_DIR/../templates/user-config/configs"
    cp -r "$template_dir"/. "$config_dir/configs/"
    log "  Copied program configs from template"
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
        copy_template_templates "$TEMP_CONFIG"
        copy_template_fonts "$TEMP_CONFIG"
        copy_template_colorschemes "$TEMP_CONFIG"
        copy_template_configs "$TEMP_CONFIG"
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

    local template_file="$SCRIPT_DIR/../templates/user-config/flake.nix"
    if [[ ! -f "$template_file" ]]; then
        error "flake.nix template not found: $template_file"
    fi

    sed \
        -e "s|@USERNAME@|${CONFIG[username]}|g" \
        -e "s|@HYDRIX_URL@|${CONFIG[hydrixUrl]}|g" \
        "$template_file" > "$config_dir/flake.nix"

    log "Generated: $config_dir/flake.nix"
}

generate_machine_nix() {
    local config_dir="$1"
    local gen_date
    gen_date=$(date +"%Y-%m-%d %H:%M")

    mkdir -p "$config_dir/machines"

    local password_hash
    password_hash=$(echo "${CONFIG[userPassword]}" | mkpasswd -m sha-512 -s)

    local template_file="$SCRIPT_DIR/../templates/user-config/machines/installer.nix"
    if [[ ! -f "$template_file" ]]; then
        error "Machine installer template not found: $template_file"
    fi

    # First pass: single-line substitutions via sed
    # Second pass: grubExtraEntries via awk (supports multiline content)
    sed \
        -e "s|@SERIAL@|${CONFIG[serial]}|g" \
        -e "s|@DATE@|${gen_date}|g" \
        -e "s|@USERNAME@|${CONFIG[username]}|g" \
        -e "s|@PASSWORD_HASH@|${password_hash}|g" \
        -e "s|@COLORSCHEME@|${CONFIG[colorscheme]}|g" \
        -e "s|@DEVICE@|${CONFIG[device]}|g" \
        -e "s|@SWAP_SIZE@|${CONFIG[swapSize]}|g" \
        -e "s|@LAYOUT@|${CONFIG[layout]}|g" \
        -e "s|@EFI_PARTITION@|${CONFIG[efiPartition]}|g" \
        -e "s|@NIXOS_PARTITION@|${CONFIG[nixosPartition]}|g" \
        -e "s|@ROUTER_TYPE@|${CONFIG[routerType]}|g" \
        -e "s|@PLATFORM@|${CONFIG[platform]}|g" \
        -e "s|@IS_ASUS@|${CONFIG[isAsus]}|g" \
        -e "s|@WIFI_PCI_ID@|${CONFIG[wifiPciId]}|g" \
        -e "s|@WIFI_PCI_ADDRESS@|${CONFIG[wifiPciAddress]}|g" \
        -e "s|@GRUB_GFXMODE@|${CONFIG[grubGfxmode]}|g" \
        "$template_file" > "$config_dir/machines/${CONFIG[serial]}.nix"

    # Write GRUB extra entries as a separate Nix file to avoid quoting issues
    generate_grub_entries_nix "$config_dir"

    log "Generated: $config_dir/machines/${CONFIG[serial]}.nix"
}

# Write machines/grub-entries.nix with chainboot entries for existing encrypted OSes.
# Using a separate file avoids Nix string quoting issues that arise from substituting
# GRUB stanzas (which contain double quotes) directly into a template.
generate_grub_entries_nix() {
    local config_dir="$1"
    local outfile="$config_dir/machines/grub-entries.nix"

    if [[ -z "${CONFIG[grubExtraEntries]}" ]]; then
        # No entries — write an empty module so the import still resolves
        printf '{ ... }: {}\n' > "$outfile"
        return
    fi

    # Nix ''...'' strings allow double quotes without escaping, so write the
    # entries verbatim inside that string literal.
    {
        printf '{ ... }:\n'
        printf '{\n'
        printf "  boot.loader.grub.extraEntries = ''\n"
        printf '%s' "${CONFIG[grubExtraEntries]}"
        printf "  '';\n"
        printf '}\n'
    } > "$outfile"

    log "Generated: $config_dir/machines/grub-entries.nix"
}

# ========== DUAL BOOT SPACE PREPARATION ==========

_usage_bar() {
    local pct="${1:-0}" filled=$(( pct * 20 / 100 )) bar="" i
    for (( i=0; i<20; i++ )); do
        [[ $i -lt $filled ]] && bar+="█" || bar+="░"
    done
    printf "[%s] %3d%%" "$bar" "$pct"
}

show_disk_layout() {
    local device="$1"
    local devname="${device##*/}"
    local sector_size total_sectors
    sector_size=$(cat "/sys/class/block/$devname/queue/logical_block_size" 2>/dev/null || echo 512)
    total_sectors=$(cat "/sys/class/block/$devname/size" 2>/dev/null || echo 0)

    printf "\n  Disk: %s  (%dGB total)\n\n" "$device" \
        "$(( total_sectors * sector_size / 1073741824 ))"
    printf "  %-18s %8s  %-8s  %s\n" "Partition" "Size" "Type" "Usage"
    printf "  %-18s %8s  %-8s  %s\n" "---------" "----" "----" "-----"

    for part_sys in "/sys/class/block/$devname/"/*/; do
        local part_name="${part_sys%/}"; part_name="${part_name##*/}"
        [[ "$part_name" == "${devname}"* ]] || continue
        [[ -f "${part_sys}partition" ]] || continue
        local devpath="/dev/$part_name"
        local part_sectors
        part_sectors=$(cat "${part_sys}size" 2>/dev/null || echo 0)
        local size_bytes=$(( part_sectors * sector_size ))
        local size_gb=$(( size_bytes / 1073741824 ))
        local fstype
        fstype=$(blkid -o value -s TYPE "$devpath" 2>/dev/null || echo "")
        local usage_str="-"
        if [[ "$fstype" == "ntfs" ]] && command -v ntfsresize &>/dev/null; then
            local used_pct
            used_pct=$(ntfsresize --info --force "$devpath" 2>&1 | \
                grep "Space in use" | sed 's/.*(\([0-9]*\)\..*/\1/')
            usage_str=$(_usage_bar "${used_pct:-0}")
        elif [[ "$fstype" == "vfat" ]]; then
            usage_str="[EFI / boot]"
        elif [[ -z "$fstype" ]]; then
            usage_str="[reserved]"
        fi
        printf "  %-18s %7dGB  %-8s  %s\n" "$devpath" "$size_gb" "${fstype:-?}" "$usage_str"
    done

    local free_bytes
    free_bytes=$(parted -s "$device" unit B print free 2>/dev/null | \
        grep "Free Space" | tail -1 | awk '{print $3}' | tr -d 'B') || true
    printf "\n  Unallocated: %dGB\n\n" "$(( ${free_bytes:-0} / 1073741824 ))"
}

prepare_dual_boot_space() {
    local device="${CONFIG[device]}"
    local total_bytes
    total_bytes=$(lsblk -rn -b -d -o SIZE "$device" 2>/dev/null)
    local total_gb=$(( total_bytes / 1073741824 ))

    show_disk_layout "$device"

    # Ask how much of the disk NixOS should get
    local pct
    while true; do
        read -p "How much of the disk for NixOS? (10-90%, default 50): " pct
        pct="${pct:-50}"; pct="${pct//%/}"
        [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= 10 && pct <= 90 )) && break
        warn "Enter a number between 10 and 90"
    done
    local nixos_bytes=$(( total_bytes * pct / 100 ))
    # When creating a new EFI partition, reserve 512MB from the allocation
    local efi_create_bytes=0
    if [[ -z "${CONFIG[efiPartition]}" ]]; then
        efi_create_bytes=$(( 512 * 1024 * 1024 ))
        log "NixOS allocation: $(( nixos_bytes / 1073741824 ))GB (${pct}% of ${total_gb}GB) + 512MB new EFI"
    else
        log "NixOS allocation: $(( nixos_bytes / 1073741824 ))GB (${pct}% of ${total_gb}GB)"
    fi
    nixos_bytes=$(( nixos_bytes + efi_create_bytes ))

    local devname="${device##*/}"
    local sector_size
    sector_size=$(cat "/sys/class/block/$devname/queue/logical_block_size" 2>/dev/null || echo 512)

    # Check how much free space already exists
    local free_bytes
    free_bytes=$(parted -s "$device" unit B print free 2>/dev/null | \
        grep "Free Space" | tail -1 | awk '{print $3}' | tr -d 'B') || true
    free_bytes="${free_bytes:-0}"

    if (( free_bytes >= nixos_bytes )); then
        log "$(( free_bytes / 1073741824 ))GB already unallocated — no shrinking needed"
        _create_nixos_partition "$device" "$devname" "$sector_size"
        return
    fi

    # Before shrinking, ask if an existing partition can be reused (e.g. from a failed
    # previous install). We can't probe inside LUKS without the password, so show all
    # non-EFI, non-swap partitions and let the user decide.
    echo ""
    log "No unallocated space available. Existing partitions on $device:"
    local -a all_parts=() all_sizes=() all_types=()
    for part_sys in "/sys/class/block/$devname/"/*/; do
        local part_name="${part_sys%/}"; part_name="${part_name##*/}"
        [[ "$part_name" == "${devname}"* ]] || continue
        [[ -f "${part_sys}partition" ]] || continue
        local devpath="/dev/$part_name"
        [[ -b "$devpath" ]] || continue
        [[ "$devpath" == "${CONFIG[efiPartition]}" ]] && continue
        local part_sectors; part_sectors=$(cat "${part_sys}size" 2>/dev/null || echo 0)
        local psize=$(( part_sectors * sector_size ))
        local ptype
        if cryptsetup isLuks "$devpath" 2>/dev/null; then
            ptype="crypto_LUKS"
        else
            ptype=$(timeout 5 blkid -o value -s TYPE "$devpath" 2>/dev/null || true)
            ptype="${ptype:-unformatted}"
        fi
        [[ "$ptype" == "swap" ]] && continue
        all_parts+=("$devpath")
        all_sizes+=("$psize")
        all_types+=("$ptype")
    done

    echo ""
    for i in "${!all_parts[@]}"; do
        printf "  %d) %-20s %5dGB  %s\n" \
            $(( i + 1 )) "${all_parts[$i]}" "$(( all_sizes[i] / 1073741824 ))" "${all_types[$i]}"
    done
    echo ""
    log "If one of these is from a previous failed install, it can be reused (all data on it will be erased)."
    local pick_reuse
    read -p "Enter number to reuse existing partition, or press Enter to shrink instead: " pick_reuse </dev/tty
    if [[ "$pick_reuse" =~ ^[0-9]+$ ]] && (( pick_reuse >= 1 && pick_reuse <= ${#all_parts[@]} )); then
        CONFIG[nixosPartition]="${all_parts[$(( pick_reuse - 1 ))]}"
        log "Using existing partition ${CONFIG[nixosPartition]} for NixOS (will be erased by installer)"
        return
    fi

    local needed_bytes=$(( nixos_bytes - free_bytes ))
    local needed_gb=$(( needed_bytes / 1073741824 ))
    log "Need to free ${needed_gb}GB more by shrinking an existing partition"

    # Build list of shrink candidates using sysfs — never blocks unlike lsblk on LUKS devices.
    # Exclude: EFI, swap, and unformatted partitions (can't shrink what has no filesystem).
    local -a cand_parts=() cand_sizes=()
    for part_sys in "/sys/class/block/$devname/"/*/; do
        local part_name="${part_sys%/}"; part_name="${part_name##*/}"
        [[ "$part_name" == "${devname}"* ]] || continue
        [[ -f "${part_sys}partition" ]] || continue
        local devpath="/dev/$part_name"
        [[ -b "$devpath" ]] || continue
        [[ "$devpath" == "${CONFIG[efiPartition]}" ]] && continue
        local part_sectors
        part_sectors=$(cat "${part_sys}size" 2>/dev/null || echo 0)
        local psize=$(( part_sectors * sector_size ))
        local fstype
        if cryptsetup isLuks "$devpath" 2>/dev/null; then
            fstype="crypto_LUKS"
        else
            fstype=$(timeout 5 blkid -o value -s TYPE "$devpath" 2>/dev/null || true)
        fi
        [[ "$fstype" == "swap" ]] && continue
        [[ -z "$fstype" ]] && continue  # unformatted — skip, can't shrink
        cand_parts+=("$devpath")
        cand_sizes+=("$psize")
    done

    local target_part="" target_size_bytes=0

    if [[ "${#cand_parts[@]}" -eq 0 ]]; then
        echo ""
        warn "No shrinkable partitions found (all are EFI or swap)."
        echo "Available partitions on $device:"
        for part_sys in "/sys/class/block/$devname/"/*/; do
            local pn="${part_sys%/}"; pn="${pn##*/}"
            [[ "$pn" == "${devname}"* ]] || continue
            [[ -f "${part_sys}partition" ]] || continue
            local ps; ps=$(cat "${part_sys}size" 2>/dev/null || echo 0)
            printf "  /dev/%s  %dGB\n" "$pn" "$(( ps * sector_size / 1073741824 ))"
        done
        echo ""
        read -p "Enter partition to shrink (e.g. /dev/nvme0n1p2), or blank to abort: " target_part </dev/tty
        [[ -z "$target_part" ]] && error "Aborted"
        [[ -b "$target_part" ]] || error "$target_part is not a block device"
        target_size_bytes=$(lsblk -rn -b -o SIZE "$target_part" 2>/dev/null || echo 0)
    elif [[ "${#cand_parts[@]}" -eq 1 ]]; then
        target_part="${cand_parts[0]}"
        target_size_bytes="${cand_sizes[0]}"
    else
        # Multiple candidates — show numbered list, pick largest as default
        echo ""
        log "Multiple shrinkable partitions found:"
        local best_idx=0
        for i in "${!cand_parts[@]}"; do
            local sz_gb=$(( cand_sizes[i] / 1073741824 ))
            printf "  %d) %s  %dGB\n" $(( i + 1 )) "${cand_parts[$i]}" "$sz_gb"
            if (( cand_sizes[i] > cand_sizes[best_idx] )); then best_idx=$i; fi
        done
        echo ""
        local pick
        read -p "Which partition to shrink? [default: $(( best_idx + 1 ))]: " pick </dev/tty
        pick="${pick:-$(( best_idx + 1 ))}"
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#cand_parts[@]} )); then
            target_part="${cand_parts[$(( pick - 1 ))]}"
            target_size_bytes="${cand_sizes[$(( pick - 1 ))]}"
        else
            error "Invalid selection"
        fi
    fi

    local target_fstype
    target_fstype=$(timeout 5 blkid -o value -s TYPE "$target_part" 2>/dev/null || echo "unknown")

    local new_size_bytes=$(( target_size_bytes - needed_bytes ))
    local new_size_gb=$(( new_size_bytes / 1073741824 ))

    if (( new_size_bytes <= 0 )); then
        error "$target_part is only $(( target_size_bytes / 1073741824 ))GB but needs to free ${needed_gb}GB — not enough space. Choose a smaller NixOS allocation or pick a larger partition."
    fi
    if (( new_size_gb < 10 )); then
        error "$target_part would be shrunk to ${new_size_gb}GB — too small for a usable OS. Choose a smaller NixOS allocation percentage."
    fi

    echo ""
    warn "Will shrink $target_part ($target_fstype): $(( target_size_bytes / 1073741824 ))GB → ${new_size_gb}GB"
    warn "Data is preserved but back up important files before continuing."
    echo ""

    read -p "Proceed? [y/N]: " confirm </dev/tty
    [[ "${confirm,,}" == "y" ]] || error "Aborted by user"

    shrink_partition "$target_part" "$new_size_bytes" "$device" "$sector_size"

    log "Partition shrunk. Updated layout:"
    show_disk_layout "$device"

    _create_nixos_partition "$device" "$devname" "$sector_size"
}

# Create NixOS partition (and EFI partition if none exists) in the free space.
# Stores results in CONFIG[nixosPartition] and CONFIG[efiPartition].
_create_nixos_partition() {
    local device="$1"
    local devname="${device##*/}"

    # Snapshot existing partitions via sysfs — never blocks
    local -A before=()
    for part_sys in "/sys/class/block/$devname/"/*/; do
        local pn="${part_sys%/}"; pn="${pn##*/}"
        [[ "$pn" == "${devname}"* ]] || continue
        [[ -f "${part_sys}partition" ]] || continue
        before["/dev/$pn"]=1
    done

    _settle() {
        sleep 2
        partprobe "$device" 2>/dev/null || true
        udevadm settle --timeout=10 2>/dev/null || true
    }

    # Return partitions present now that weren't in the before snapshot
    _new_parts() {
        for part_sys in "/sys/class/block/$devname/"/*/; do
            local pn="${part_sys%/}"; pn="${pn##*/}"
            [[ "$pn" == "${devname}"* ]] || continue
            [[ -f "${part_sys}partition" ]] || continue
            local devpath="/dev/$pn"
            [[ -b "$devpath" ]] || continue
            [[ -n "${before[$devpath]:-}" ]] && continue
            echo "$devpath"
        done
    }

    if [[ -z "${CONFIG[efiPartition]}" ]]; then
        # No existing EFI — create 512MB EFI then NixOS in remaining space
        log "Creating 512MB EFI partition..."
        printf "size=512MiB,type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n" | sfdisk -a "$device"
        _settle

        local efi_part
        efi_part=$(_new_parts | head -1)
        [[ -z "$efi_part" ]] && error "Failed to detect newly created EFI partition on $device"
        mkfs.vfat -F32 "$efi_part"
        CONFIG[efiPartition]="$efi_part"
        log "EFI partition: $efi_part"

        # Update snapshot to include the EFI partition
        before["$efi_part"]=1

        log "Creating NixOS partition in remaining free space..."
        printf ",\n" | sfdisk -a "$device"
        _settle
    else
        log "Creating NixOS partition in free space..."
        printf ",\n" | sfdisk -a "$device"
        _settle
    fi

    local nixos_part
    nixos_part=$(_new_parts | tail -1)
    [[ -z "$nixos_part" ]] && error "Failed to detect newly created NixOS partition on $device"

    CONFIG[nixosPartition]="$nixos_part"
    log "NixOS partition: $nixos_part"
}

# Shrink a partition and its filesystem in-place.
# Handles ntfs, btrfs, ext2/3/4, and crypto_LUKS wrappers around those.
shrink_partition() {
    local devpath="$1" new_size_bytes="$2" disk="$3" sector_size="$4"

    local fstype
    # cryptsetup isLuks is the most reliable LUKS detector in live environments
    # where blkid/lsblk fail to probe LUKS2 headers
    if cryptsetup isLuks "$devpath" 2>/dev/null; then
        fstype="crypto_LUKS"
    else
        fstype=$(timeout 10 blkid -o value -s TYPE "$devpath" 2>/dev/null || true)
        if [[ -z "$fstype" ]]; then
            fstype=$(lsblk -no FSTYPE "$devpath" 2>/dev/null | head -1 || true)
        fi
    fi

    local inner_dev="$devpath" luks_name=""

    if [[ "$fstype" == "crypto_LUKS" ]]; then
        luks_name="hydrix-resize-$$"
        log "Opening LUKS container on $devpath..."
        cryptsetup open "$devpath" "$luks_name" </dev/tty
        inner_dev="/dev/mapper/$luks_name"
        fstype=$(timeout 10 blkid -o value -s TYPE "$inner_dev" 2>/dev/null || true)
        # lsblk on the mapped device is safe (it's already unlocked, not a raw LUKS block)
        if [[ -z "$fstype" ]]; then
            fstype=$(lsblk -no FSTYPE "$inner_dev" 2>/dev/null | head -1 || true)
        fi
        if [[ -z "$fstype" ]]; then
            error "Could not detect inner filesystem type in LUKS container $devpath. Run 'blkid $inner_dev' manually to inspect."
        fi
        log "Inner filesystem: $fstype"
    fi

    # Reserve space for LUKS header when resizing inner filesystem
    local fs_size="$new_size_bytes"
    [[ -n "$luks_name" ]] && fs_size=$(( new_size_bytes - 4194304 ))

    case "$fstype" in
        ntfs)
            log "Checking NTFS filesystem..."
            if ! ntfsresize --no-action --force --size "$fs_size" "$inner_dev"; then
                [[ -n "$luks_name" ]] && cryptsetup close "$luks_name"
                error "ntfsresize pre-check failed. Run chkdsk from Windows first."
            fi
            log "Shrinking NTFS filesystem..."
            ntfsresize --force --size "$fs_size" "$inner_dev"
            ;;
        btrfs)
            local mnt="/tmp/hydrix-resize-$$"
            mkdir -p "$mnt"
            log "Mounting btrfs for resize..."
            mount -o noatime "$inner_dev" "$mnt"
            log "Shrinking btrfs filesystem..."
            btrfs filesystem resize "$fs_size" "$mnt"
            umount "$mnt"; rmdir "$mnt"
            ;;
        ext4|ext3|ext2)
            log "Checking ext filesystem..."
            e2fsck -f "$inner_dev"
            log "Shrinking ext filesystem..."
            resize2fs "$inner_dev" "$(( fs_size / 1024 ))K"
            ;;
        "")
            [[ -n "$luks_name" ]] && cryptsetup close "$luks_name"
            error "Could not detect filesystem type on $devpath (blkid and lsblk both returned empty). The partition may be unformatted or use an unrecognised format. Cannot shrink automatically."
            ;;
        *)
            [[ -n "$luks_name" ]] && cryptsetup close "$luks_name"
            error "Unsupported filesystem type '$fstype' on $devpath. Only ntfs, btrfs, ext4, and LUKS-wrapped versions are supported. Resize manually."
            ;;
    esac

    [[ -n "$luks_name" ]] && cryptsetup close "$luks_name"

    # Resize the partition entry to match using sfdisk.
    # sfdisk reads confirmation from stdin; a pipe bypasses the prompt entirely.
    local part_name="${devpath##*/}"
    local part_num="${part_name##*[!0-9]}"
    local new_size_sectors=$(( new_size_bytes / sector_size ))

    log "Updating partition table..."
    printf ",%s\n" "$new_size_sectors" | sfdisk -N "$part_num" "$disk"
    sleep 1
    partprobe "$disk" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
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
        disko_args+=(--arg nixosPartition "\"${CONFIG[nixosPartition]}\"")

        # Stop udisks2 automounter so it can't re-mount the EFI partition
        # between our unmount and disko's mount step
        systemctl stop udisks2.service 2>/dev/null || true
        umount "${CONFIG[efiPartition]}" 2>/dev/null || true
    fi

    # Run disko (formats and mounts the NixOS partition only)
    log "Running disko..."
    nix run github:nix-community/disko -- --mode disko "${disko_args[@]}" "$disko_file"

    if [[ "$layout" == dual-boot-* ]]; then
        # Mount the existing EFI partition at /mnt/boot manually.
        # Disko does not manage it to avoid automount conflicts during install.
        log "Mounting EFI partition at /mnt/boot..."
        mkdir -p /mnt/boot
        mount -t vfat -o defaults,umask=0077 "${CONFIG[efiPartition]}" /mnt/boot
        systemctl start udisks2.service 2>/dev/null || true
    fi

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

    echo ""
    log "=== Running nixos-install (this takes 20-60 min depending on network) ==="
    echo ""
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

    # Copy wallpapers to user home (disk is now mounted)
    copy_wallpapers "/mnt/home/${CONFIG[username]}"

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

        # --store /mnt ensures outputs go to the target system's nix store
        # --eval-store auto evaluates using the live ISO's daemon
        if nix build "$config_dir#nixosConfigurations.${vm_name}.config.microvm.declaredRunner" \
            --no-link \
            --store /mnt --eval-store auto \
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
            --store /mnt --eval-store auto \
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
    _finalize_dual_boot_entries || warn "Dual-boot GRUB entry generation encountered errors — other OS entries may be absent from the GRUB menu"
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
