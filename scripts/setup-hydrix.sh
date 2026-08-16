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

# Ensure nix experimental features are available (stock NixOS installs don't
# enable flakes/nix-command by default)
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
    [colorscheme]="hydrix"
    [diskoDevice]=""
    [hardwareConfigPath]=""
    [hydrixSource]="github"
    [hydrixUrl]="git+https://github.com/borttappat/Hydrix.git"
    [hydrixLocalPath]=""
    # WAN / VFIO — set by detect_wifi_hardware
    [hasWifi]="false"
    [vfioEnable]="false"
    [vfioPciIds]="[ ]"
    [wanMode]="auto"
    [wanDevice]=""
    [wanDeviceLine]=""
)

# ========== SECURE CLEANUP ==========
# Ensure sensitive data is cleared on exit (normal or error)

# File-based caches survive subshell boundaries (variable assignments inside
# $(...) are lost when the subshell exits; files are not).
_HYDRIX_TMPL_CACHE_FILE="/tmp/hydrix-setup-tmpl-$$"
_HYDRIX_TMPL_TMPDIR_FILE="/tmp/hydrix-setup-tmpl-tmpdir-$$"

secure_cleanup() {
    # Clear sensitive variables from memory
    unset token pass pass1 pass2 password password_confirm key_content
    unset WIFI_PASSWORD

    # Clear SSH command override
    unset GIT_SSH_COMMAND

    # Remove temp clone used for template fetching
    local tmpl_tmpdir=""
    [[ -f "$_HYDRIX_TMPL_TMPDIR_FILE" ]] && tmpl_tmpdir=$(cat "$_HYDRIX_TMPL_TMPDIR_FILE")
    if [[ -n "$tmpl_tmpdir" ]] && [[ -d "$tmpl_tmpdir" ]]; then
        rm -rf "$tmpl_tmpdir"
    fi
    rm -f "$_HYDRIX_TMPL_CACHE_FILE" "$_HYDRIX_TMPL_TMPDIR_FILE"
}

# Register cleanup handler for all exit paths
trap secure_cleanup EXIT

# ========== UTILITY FUNCTIONS ==========

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }
warn() { echo "[WARN] $*"; }

command_exists() { command -v "$1" &>/dev/null; }

# Resolve the templates/user-config directory regardless of invocation method.
# On first call when templates are not found locally (curl|bash on a fresh machine),
# does a shallow clone of the Hydrix repo to a temp dir and caches the result.
# Uses a file-based cache so the result survives $(...) subshell boundaries.

