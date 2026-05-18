#!/usr/bin/env bash
# common.sh - Shared functions for Hydrix setup and install scripts
#
# Source this file: source "$(dirname "$0")/lib/common.sh"

# Prevent double-sourcing
[[ -n "${_HYDRIX_COMMON_SOURCED:-}" ]] && return
_HYDRIX_COMMON_SOURCED=1

# ========== LOGGING ==========

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
success() { echo "[SUCCESS] $*"; }
warn() { echo "[WARN] $*"; }

# ========== COLORS (for interactive prompts) ==========

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

# ========== SYSTEM DETECTION ==========

detect_hostname() {
    local hostname
    hostname=$(hostnamectl hostname 2>/dev/null || hostname)

    # Sanitize hostname for use in Nix identifiers
    hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')

    if [[ -z "$hostname" ]]; then
        echo "nixos"
    else
        echo "$hostname"
    fi
}

detect_cpu_platform() {
    # Returns "intel" or "amd" based on CPU vendor
    local cpu_vendor
    cpu_vendor=$(grep -m1 "vendor_id" /proc/cpuinfo 2>/dev/null | awk '{print $3}')

    case "$cpu_vendor" in
        GenuineIntel) echo "intel" ;;
        AuthenticAMD) echo "amd" ;;
        *) echo "intel" ;;  # Default to intel
    esac
}

get_iommu_param() {
    local platform="$1"
    case "$platform" in
        intel) echo "intel_iommu=on" ;;
        amd) echo "amd_iommu=on" ;;
        *) echo "intel_iommu=on" ;;
    esac
}

detect_asus_system() {
    local vendor
    vendor=$(hostnamectl 2>/dev/null | grep "Hardware Vendor" | cut -d: -f2 | xargs || echo "")

    if echo "$vendor" | grep -qi "asus"; then
        echo "true"
    else
        echo "false"
    fi
}

detect_current_user() {
    # Get the user who invoked the script (even if running with sudo)
    local user
    if [[ -n "${SUDO_USER:-}" ]]; then
        user="$SUDO_USER"
    else
        user="$(whoami)"
    fi

    # Don't allow root as the detected user
    if [[ "$user" == "root" ]] || [[ -z "$user" ]]; then
        echo "user"  # Default fallback
    else
        echo "$user"
    fi
}

# ========== HARDWARE SERIAL DETECTION ==========
# Machine identification based on hardware serial numbers.
# Config files are named machines/<serial>.nix for reliable reinstall detection.

# Check if a serial number is invalid/placeholder
is_invalid_serial() {
    local serial="$1"
    local lower
    lower=$(echo "$serial" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        ""|\
        "to be filled by o.e.m."|\
        "to be filled by o.e.m"|\
        "default string"|\
        "system serial number"|\
        "not specified"|\
        "none"|\
        "n/a"|\
        "na"|\
        "unknown"|\
        "undefined"|\
        "chassis serial number"|\
        "type2 - board serial number")
            return 0 ;;
    esac

    # All zeros is invalid
    [[ "$lower" =~ ^0+$ ]] && return 0

    return 1
}

# Get raw serial from DMI (system, board, or chassis)
get_raw_serial() {
    local serial=""

    # Try dmidecode first (most reliable, but needs root)
    if command -v dmidecode &>/dev/null; then
        serial=$(sudo dmidecode -s system-serial-number 2>/dev/null | head -1 | xargs)
    fi

    # Try sysfs sources in order of preference
    for path in /sys/class/dmi/id/product_serial \
                /sys/class/dmi/id/board_serial \
                /sys/class/dmi/id/chassis_serial; do
        if [[ -z "$serial" ]] || is_invalid_serial "$serial"; then
            serial=$(cat "$path" 2>/dev/null | xargs || echo "")
        else
            break
        fi
    done

    echo "$serial"
}

# Sanitize serial for use as Nix identifier and filename
# - Lowercase
# - Replace spaces/underscores with hyphens
# - Remove special characters
# - Ensure starts with alphanumeric
# - Truncate to 63 chars (DNS label limit)
sanitize_serial() {
    local s="$1"

    # Lowercase and replace spaces/underscores with hyphens
    s=$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr ' _' '-')

    # Remove anything that's not alphanumeric or hyphen
    s=$(echo "$s" | sed 's/[^a-z0-9-]//g')

    # Collapse multiple hyphens and trim from ends
    s=$(echo "$s" | sed 's/-\+/-/g; s/^-//; s/-$//')

    # Ensure starts with alphanumeric (prepend 'h-' if needed)
    if [[ -n "$s" ]] && [[ ! "$s" =~ ^[a-z0-9] ]]; then
        s="h-$s"
    fi

    # Truncate to 63 chars (max DNS label length) and remove trailing hyphen
    echo "${s:0:63}" | sed 's/-$//'
}