find_hydrix_templates() {
    # Return cached result from previous call
    if [[ -f "$_HYDRIX_TMPL_CACHE_FILE" ]]; then
        cat "$_HYDRIX_TMPL_CACHE_FILE"; return 0
    fi

    local found=""

    # 1. Explicit override
    if [[ -n "${HYDRIX_TEMPLATES:-}" ]] && [[ -d "$HYDRIX_TEMPLATES" ]]; then
        found="$HYDRIX_TEMPLATES"
    # 2. Current user's ~/Hydrix
    elif [[ -d "$HOME/Hydrix/templates/user-config" ]]; then
        found="$HOME/Hydrix/templates/user-config"
    # 3. Real invoking user when running under sudo (HOME=/root in that case)
    elif [[ -n "${SUDO_USER:-}" ]]; then
        local sudo_home
        sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "")
        if [[ -n "$sudo_home" ]] && [[ -d "$sudo_home/Hydrix/templates/user-config" ]]; then
            found="$sudo_home/Hydrix/templates/user-config"
        fi
    fi

    # 4. Relative to script location (direct invocation from local clone)
    if [[ -z "$found" ]] && [[ -n "${SCRIPT_DIR:-}" ]] && [[ -d "$SCRIPT_DIR/../templates/user-config" ]]; then
        found="$SCRIPT_DIR/../templates/user-config"
    fi

    # 5. Fetch from GitHub — covers curl|bash on a fresh machine with no local clone
    #
    # Callers capture this function's return value via tmpl_root=$(find_hydrix_templates),
    # so nothing in this branch may write to stdout except the final `echo "$found"` below
    # -- log/success are plain echo (stdout) elsewhere in this script, and git clone's own
    # output would land on stdout too without redirecting it, so all three are explicitly
    # sent to stderr here instead.
    if [[ -z "$found" ]]; then
        log "Templates not found locally — fetching from GitHub..." >&2
        local clone_dir
        clone_dir=$(mktemp -d)
        local branch="${HYDRIX_BRANCH:-main}"
        if git clone --depth=1 --branch "$branch" \
            https://github.com/borttappat/Hydrix.git "$clone_dir/Hydrix" >&2; then
            found="$clone_dir/Hydrix/templates/user-config"
            echo "$clone_dir" > "$_HYDRIX_TMPL_TMPDIR_FILE"
            success "Templates fetched from GitHub (branch: $branch)" >&2
        else
            rm -rf "$clone_dir"
            return 1
        fi
    fi

    echo "$found" > "$_HYDRIX_TMPL_CACHE_FILE"
    echo "$found"
}

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

    [[ ! -d "$CONFIG_DIR/infra" ]] && copy_template_infra

    # Ensure custom, colorschemes, templates, configs directories exist
    [[ ! -d "$CONFIG_DIR/custom" ]]     && copy_template_custom
    [[ ! -d "$CONFIG_DIR/templates" ]]  && copy_template_templates
    [[ ! -d "$CONFIG_DIR/colorschemes" ]] && create_colorschemes_dir
    [[ ! -d "$CONFIG_DIR/configs" ]]    && copy_template_configs
    [[ ! -d "$CONFIG_DIR/vpn" ]]       && copy_template_vpn

    # Update flake.nix to use auto-discovery
    generate_flake_nix

    # Commit migration
    (
        cd "$CONFIG_DIR"
        git add .
        git -c user.name="${CONFIG[serial]}" -c user.email="${CONFIG[username]}@${CONFIG[serial]}.hydrix.local" \
            commit -m "Migrate to multi-machine format: machine.nix -> machines/${legacy_hostname}.nix" 2>/dev/null || true
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

    # Board identifier (for config file naming — matches rebuild's non-root detection)
    local serial
    serial=$(generate_fallback_id)
    if [[ -z "$serial" ]] || [[ "$serial" == unknown-* ]]; then
        serial="hydrix-$(head -c 4 /dev/urandom | xxd -p)"
        warn "  Could not detect board name, using random identifier: $serial"
    else
        log "  Board identifier: $serial"
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

    # NixOS state version — read the value this machine was originally installed
    # with (never bumped since, per the NixOS manual on system.stateVersion).
    # Carried forward as-is; never re-derived from the currently running release.
    CONFIG[stateVersion]=$(parse_nix_value "system.stateVersion" "/etc/nixos/configuration.nix")
    if [[ -z "${CONFIG[stateVersion]}" ]]; then
        # Flake-managed systems have no /etc/nixos/configuration.nix.
        # Fall back to the current NixOS release as a best-effort starting point.
        local nixos_rel
        nixos_rel=$(nixos-version 2>/dev/null | grep -oP '^\d+\.\d+')
        if [[ -n "$nixos_rel" ]]; then
            CONFIG[stateVersion]="$nixos_rel"
            log "  State version: ${CONFIG[stateVersion]} (detected from nixos-version)"
        else
            read -rp "parameter system.stateVersion not found, enter value manually: " CONFIG[stateVersion]
            while [[ -z "${CONFIG[stateVersion]}" ]]; do
                read -rp "system.stateVersion cannot be empty, enter value manually: " CONFIG[stateVersion]
            done
        fi
    fi
    log "  State version: ${CONFIG[stateVersion]}"

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

detect_ethernet_interface() {
    local iface=""

    # Prefer the interface currently carrying the default route, but skip
    # virtual/bridge interfaces (br-*, tap*, etc.) that may exist from a
    # prior setup attempt — they are never valid WAN devices.
    iface=$(ip route show default 2>/dev/null | awk '/default/ { print $5; exit }')
    if [[ "$iface" =~ ^(br|tap|veth|virbr|docker|dummy|bond|tun|wl) ]]; then
        iface=""
    fi

    if [[ -z "$iface" ]]; then
        # Fallback: first physical ethernet (skip loopback, wireless, virtual)
        for dir in /sys/class/net/*/; do
            local name
            name=$(basename "$dir")
            [[ "$name" == "lo" ]] && continue
            [[ "$name" =~ ^(wl|br|tap|veth|virbr|docker|dummy|bond|tun) ]] && continue
            [[ -e "$dir/device" ]] || continue
            iface="$name"
            break
        done
    fi

    echo "${iface:-}"
}

# Read PCI vendor:device ID from sysfs. Always present, no pciutils dependency
# (a bare NixOS install may not have lspci installed).
pci_id_from_sysfs() {
    local addr="$1" vendor device
    vendor=$(cat "/sys/bus/pci/devices/$addr/vendor" 2>/dev/null || echo "")
    device=$(cat "/sys/bus/pci/devices/$addr/device" 2>/dev/null || echo "")
    [[ -n "$vendor" && -n "$device" ]] && echo "${vendor#0x}:${device#0x}"
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
                pci_id=$(pci_id_from_sysfs "$pci_addr")
                log "  Found: $pci_addr (ID: $pci_id)"
                break
            fi
        fi
    done

    # Fallback 1: vfio-pci bound devices by PCI class 0x028000 (Network controller).
    # Handles re-running setup on an existing Hydrix machine where the WiFi card is
    # already passed through to the router VM and has no wl* interface.
    if [[ -z "$pci_addr" ]]; then
        for dev in /sys/bus/pci/drivers/vfio-pci/*/; do
            [[ -e "$dev/class" ]] || continue
            local class
            class=$(cat "$dev/class" 2>/dev/null || echo "")
            if [[ "$class" == "0x028000" ]]; then
                pci_addr=$(basename "$dev")
                pci_id=$(pci_id_from_sysfs "$pci_addr")
                log "  Found (vfio-pci): $pci_addr (ID: $pci_id)"
                break
            fi
        done
    fi

    # Fallback 2: scan all PCI devices by class 0x028000 (Network controller),
    # regardless of driver binding. Covers WiFi cards with no wl* interface and
    # not yet bound to vfio-pci.
    if [[ -z "$pci_addr" ]]; then
        for dev in /sys/bus/pci/devices/*/; do
            [[ -e "$dev/class" ]] || continue
            local class
            class=$(cat "$dev/class" 2>/dev/null || echo "")
            if [[ "$class" == "0x028000" ]]; then
                pci_addr=$(basename "$dev")
                pci_id=$(pci_id_from_sysfs "$pci_addr")
                log "  Found (pci scan): $pci_addr (ID: $pci_id)"
                break
            fi
        done
    fi

    if [[ -n "$pci_addr" ]]; then
        CONFIG[wifiPciAddress]="${pci_addr#0000:}"
        CONFIG[wifiPciId]="$pci_id"
        CONFIG[hasWifi]="true"
        CONFIG[vfioEnable]="true"
        CONFIG[vfioPciIds]='[ "'"${pci_id}"'" ]'
        CONFIG[wanMode]="auto"
        CONFIG[wanDeviceLine]=""
        success "WiFi: ${CONFIG[wifiPciAddress]} (${CONFIG[wifiPciId]})"
    else
        warn "WiFi hardware not detected"
        local eth
        eth=$(detect_ethernet_interface)
        if [[ -n "$eth" ]]; then
            log "  Ethernet WAN: $eth"
        else
            warn "  No ethernet interface detected — wan.mode will be 'none'"
            eth=""
        fi
        CONFIG[wifiPciAddress]=""
        CONFIG[wifiPciId]=""
        CONFIG[hasWifi]="false"
        CONFIG[vfioEnable]="false"
        CONFIG[vfioPciIds]="[ ]"
        CONFIG[wanMode]="macvtap"
        CONFIG[wanDevice]="$eth"
        CONFIG[wanDeviceLine]="${eth:+wan.device = \"${eth}\";}"
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

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    local template_dir="$tmpl_root/specialisations"

    cp -r "$template_dir"/* "$CONFIG_DIR/specialisations/"
    log "  Copied from template"
}

copy_template_infra() {
    log "Creating infra VMs from template..."

    mkdir -p "$CONFIG_DIR/infra"

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/infra"/* "$CONFIG_DIR/infra/"
    log "  Copied from template"
}

copy_template_profiles() {
    log "Creating profiles from template..."

    mkdir -p "$CONFIG_DIR/profiles"

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/profiles"/* "$CONFIG_DIR/profiles/"
    log "  Copied from template"
}

copy_template_modules() {
    log "Creating modules config from template..."

    mkdir -p "$CONFIG_DIR/modules"

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/modules"/* "$CONFIG_DIR/modules/"
    log "  Copied from template"
}

substitute_modules_locale() {
    local common="$CONFIG_DIR/modules/common.nix"

    # Skip if placeholders are already gone (existing repo has real values)
    if ! grep -q "@TIMEZONE@" "$common" 2>/dev/null; then
        log "  modules/common.nix already configured, skipping locale substitution"
        return
    fi

    log "  Substituting locale placeholders in modules/common.nix..."
    sed -i \
        -e "s|@TIMEZONE@|${CONFIG[timezone]}|g" \
        -e "s|@LOCALE@|${CONFIG[locale]}|g" \
        -e "s|@CONSOLE_KEYMAP@|${CONFIG[consoleKeymap]}|g" \
        -e "s|@XKB_LAYOUT@|${CONFIG[xkbLayout]}|g" \
        -e "s|@XKB_VARIANT@|${CONFIG[xkbVariant]}|g" \
        "$common"
    log "  Locale: tz=${CONFIG[timezone]} lang=${CONFIG[locale]} kb=${CONFIG[xkbLayout]}"
}

substitute_modules_user() {
    local user_nix="$CONFIG_DIR/modules/user.nix"

    # Skip if placeholders are already gone (existing repo has real values)
    if ! grep -q "@USERNAME@" "$user_nix" 2>/dev/null; then
        log "  modules/user.nix already configured, skipping identity substitution"
        return
    fi

    log "  Substituting identity placeholders in modules/user.nix..."
    sed -i \
        -e "s|@USERNAME@|${CONFIG[username]}|g" \
        -e "s|@COLORSCHEME@|${CONFIG[colorscheme]}|g" \
        "$user_nix"
    log "  Identity: user=${CONFIG[username]} colorscheme=${CONFIG[colorscheme]}"
}

# Git identity for ~/hydrix-config is auto-derived at eval time (machine name
# + hydrix.username, scoped to that repo's local .git/config via
# modules/user.nix); no prompt, no placeholder substitution needed here.

# wifi.nix ships from the template as a static empty sops stub (no
# @WIFI_SSID@ placeholder to substitute). Credentials collected by
# prompt_wifi() are encrypted straight to secrets/wifi.yaml in the sops
# step of main() instead, never written to modules/wifi.nix in plaintext.

copy_template_fonts() {
    log "Creating fonts from template..."

    mkdir -p "$CONFIG_DIR/fonts"

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/fonts"/. "$CONFIG_DIR/fonts/"
    log "  Copied from template"
}

copy_template_tasks() {
    log "Creating task slots from template..."

    mkdir -p "$CONFIG_DIR/tasks"

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/tasks"/. "$CONFIG_DIR/tasks/"
    log "  Copied from template"
}

copy_template_custom() {
    log "Creating custom modules from template..."

    mkdir -p "$CONFIG_DIR/custom"

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/custom"/* "$CONFIG_DIR/custom/"
    log "  Copied from template"
}

copy_template_templates() {
    log "Creating templates from template..."

    mkdir -p "$CONFIG_DIR/templates"

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/templates"/* "$CONFIG_DIR/templates/"
    log "  Copied from template (new-profile reads these)"
}

copy_template_configs() {
    log "Creating configs directory..."
    mkdir -p "$CONFIG_DIR/configs"

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/configs"/. "$CONFIG_DIR/configs/"
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
    if [[ -d "$(dirname "$0")/../theming/wallpapers" ]]; then
        hydrix_wp="$(cd "$(dirname "$0")/.." && pwd)/theming/wallpapers"
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

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"

    mkdir -p "$CONFIG_DIR/secrets"
    [[ -f "$tmpl_root/secrets/.sops.yaml" ]] && \
        cp "$tmpl_root/secrets/.sops.yaml" "$CONFIG_DIR/secrets/.sops.yaml"
    [[ -f "$tmpl_root/secrets/github.yaml.example" ]] && \
        cp "$tmpl_root/secrets/github.yaml.example" "$CONFIG_DIR/secrets/github.yaml.example"
    [[ -f "$tmpl_root/.gitignore" ]] && \
        cp "$tmpl_root/.gitignore" "$CONFIG_DIR/.gitignore"
    log "  secrets/ scaffold created (see secrets/.sops.yaml for setup instructions)"
}

copy_template_vpn() {
    log "Creating vpn directory..."
    mkdir -p "$CONFIG_DIR/vpn"
    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    cp -r "$tmpl_root/vpn"/* "$CONFIG_DIR/vpn/"
    log "  Copied from template (add .conf files and edit vpn/mullvad.nix to activate)"
}

copy_template_readme() {
    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || return 0  # README is optional

    if [[ -f "$tmpl_root/README.md" ]]; then
        cp "$tmpl_root/README.md" "$CONFIG_DIR/README.md"
        log "  Copied README.md from template"
    fi
}

# ========== CONFIG GENERATION ==========

generate_flake_nix() {
    log "Generating flake.nix from template..."

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    local template_file="$tmpl_root/flake.nix"
    [[ -f "$template_file" ]] || error "flake.nix not found in templates: $template_file"

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

    local tmpl_root
    tmpl_root=$(find_hydrix_templates) || error "Could not find Hydrix templates directory"
    local template_file="$tmpl_root/machines/installer.nix"
    [[ -f "$template_file" ]] || error "Machine config template not found: $template_file"

    # Best-effort detection of disko values from the running system.
    # These are informational for future reinstalls; disko is not re-run in setup mode.
    local efi_part layout swap_size grub_gfxmode
    efi_part=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || findmnt -n -o SOURCE /boot 2>/dev/null || echo "")
    # Detect LUKS by checking if root lives on a dm-crypt device.
    if lsblk -no TYPE "$(findmnt -n -o SOURCE /)" 2>/dev/null | grep -q "crypt" || \
       [[ "$(findmnt -n -o SOURCE /)" == /dev/mapper/* ]]; then
        layout="full-disk-luks"
    else
        layout="full-disk-plain"
    fi
    swap_size=$(swapon --show=SIZE --noheadings --bytes 2>/dev/null | head -1 | awk '{printf "%.0fG\n", $1/1024/1024/1024}')
    [[ -z "$swap_size" || "$swap_size" == "0G" ]] && swap_size="8G"
    grub_gfxmode="1920x1080x32"

    # Pipe through a second sed to drop the hashedPassword line: setup mode cannot
    # safely read the existing hash (requires root), and setting "!" locks the account.
    # The user can add their hash manually with: mkpasswd -m sha-512
    sed \
        -e "s|@SERIAL@|${CONFIG[serial]}|g" \
        -e "s|@DATE@|${gen_date}|g" \
        -e "s|@PASSWORD_HASH@|__SETUP_NO_PASSWORD__|g" \
        -e "s|@DISKO_ENABLE@|false|g" \
        -e "s|@DEVICE@|${CONFIG[diskoDevice]}|g" \
        -e "s|@SWAP_SIZE@|${swap_size}|g" \
        -e "s|@LAYOUT@|${layout}|g" \
        -e "s|@NIXOS_PARTITION@|${CONFIG[diskoDevice]}|g" \
        -e "s|@EFI_PARTITION@|${efi_part}|g" \
        -e "s|@EFI_BOOTLOADER_ID@|nixos|g" \
        -e "s|@ROUTER_TYPE@|${CONFIG[routerType]}|g" \
        -e "s|@PLATFORM@|${CONFIG[platform]}|g" \
        -e "s|@IS_ASUS@|${CONFIG[isAsus]}|g" \
        -e "s|@WIFI_PCI_ID@|${CONFIG[wifiPciId]}|g" \
        -e "s|@WIFI_PCI_ADDRESS@|${CONFIG[wifiPciAddress]}|g" \
        -e "s|@VFIO_ENABLE@|${CONFIG[vfioEnable]}|g" \
        -e "s|@WAN_MODE@|${CONFIG[wanMode]}|g" \
        -e "s|@WAN_DEVICE@|${CONFIG[wanDevice]}|g" \
        -e "s|@GRUB_GFXMODE@|${grub_gfxmode}|g" \
        -e "s|@STATE_VERSION@|${CONFIG[stateVersion]}|g" \
        "$template_file" | \
    sed -e "/__SETUP_NO_PASSWORD__/d" \
        -e "/grub-entries\.nix/d" \
        > "$CONFIG_DIR/machines/${CONFIG[serial]}.nix"

    log "  Created: $CONFIG_DIR/machines/${CONFIG[serial]}.nix"
}

generate_full_config() {
    log "Generating full Hydrix configuration..."

    mkdir -p "$CONFIG_DIR"

    # Generate all components
    generate_flake_nix
    copy_template_specialisations
    copy_template_profiles
    copy_template_infra
    copy_template_modules
    copy_template_fonts
    copy_template_tasks
    substitute_modules_locale
    substitute_modules_user
    copy_template_custom
    copy_template_templates
    copy_template_configs
    copy_template_vpn
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
        git -c user.name="${CONFIG[serial]}" -c user.email="${CONFIG[username]}@${CONFIG[serial]}.hydrix.local" \
            commit -m "Initial Hydrix configuration for ${CONFIG[serial]}"
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

    # Update modules files if they still have placeholder values
    # (handles edge case: user cloned a fresh repo with unsubstituted templates)
    substitute_modules_locale
    substitute_modules_user

    # Commit the new machine
    (
        cd "$CONFIG_DIR"
        git add "machines/${CONFIG[serial]}.nix"
        if [[ -n "${CONFIG[hardwareConfigPath]}" ]]; then
            git add "machines/${CONFIG[serial]}-hardware.nix"
        fi
        git -c user.name="${CONFIG[serial]}" -c user.email="${CONFIG[username]}@${CONFIG[serial]}.hydrix.local" \
            commit -m "Add machine: ${CONFIG[serial]}"
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
            git -c user.name="${CONFIG[serial]}" -c user.email="${CONFIG[username]}@${CONFIG[serial]}.hydrix.local" \
                commit -m "Update hardware config for ${CONFIG[serial]}" 2>/dev/null || true
        fi
    )

    success "Using existing: machines/${CONFIG[serial]}.nix"
    success "Hardware config regenerated: machines/${CONFIG[serial]}-hardware.nix"
}

# ========== INTERACTIVE PROMPTS ==========

prompt_wifi() {
    # Skip entirely when no WiFi hardware — ethernet WAN needs no credentials
    if [[ "${CONFIG[hasWifi]}" == "false" ]]; then
        log "No WiFi hardware — skipping WiFi credential prompt"
        return
    fi

    # Skip if this repo already has WiFi credentials encrypted via sops
    if [[ -f "$CONFIG_DIR/secrets/wifi.yaml" ]]; then
        log "WiFi already configured in secrets/wifi.yaml, skipping"
        return
    fi

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
    log "Available colorschemes: hydrix, nord"
    read -p "Colorscheme [hydrix]: " cs
    CONFIG[colorscheme]="${cs:-hydrix}"
}

# ========== HYDRIX SOURCE SELECTION ==========

HYDRIX_BRANCH="main"

select_hydrix_branch() {
    echo ""
    echo "  Which branch?"
    echo ""
    echo "  [1] main     (default — latest stable restructured layout)"
    echo "  [2] stable   (legacy modules/ layout, pre-restructure)"
    echo "  [3] Custom   (enter branch name manually)"
    echo ""
    read -p "Branch [1-3, default=1]: " branch_choice

    case "${branch_choice:-1}" in
        1) HYDRIX_BRANCH="main" ;;
        2) HYDRIX_BRANCH="stable" ;;
        3)
            read -p "Branch name: " HYDRIX_BRANCH
            HYDRIX_BRANCH="${HYDRIX_BRANCH:-main}"
            ;;
        *) HYDRIX_BRANCH="main" ;;
    esac
}

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
            select_hydrix_branch
            CONFIG[hydrixSource]="github"
            if [[ "$HYDRIX_BRANCH" == "main" ]]; then
                CONFIG[hydrixUrl]="git+https://github.com/borttappat/Hydrix.git"
            else
                CONFIG[hydrixUrl]="git+https://github.com/borttappat/Hydrix.git?ref=${HYDRIX_BRANCH}"
            fi
            log "Using GitHub: ${CONFIG[hydrixUrl]}"
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

# Initialize sops secrets and encrypt WiFi credentials captured by
# prompt_wifi(), before nixos-rebuild switch. Uses nix run nixpkgs#{age,sops,
# ssh-to-age} directly rather than the hydrix-sops-setup binary, which
# doesn't exist until after a successful switch -- mirrors
# install-hydrix.sh's init_sops_during_install(), adapted for a live
# (non-chroot) target: no /mnt prefix, sudo only for /etc/ssh and
# /var/lib/sops-nix writes.
#
# Gracefully skipped (with a warning) if age/sops/ssh-to-age cannot be
# obtained, or SSH host key generation fails. Sops can be initialized
# manually afterward with: hydrix-sops-setup && hydrix-sops-setup --gen-key
init_sops_and_wifi() {
    log "Initializing sops secrets..."

    sudo mkdir -p /etc/ssh
    if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
        sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -C "" -q
        sudo chmod 600 /etc/ssh/ssh_host_ed25519_key
        sudo chmod 644 /etc/ssh/ssh_host_ed25519_key.pub
        log "  Generated SSH host key"
    else
        log "  SSH host key already exists"
    fi

    local host_pubkey
    host_pubkey=$(nix run --no-write-lock-file nixpkgs#ssh-to-age -- \
        -i /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null) || true

    if [[ -z "$host_pubkey" ]]; then
        warn "  Could not derive age public key -- run hydrix-sops-setup after reboot"
        return 0
    fi
    log "  Host age public key: $host_pubkey"

    local sops_yaml="$CONFIG_DIR/secrets/.sops.yaml"
    mkdir -p "$CONFIG_DIR/secrets"

    # copy_template_secrets() seeds secrets/.sops.yaml from the unedited
    # templates/secrets/.sops.yaml stub, which contains the literal
    # placeholder below -- distinguish that from a real, already-keyed repo.
    if [[ -f "$sops_yaml" ]] && ! grep -q "REPLACE_WITH_OUTPUT_OF_SOPS_AGE_PUBKEY" "$sops_yaml" 2>/dev/null; then
        # Existing repo: this is an additional machine. Do not touch already
        # encrypted files -- the caller cannot decrypt them yet.
        if grep -qF "$host_pubkey" "$sops_yaml"; then
            success "  This machine's age key is already in secrets/.sops.yaml"
        else
            awk -v key="$host_pubkey" '
                /^[[:space:]]+-[[:space:]]+age1/ { last=NR; indent=$0; sub(/-[^-].*/, "", indent) }
                { lines[NR]=$0 }
                END {
                    for (i=1; i<=NR; i++) {
                        print lines[i]
                        if (i==last) print indent "- " key
                    }
                }
            ' "$sops_yaml" > "${sops_yaml}.tmp" && mv "${sops_yaml}.tmp" "$sops_yaml"
            log "  Added this machine to existing secrets/.sops.yaml"

            if [[ -f "$CONFIG_DIR/secrets/master-age-key.age" ]]; then
                echo ""
                log "  Found secrets/master-age-key.age -- unlocking it decrypts"
                log "  secrets on this machine right away, no sops updatekeys needed."
                read -p "  Unlock master key now? [Y/n]: " unlock_yn
                if [[ "${unlock_yn:-y}" =~ ^[Yy] ]]; then
                    echo "  (Enter the master key passphrase)"
                    local tmpunlock age_ok=0
                    tmpunlock=$(mktemp)
                    if command -v age &>/dev/null; then
                        age -d -o "$tmpunlock" "$CONFIG_DIR/secrets/master-age-key.age" && age_ok=1 || true
                    else
                        nix run --no-write-lock-file nixpkgs#age -- \
                            -d -o "$tmpunlock" "$CONFIG_DIR/secrets/master-age-key.age" && age_ok=1 || true
                    fi
                    if [[ $age_ok -eq 1 ]]; then
                        sudo mkdir -p /var/lib/sops-nix
                        sudo chmod 700 /var/lib/sops-nix
                        sudo cp "$tmpunlock" /var/lib/sops-nix/master-age-key.txt
                        sudo chmod 600 /var/lib/sops-nix/master-age-key.txt
                        log "  Master key unlocked -- secrets decrypt after this switch."
                    else
                        warn "  Decryption failed. Run 'hydrix-sops-setup --unlock' later."
                    fi
                    rm -f "$tmpunlock"
                fi
            else
                log ""
                log "  IMPORTANT: existing secrets are not yet re-keyed for this machine."
                log "  From a machine that can already decrypt, run:"
                log "    cd ~/hydrix-config/secrets && sops updatekeys --yes wifi.yaml github.yaml"
                log "    git add secrets/ && git commit -m 'feat(secrets): add ${CONFIG[serial]} as recipient' && git push"
                log "  Then here: cd $CONFIG_DIR && git pull"
            fi
        fi
    else
        # Fresh repo (or unedited template stub): create/overwrite
        # secrets/.sops.yaml and encrypt WiFi/GitHub credentials from scratch.
        printf 'creation_rules:\n  - path_regex: .*\\.yaml$\n    age:\n      - %s\n' \
            "$host_pubkey" > "$sops_yaml"
        log "  Created secrets/.sops.yaml"

        local master_pubkey=""
        echo ""
        log "  A master key lets new machines decrypt secrets immediately on clone,"
        log "  no 'sops updatekeys' round-trip from an existing machine required."
        read -p "  Generate a password-protected master key now? [Y/n]: " master_yn
        if [[ "${master_yn:-y}" =~ ^[Yy] ]]; then
            local master_tmp
            master_tmp=$(mktemp)
            rm -f "$master_tmp"
            if nix shell --no-write-lock-file nixpkgs#age -c age-keygen -o "$master_tmp" 2>/dev/null; then
                master_pubkey=$(nix shell --no-write-lock-file nixpkgs#age -c age-keygen -y "$master_tmp" 2>/dev/null)
                echo ""
                echo "  Set a passphrase to protect the master key."
                echo "  You will need this passphrase when setting up new machines or reinstalling."
                echo ""
                if nix shell --no-write-lock-file nixpkgs#age -c age --passphrase \
                       -o "$CONFIG_DIR/secrets/master-age-key.age" "$master_tmp"; then
                    sudo mkdir -p /var/lib/sops-nix
                    sudo chmod 700 /var/lib/sops-nix
                    sudo cp "$master_tmp" /var/lib/sops-nix/master-age-key.txt
                    sudo chmod 600 /var/lib/sops-nix/master-age-key.txt
                    printf '      - %s\n' "$master_pubkey" >> "$sops_yaml"
                    log "  Master key generated: secrets/master-age-key.age"
                else
                    warn "  Master key encryption failed, continuing with the SSH-derived key only"
                    master_pubkey=""
                fi
            else
                warn "  Could not generate master key, continuing with the SSH-derived key only"
            fi
            rm -f "$master_tmp"
        fi

        local recipients="$host_pubkey"
        [[ -n "$master_pubkey" ]] && recipients="$host_pubkey,$master_pubkey"

        local machine_nix="$CONFIG_DIR/machines/${CONFIG[serial]}.nix"

        # Encrypt WiFi credentials captured earlier by prompt_wifi()
        if [[ -n "${CONFIG[wifiSsid]:-}" ]] && [[ -n "${CONFIG[wifiPassword]:-}" ]]; then
            local ssid_esc psk_esc
            ssid_esc=$(printf '%s' "${CONFIG[wifiSsid]}"     | sed 's/\\/\\\\/g; s/"/\\"/g')
            psk_esc=$(printf  '%s' "${CONFIG[wifiPassword]}" | sed 's/\\/\\\\/g; s/"/\\"/g')
            local plain_yaml
            plain_yaml=$(mktemp --suffix=.yaml)
            printf 'networks: "[{\\"ssid\\": \\"%s\\", \\"psk\\": \\"%s\\", \\"priority\\": 50}]"\n' \
                "$ssid_esc" "$psk_esc" > "$plain_yaml"

            if SOPS_AGE_RECIPIENTS="$recipients" \
               nix run --no-write-lock-file nixpkgs#sops -- \
                   --encrypt "$plain_yaml" > "$CONFIG_DIR/secrets/wifi.yaml" 2>/dev/null; then
                rm -f "$plain_yaml"
                log "  WiFi credentials encrypted to secrets/wifi.yaml"
                sed -i 's/      enable = false;/      enable = true;/' "$machine_nix"
                sed -i \
                    's|# wifiSecretsFile   = ../secrets/wifi.yaml;|wifiSecretsFile = ../secrets/wifi.yaml;|' \
                    "$machine_nix"
                sed -i \
                    "s|\"microvm-router-${CONFIG[serial]}\" = { autostart = true; };|\"microvm-router-${CONFIG[serial]}\" = { autostart = true; secrets = [ \"wifi\" ]; };|" \
                    "$machine_nix"
            else
                rm -f "$plain_yaml"
                warn "  sops encryption failed, add WiFi credentials later with: wifi-sync add SSID PASSWORD"
            fi
        fi

        # Dedicated SSH deploy key for microvm-gitsync (offline lockdown
        # push/pull). Registering the public key with GitHub stays a manual
        # step, by design.
        echo ""
        log "  A dedicated SSH deploy key lets microvm-gitsync push/pull this repo"
        log "  offline. You add the printed public key to GitHub yourself afterward."
        read -p "  Generate an SSH deploy key for gitsync now? [Y/n]: " deploy_yn
        if [[ "${deploy_yn:-y}" =~ ^[Yy] ]]; then
            local deploy_tmp
            deploy_tmp=$(mktemp)
            rm -f "$deploy_tmp"
            if ssh-keygen -t ed25519 -f "$deploy_tmp" -N "" -C "hydrix-gitsync-${CONFIG[serial]}" -q; then
                local plain_gh_yaml
                plain_gh_yaml=$(mktemp --suffix=.yaml)
                {
                    echo "id_ed25519: |"
                    sed 's/^/    /' "$deploy_tmp"
                    printf 'id_ed25519_pub: "%s"\n' "$(cat "$deploy_tmp.pub")"
                } > "$plain_gh_yaml"

                if SOPS_AGE_RECIPIENTS="$recipients" \
                   nix run --no-write-lock-file nixpkgs#sops -- \
                       --encrypt "$plain_gh_yaml" > "$CONFIG_DIR/secrets/github.yaml" 2>/dev/null; then
                    rm -f "$plain_gh_yaml"
                    sed -i 's/      enable = false;/      enable = true;/' "$machine_nix"
                    sed -i \
                        's|# githubSecretsFile = ../secrets/github.yaml;|githubSecretsFile = ../secrets/github.yaml;|' \
                        "$machine_nix"
                    sed -i \
                        's|# "microvm-gitsync"  = { secrets = \[ "github" \]; };|"microvm-gitsync" = { secrets = [ "github" ]; };|' \
                        "$machine_nix"
                    echo ""
                    echo "  Deploy key generated. Add this public key to GitHub (github.com/settings/keys):"
                    echo "    $(cat "$deploy_tmp.pub")"
                else
                    rm -f "$plain_gh_yaml"
                    warn "  sops encryption failed, deploy key not saved."
                fi
            else
                warn "  Could not generate SSH deploy key"
            fi
            shred -u "$deploy_tmp" "$deploy_tmp.pub" 2>/dev/null || rm -f "$deploy_tmp" "$deploy_tmp.pub"
        fi

        echo ""
        echo "  Generate a personal age key (works across machines, bridge until Yubikey):"
        echo "    hydrix-sops-setup --gen-key"
        echo ""
        echo "  Commit the sops config:"
        echo "    cd $CONFIG_DIR && git add -f secrets/ machines/${CONFIG[serial]}.nix && git commit -m 'feat(secrets): init sops'"
    fi

    success "  Sops initialized"
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
    # SOPS & WIFI SECRETS
    # =========================================================================
    # Runs before the build/switch below so a switch failure can never
    # discard the WiFi credentials prompt_wifi() already captured.
    init_sops_and_wifi

    # =========================================================================
    # BUILD & APPLY
    # =========================================================================

    echo ""
    log "=== Building System ==="
    echo ""
    echo "This will:"
    echo "  1. Validate the configuration"
    echo "  2. Build microvm-router-${CONFIG[serial]} VM"
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
        echo "  nix build .#nixosConfigurations.microvm-router-${CONFIG[serial]}.config.microvm.declaredRunner"
        echo "  nix build .#nixosConfigurations.microvm-builder.config.microvm.declaredRunner"
        echo "  rebuild"
        echo ""
        return 0
    fi

    local flake_ref="path:${CONFIG_DIR}"

    # --- Step 1: Validate host config only ---
    # nix flake check evaluates ALL outputs (packages, every VM) which is slow and
    # hits outputs irrelevant to setup. Match what rebuild actually does: eval the
    # host nixosConfiguration toplevel only.
    log "Validating configuration..."
    if ! nix eval "${flake_ref}#nixosConfigurations.${CONFIG[serial]}.config.system.build.toplevel" \
         --no-write-lock-file >/dev/null 2>&1; then
        error "Host evaluation failed. Fix errors in $CONFIG_DIR/machines/${CONFIG[serial]}.nix and rebuild manually."
    fi
    success "Configuration valid"

    # --- Step 2: Build microvm-router ---
    local router_name="microvm-router-${CONFIG[serial]}"
    log "Building ${router_name}..."
    local router_out="/tmp/${router_name}"
    if nix build "${flake_ref}#nixosConfigurations.${router_name}.config.microvm.declaredRunner" \
         -o "$router_out" 2>&1; then
        local router_store
        router_store=$(readlink -f "$router_out")
        sudo mkdir -p /var/lib/microvms/${router_name}/config
        sudo chown microvm:kvm /var/lib/microvms/${router_name} 2>/dev/null || true
        sudo chown root:root /var/lib/microvms/${router_name}/config 2>/dev/null || true
        sudo chmod 755 /var/lib/microvms/${router_name} /var/lib/microvms/${router_name}/config
        sudo ln -sfn "$router_store" /var/lib/microvms/${router_name}/current
        success "${router_name} built: $router_store"
    else
        warn "${router_name} build failed (WiFi may not be configured yet)"
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
    echo "  walrgb ~/wallpapers/Hydrix.png"
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
    # This script runs as a plain user (sudo only for specific privileged steps),
    # and /var/log is root-owned on every NixOS system -- log to /tmp like
    # install-hydrix.sh does, then best-effort copy it into /var/log/hydrix
    # afterward via sudo so it persists in the same place either way.
    HYDRIX_LOG="/tmp/hydrix-setup-$(date +%Y%m%d-%H%M%S).log"
    echo "Logging to: $HYDRIX_LOG"
    exec > >(tee -a "$HYDRIX_LOG") 2>&1
    main "$@"
    if sudo -n true 2>/dev/null; then
        sudo mkdir -p /var/log/hydrix
        sudo cp "$HYDRIX_LOG" /var/log/hydrix/
        echo "Setup log saved to /var/log/hydrix/$(basename "$HYDRIX_LOG")"
    fi
}