# Detect hardware serial and return sanitized version
# Returns "unknown-machine" on failure
detect_serial() {
    local raw
    raw=$(get_raw_serial)

    if [[ -z "$raw" ]] || is_invalid_serial "$raw"; then
        echo "unknown-machine"
        return 1
    fi

    sanitize_serial "$raw"
}

# Generate fallback machine ID from board/product name
# Used when no valid serial is available
generate_fallback_id() {
    local id=""

    # Try board name first
    id=$(cat /sys/class/dmi/id/board_name 2>/dev/null | xargs || echo "")
    id=$(echo "$id" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | sed 's/[^a-z0-9-]//g')

    if [[ -n "$id" ]] && [[ "$id" != "default-string" ]] && [[ "$id" != "not-applicable" ]]; then
        echo "mb-${id:0:50}"
        return
    fi

    # Try product name
    id=$(cat /sys/class/dmi/id/product_name 2>/dev/null | xargs || echo "")
    id=$(echo "$id" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | sed 's/[^a-z0-9-]//g')

    if [[ -n "$id" ]] && [[ "$id" != "default-string" ]] && [[ "$id" != "not-applicable" ]]; then
        echo "prod-${id:0:50}"
        return
    fi

    # Last resort: random suffix
    echo "hydrix-$(head -c 4 /dev/urandom | xxd -p)"
}

# Check if a machine identifier is valid
# Returns 0 if valid, 1 with warning message if invalid
check_serial() {
    local s="$1"

    if [[ -z "$s" ]]; then
        warn "Machine identifier cannot be empty"
        return 1
    fi

    if [[ ${#s} -gt 63 ]]; then
        warn "Machine identifier too long (max 63 chars, got ${#s})"
        return 1
    fi

    # Must match DNS label format: start/end with alphanumeric, hyphens in between
    if [[ ! "$s" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        warn "Invalid identifier format: must be lowercase alphanumeric with hyphens, start/end with alphanumeric"
        return 1
    fi

    return 0
}

# ========== LOCALE DETECTION ==========

detect_timezone() {
    # Try timedatectl first
    local tz
    tz=$(timedatectl show -p Timezone --value 2>/dev/null)

    if [[ -n "$tz" ]]; then
        echo "$tz"
        return
    fi

    # Try /etc/localtime symlink
    if [[ -L /etc/localtime ]]; then
        tz=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
        if [[ -n "$tz" ]]; then
            echo "$tz"
            return
        fi
    fi

    # Default
    echo "UTC"
}

detect_locale() {
    # Check LANG environment variable
    if [[ -n "${LANG:-}" ]]; then
        echo "$LANG"
        return
    fi

    # Try locale command
    local loc
    loc=$(locale 2>/dev/null | grep "^LANG=" | cut -d= -f2)
    if [[ -n "$loc" ]]; then
        echo "$loc"
        return
    fi

    # Default
    echo "en_US.UTF-8"
}

detect_console_keymap() {
    # Try to read from /etc/vconsole.conf
    if [[ -f /etc/vconsole.conf ]]; then
        local keymap
        keymap=$(grep "^KEYMAP=" /etc/vconsole.conf 2>/dev/null | cut -d= -f2)
        if [[ -n "$keymap" ]]; then
            echo "$keymap"
            return
        fi
    fi

    # Default
    echo "us"
}

detect_xkb_layout() {
    # Try setxkbmap
    local layout
    layout=$(setxkbmap -query 2>/dev/null | grep "^layout:" | awk '{print $2}')
    if [[ -n "$layout" ]]; then
        echo "$layout"
        return
    fi

    # Default
    echo "us"
}

detect_xkb_variant() {
    # Try setxkbmap
    local variant
    variant=$(setxkbmap -query 2>/dev/null | grep "^variant:" | awk '{print $2}')
    echo "${variant:-}"  # Can be empty
}

# Parse a simple Nix value from a configuration file
# Usage: parse_nix_value "time.timeZone" "/etc/nixos/configuration.nix"
parse_nix_value() {
    local key="$1"
    local file="${2:-/etc/nixos/configuration.nix}"

    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi

    # Match patterns like: time.timeZone = "Europe/Stockholm";
    local value
    value=$(grep -E "^\s*${key}\s*=" "$file" 2>/dev/null | head -1 | sed 's/.*=\s*"\([^"]*\)".*/\1/')
    echo "$value"
}

# ========== PASSWORD HANDLING ==========

prompt_password() {
    local prompt="${1:-Enter password}"
    local min_length="${2:-8}"
    local password=""
    local password_confirm=""

    while true; do
        read -sp "$prompt: " password
        echo ""

        if [[ -z "$password" ]]; then
            warn "Password cannot be empty"
            continue
        fi

        if [[ ${#password} -lt $min_length ]]; then
            warn "Password must be at least $min_length characters"
            continue
        fi

        read -sp "Confirm password: " password_confirm
        echo ""

        if [[ "$password" != "$password_confirm" ]]; then
            warn "Passwords do not match, try again"
            continue
        fi

        break
    done

    # Return via stdout
    echo "$password"
}

hash_password() {
    local password="$1"

    # Try mkpasswd first (preferred)
    if command -v mkpasswd &>/dev/null; then
        echo "$password" | mkpasswd -m sha-512 -s
        return
    fi

    # Fallback to openssl
    if command -v openssl &>/dev/null; then
        local salt
        salt=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
        openssl passwd -6 -salt "$salt" "$password"
        return
    fi

    error "Neither mkpasswd nor openssl available - cannot hash password"
}

# ========== WIFI DETECTION ==========

detect_wifi_ssid() {
    # Get the currently connected WiFi SSID using nmcli
    local ssid
    ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2)

    if [[ -z "$ssid" ]]; then
        # Try iwgetid
        ssid=$(iwgetid -r 2>/dev/null)
    fi

    echo "$ssid"
}

prompt_wifi_credentials() {
    local detected_ssid="${1:-}"
    local ssid=""
    local password=""

    echo ""
    log "========================================"
    log "  WIFI CONFIGURATION"
    log "========================================"
    echo ""
    log "The router VM needs WiFi credentials to connect after reboot."
    echo ""

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
            WIFI_SSID=""
            WIFI_PASSWORD=""
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

    # Return values via global variables
    WIFI_SSID="$ssid"
    WIFI_PASSWORD="$password"
    return 0
}

# ========== INPUT VALIDATION ==========
# Prevent injection attacks by validating user inputs before use in Nix code/shell commands
#
# Two variants for each validation:
#   validate_X()  - Calls error() and exits on failure (for mandatory validation)
#   check_X()     - Prints warning and returns 1 on failure (for interactive prompts)

# Check hostname (RFC 1123 compliant) - returns status, prints error message
# Must be lowercase alphanumeric with hyphens, 1-63 chars, start/end with alphanumeric
check_hostname() {
    local hostname="$1"
    local context="${2:-hostname}"

    if [[ -z "$hostname" ]]; then
        warn "Invalid $context: cannot be empty"
        return 1
    fi

    if [[ ${#hostname} -gt 63 ]]; then
        warn "Invalid $context: must be 63 characters or less (got ${#hostname})"
        return 1
    fi

    if [[ ! "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        warn "Invalid $context '$hostname': must be lowercase alphanumeric with hyphens, start/end with alphanumeric"
        return 1
    fi

    return 0
}

# Validate hostname - exits on failure
validate_hostname() {
    local hostname="$1"
    local context="${2:-hostname}"

    if ! check_hostname "$hostname" "$context"; then
        exit 1
    fi
}

# Check VM name (libvirt/qemu compatible) - returns status
check_vm_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        warn "Invalid VM name: cannot be empty"
        return 1
    fi

    if [[ ${#name} -gt 64 ]]; then
        warn "Invalid VM name: must be 64 characters or less (got ${#name})"
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        warn "Invalid VM name '$name': must be alphanumeric with underscore/hyphen, start with alphanumeric"
        return 1
    fi

    return 0
}

# Validate VM name - exits on failure
validate_vm_name() {
    local name="$1"

    if ! check_vm_name "$name"; then
        exit 1
    fi
}

# Check username (Unix compatible) - returns status
check_username() {
    local username="$1"

    if [[ -z "$username" ]]; then
        warn "Invalid username: cannot be empty"
        return 1
    fi

    if [[ ${#username} -gt 32 ]]; then
        warn "Invalid username: must be 32 characters or less (got ${#username})"
        return 1
    fi

    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        warn "Invalid username '$username': must be lowercase alphanumeric with underscore, start with letter or underscore"
        return 1
    fi

    # Disallow reserved usernames
    local reserved=("root" "daemon" "bin" "sys" "sync" "games" "man" "lp" "mail" "news" "nobody")
    local u
    for u in "${reserved[@]}"; do
        if [[ "$username" == "$u" ]]; then
            warn "Invalid username '$username': reserved system username"
            return 1
        fi
    done

    return 0
}

# Validate username - exits on failure
validate_username() {
    local username="$1"

    if ! check_username "$username"; then
        exit 1
    fi
}

# Check a string that will be interpolated into Nix code - returns status
check_nix_string() {
    local value="$1"
    local context="${2:-value}"

    if [[ -z "$value" ]]; then
        # Empty is allowed for optional fields
        return 0
    fi

    # Check for characters that break Nix string interpolation
    # " - closes the string
    # $ - starts interpolation (${...})
    # ` - legacy interpolation
    if [[ "$value" =~ [\"\$\`] ]]; then
        warn "Invalid $context: contains characters that break Nix syntax (\", \$, \`)"
        return 1
    fi

    if [[ "$value" =~ $'\n' ]] || [[ "$value" =~ $'\r' ]]; then
        warn "Invalid $context: contains newlines"
        return 1
    fi

    # Check for backslash escape sequences that could be interpreted
    if [[ "$value" =~ \\[nrt\"\$\\] ]]; then
        warn "Invalid $context: contains escape sequences"
        return 1
    fi

    return 0
}

# Validate a string for Nix interpolation - exits on failure
validate_nix_string() {
    local value="$1"
    local context="${2:-value}"

    if ! check_nix_string "$value" "$context"; then
        exit 1
    fi
}

# Check flake URL format - returns status
check_flake_url() {
    local url="$1"

    if [[ -z "$url" ]]; then
        warn "Invalid flake URL: cannot be empty"
        return 1
    fi

    # Check for shell metacharacters that could enable injection
    if [[ "$url" =~ [\;\|\&\>\<\`\$\(\)\{\}\[\]\!\#\~] ]]; then
        warn "Invalid flake URL: contains shell metacharacters"
        return 1
    fi

    # Whitelist valid flake URL formats
    if [[ "$url" =~ ^github:[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+(/[a-zA-Z0-9._/-]+)?(\?[a-zA-Z0-9._=&-]+)?$ ]]; then
        return 0  # github:owner/repo or github:owner/repo/path?ref=...
    fi

    if [[ "$url" =~ ^git\+https://[a-zA-Z0-9._/-]+(\?[a-zA-Z0-9._=&-]+)?$ ]]; then
        return 0  # git+https://...
    fi

    if [[ "$url" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        return 0  # https://github.com/owner/repo
    fi

    if [[ "$url" =~ ^path:[a-zA-Z0-9._/-]+$ ]]; then
        return 0  # path:/some/path
    fi

    if [[ "$url" =~ ^/[a-zA-Z0-9._/-]+$ ]] && [[ -d "$url" ]]; then
        return 0  # /absolute/path (must exist)
    fi

    if [[ "$url" =~ ^\./[a-zA-Z0-9._/-]*$ ]] || [[ "$url" == "." ]]; then
        return 0  # ./relative/path or .
    fi

    warn "Invalid flake URL format: '$url'
Valid formats: github:owner/repo, git+https://..., /absolute/path"
    return 1
}

# Validate flake URL - exits on failure
validate_flake_url() {
    local url="$1"

    if ! check_flake_url "$url"; then
        exit 1
    fi
}

# Check colorscheme name - returns status
check_colorscheme() {
    local scheme="$1"
    local hydrix_dir="${2:-}"

    if [[ -z "$scheme" ]]; then
        warn "Invalid colorscheme: cannot be empty"
        return 1
    fi

    # Basic format check
    if [[ ! "$scheme" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        warn "Invalid colorscheme '$scheme': must be alphanumeric with underscore/hyphen"
        return 1
    fi

    # If hydrix_dir provided, check colorscheme exists
    if [[ -n "$hydrix_dir" ]]; then
        local colorscheme_file="$hydrix_dir/colorschemes/${scheme}.json"
        if [[ ! -f "$colorscheme_file" ]]; then
            local available
            available=$(ls -1 "$hydrix_dir/colorschemes/"*.json 2>/dev/null | xargs -n1 basename | sed 's/\.json$//' | tr '\n' ' ')
            warn "Invalid colorscheme '$scheme': not found. Available: $available"
            return 1
        fi
    fi

    return 0
}

# Validate colorscheme - exits on failure
validate_colorscheme() {
    local scheme="$1"
    local hydrix_dir="${2:-}"

    if ! check_colorscheme "$scheme" "$hydrix_dir"; then
        exit 1
    fi
}

# Check WiFi SSID - returns status
check_wifi_ssid() {
    local ssid="$1"

    if [[ -z "$ssid" ]]; then
        # Empty SSID is allowed (user may configure later)
        return 0
    fi

    if [[ ${#ssid} -gt 32 ]]; then
        warn "Invalid WiFi SSID: must be 32 characters or less (got ${#ssid})"
        return 1
    fi

    # Check for control characters (but allow spaces and most printable chars)
    if [[ "$ssid" =~ [[:cntrl:]] ]]; then
        warn "Invalid WiFi SSID: contains control characters"
        return 1
    fi

    # For Nix interpolation safety
    if ! check_nix_string "$ssid" "WiFi SSID"; then
        return 1
    fi

    return 0
}

# Validate WiFi SSID - exits on failure
validate_wifi_ssid() {
    local ssid="$1"

    if ! check_wifi_ssid "$ssid"; then
        exit 1
    fi
}

# Check WiFi password (WPA2/WPA3) - returns status
check_wifi_password() {
    local password="$1"

    if [[ -z "$password" ]]; then
        # Empty password is allowed (user may configure later)
        return 0
    fi

    if [[ ${#password} -lt 8 ]]; then
        warn "Invalid WiFi password: WPA2 requires at least 8 characters"
        return 1
    fi

    if [[ ${#password} -gt 63 ]]; then
        warn "Invalid WiFi password: WPA2 allows maximum 63 characters"
        return 1
    fi

    # For Nix interpolation safety
    if ! check_nix_string "$password" "WiFi password"; then
        return 1
    fi

    return 0
}

# Validate WiFi password - exits on failure
validate_wifi_password() {
    local password="$1"

    if ! check_wifi_password "$password"; then
        exit 1
    fi
}

# Check disk path (for disko operations) - returns status
check_disk_path() {
    local disk="$1"

    if [[ -z "$disk" ]]; then
        warn "Invalid disk: cannot be empty"
        return 1
    fi

    # Must be a block device path
    if [[ ! "$disk" =~ ^/dev/[a-zA-Z0-9/_-]+$ ]]; then
        warn "Invalid disk path '$disk': must be a /dev/... path"
        return 1
    fi

    # Check it exists and is a block device
    if [[ ! -b "$disk" ]]; then
        warn "Invalid disk '$disk': not a block device"
        return 1
    fi

    return 0
}

# Validate disk path - exits on failure
validate_disk_path() {
    local disk="$1"

    if ! check_disk_path "$disk"; then
        exit 1
    fi
}

# Sanitize a string for safe shell interpolation (removes dangerous chars)
# Use this when you can't reject input but need to make it safe
# Returns: sanitized string via stdout
sanitize_for_shell() {
    local input="$1"
    # Remove shell metacharacters
    echo "$input" | tr -d '";`$\\(){}[]<>|&!#~\n\r'
}

# Sanitize a string for Nix string interpolation
# Returns: sanitized string via stdout
sanitize_for_nix() {
    local input="$1"
    # Remove Nix-dangerous characters
    echo "$input" | tr -d '"\$`\\\n\r' | tr -d "'"
}

# ========== UTILITY FUNCTIONS ==========

# Check if running from live media (for install script safety)
is_live_environment() {
    # Check common indicators of live environments
    if [[ -d /run/live ]] || [[ -f /run/live/medium/live ]] || [[ -d /run/archiso ]]; then
        return 0
    fi

    # Check if root is tmpfs/overlayfs (common in live environments)
    local root_fs
    root_fs=$(stat -f -c %T / 2>/dev/null || echo "")
    if [[ "$root_fs" == "tmpfs" ]] || [[ "$root_fs" == "overlayfs" ]]; then
        return 0
    fi

    # Check for NixOS live installer
    if [[ -f /etc/nixos-version ]] && mount | grep -q "on / type tmpfs"; then
        return 0
    fi

    return 1
}

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Ensure required commands exist
require_commands() {
    local missing=()
    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required commands: ${missing[*]}"
    fi
}


# ========== BTRFS / REFLINK SUPPORT ==========

# Check if a path is on a BTRFS filesystem
# Usage: is_btrfs "/var/lib/libvirt/images"
is_btrfs() {
    local path="$1"

    # Resolve to actual mountpoint if path doesn't exist yet
    local check_path="$path"
    while [[ ! -e "$check_path" ]] && [[ "$check_path" != "/" ]]; do
        check_path=$(dirname "$check_path")
    done

    local fs_type
    fs_type=$(stat -f -c %T "$check_path" 2>/dev/null)
    [[ "$fs_type" == "btrfs" ]]
}

# Check if reflinks are supported (BTRFS or XFS with reflink)
# Usage: supports_reflink "/var/lib/libvirt/images"
supports_reflink() {
    local path="$1"

    # Resolve to actual mountpoint if path doesn't exist yet
    local check_path="$path"
    while [[ ! -e "$check_path" ]] && [[ "$check_path" != "/" ]]; do
        check_path=$(dirname "$check_path")
    done

    local fs_type
    fs_type=$(stat -f -c %T "$check_path" 2>/dev/null)

    case "$fs_type" in
        btrfs)
            return 0
            ;;
        xfs)
            # XFS supports reflinks if formatted with reflink=1 (default since xfsprogs 5.1)
            # Test by attempting a reflink copy
            local test_file
            test_file=$(mktemp -p "$check_path" .reflink-test-XXXXXX 2>/dev/null) || return 1
            local test_copy="${test_file}.copy"
            if cp --reflink=always "$test_file" "$test_copy" 2>/dev/null; then
                rm -f "$test_file" "$test_copy"
                return 0
            fi
            rm -f "$test_file" "$test_copy" 2>/dev/null
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Copy a file using reflinks if available, falling back to regular copy
# Usage: smart_copy source dest [--reflink-only]
# Returns: 0 on success, 1 on failure
# With --reflink-only, fails if reflink is not available (no fallback)
smart_copy() {
    local source="$1"
    local dest="$2"
    local reflink_only="${3:-}"

    if [[ ! -f "$source" ]]; then
        error "Source file does not exist: $source"
        return 1
    fi

    local dest_dir
    dest_dir=$(dirname "$dest")

    if supports_reflink "$dest_dir"; then
        log "Using reflink copy (instant, space-efficient)"
        if cp --reflink=always "$source" "$dest" 2>/dev/null; then
            return 0
        fi
        # Reflink failed (maybe cross-device), try auto
        if cp --reflink=auto "$source" "$dest" 2>/dev/null; then
            log "Reflink not possible (cross-device?), used regular copy"
            return 0
        fi
    fi

    if [[ "$reflink_only" == "--reflink-only" ]]; then
        warn "Reflink copy not available and --reflink-only specified"
        return 1
    fi

    log "Using regular copy (reflinks not supported)"
    cp "$source" "$dest"
}

# Get the VM bases directory (for storing base images for reflink cloning)
# Returns: /var/lib/libvirt/bases (Hydrix BTRFS layout) or /var/lib/libvirt/images (fallback)
get_vm_bases_dir() {
    local bases_dir="/var/lib/libvirt/bases"
    local images_dir="/var/lib/libvirt/images"

    # Check if dedicated bases directory exists (Hydrix BTRFS layout)
    if [[ -d "$bases_dir" ]]; then
        echo "$bases_dir"
    else
        echo "$images_dir"
    fi
}

# Check if VM images directory supports reflinks
# Caches the result for performance
vm_images_support_reflink() {
    # Cache the result
    if [[ -n "${_VM_IMAGES_REFLINK_SUPPORT:-}" ]]; then
        [[ "$_VM_IMAGES_REFLINK_SUPPORT" == "yes" ]]
        return $?
    fi

    if supports_reflink "/var/lib/libvirt/images"; then
        _VM_IMAGES_REFLINK_SUPPORT="yes"
        return 0
    else
        _VM_IMAGES_REFLINK_SUPPORT="no"
        return 1
    fi
}
