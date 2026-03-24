#!/usr/bin/env bash
# hydrix-tui.sh - Unified Hydrix VM Management TUI
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SELF_PATH="$(realpath "${BASH_SOURCE[0]}")"

# Detect flake directory (same logic as rebuild script)
detect_flake_dir() {
    if [[ -n "${HYDRIX_FLAKE_DIR:-}" ]] && [[ -f "$HYDRIX_FLAKE_DIR/flake.nix" ]]; then
        echo "$HYDRIX_FLAKE_DIR"
        return
    fi
    if [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
        echo "$HOME/hydrix-config"
        return
    fi
    if [[ -f "$HOME/Hydrix/flake.nix" ]]; then
        echo "$HOME/Hydrix"
        return
    fi
    # Fallback: parent of script directory
    local parent
    parent="$(dirname "$SCRIPT_DIR")"
    if [[ -f "$parent/flake.nix" ]]; then
        echo "$parent"
        return
    fi
    echo "$HOME/Hydrix"  # Last resort default
}

readonly FLAKE_DIR="$(detect_flake_dir)"
readonly BASE_IMAGE_DIR="/var/lib/libvirt/base-images"
readonly XPRA_PORT=14500
readonly PERSIST_BASE="$HOME/persist"
readonly PROFILES_DIR="$FLAKE_DIR/profiles"
readonly VM_TYPES=("browsing" "pentest" "dev")

# Command log file for detailed output
readonly CMD_LOG="/tmp/hydrix-tui-$$.log"
: > "$CMD_LOG"  # Start empty

# Cleanup on exit
trap 'rm -f "$CMD_LOG"' EXIT

# Load pywal colors if available
WAL_COLORS="$HOME/.cache/wal/colors.sh"
if [[ -f "$WAL_COLORS" ]]; then
    # shellcheck source=/dev/null
    set +u  # colors.sh may reference unset variables like LS_COLORS
    source "$WAL_COLORS"
    set -u
else
    # Fallback colors (nord-ish)
    color0="#2E3440"
    color1="#BF616A"
    color2="#A3BE8C"
    color3="#EBCB8B"
    color4="#81A1C1"
    color5="#B48EAD"
    color6="#88C0D0"
    color7="#E5E9F0"
    foreground="#D8DEE9"
    background="#2E3440"
fi

# Convert hex to ANSI true color (24-bit)
hex_to_ansi() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    echo -n "\e[38;2;${r};${g};${b}m"
}

# Colors using pywal (true color ANSI sequences)
RED=$(echo -e "$(hex_to_ansi "$color1")")
GREEN=$(echo -e "$(hex_to_ansi "$color2")")
YELLOW=$(echo -e "$(hex_to_ansi "$color3")")
BLUE=$(echo -e "$(hex_to_ansi "$color4")")
CYAN=$(echo -e "$(hex_to_ansi "$color6")")
MAGENTA=$(echo -e "$(hex_to_ansi "$color5")")
NC=$'\e[0m'
BOLD=$'\e[1m'
DIM=$'\e[2m'

# Stage indicators for devshells
STAGE_DEV="${YELLOW}[dev]${NC}"
STAGE_STG="${CYAN}[stg]${NC}"
STAGE_INS="${GREEN}[ins]${NC}"

# Set fzf colors from pywal
export FZF_DEFAULT_OPTS="--color=fg:${foreground:-$color7},bg:-1,hl:$color5,fg+:${foreground:-$color7},bg+:$color0,hl+:$color5,info:$color6,prompt:$color4,pointer:$color5,marker:$color3,spinner:$color6,header:$color4"

# Terminal - use DPI-aware alacritty
TERMINAL="alacritty-dpi"
command -v alacritty-dpi &>/dev/null || TERMINAL="alacritty"

# Session log - stores recent actions for display
declare -a SESSION_LOG=()
readonly MAX_LOG_ENTRIES=3

log() { echo -e "${CYAN}::${NC} $*"; }
log_ok() { echo -e "${GREEN}::${NC} $*"; }
log_err() { echo -e "${RED}::${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}::${NC} $*"; }

# Run a command, show output live, and log it
run_logged() {
    local exit_code
    "$@" 2>&1 | tee -a "$CMD_LOG"
    exit_code=${PIPESTATUS[0]}
    echo "" >> "$CMD_LOG"
    return $exit_code
}

# Add an action to session log (shown in menus)
log_action() {
    local type="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date +%H:%M:%S)
    local entry
    case "$type" in
        ok)   entry="${GREEN}✓${NC} ${timestamp} ${msg}" ;;
        err)  entry="${RED}✗${NC} ${timestamp} ${msg}" ;;
        warn) entry="${YELLOW}!${NC} ${timestamp} ${msg}" ;;
        info) entry="${BLUE}→${NC} ${timestamp} ${msg}" ;;
        *)    entry="${CYAN}·${NC} ${timestamp} ${msg}" ;;
    esac
    SESSION_LOG+=("$entry")
    # Keep only last N entries
    while [[ ${#SESSION_LOG[@]} -gt $MAX_LOG_ENTRIES ]]; do
        SESSION_LOG=("${SESSION_LOG[@]:1}")
    done
}

# Display session log at bottom of terminal (call before fzf)
show_session_log_bottom() {
    [[ ${#SESSION_LOG[@]} -eq 0 ]] && return

    local term_height
    term_height=$(tput lines)
    local log_lines=${#SESSION_LOG[@]}

    # Move to bottom, print log
    tput cup $((term_height - log_lines - 1)) 0
    echo -e "${DIM}─── Recent ───${NC}"
    for entry in "${SESSION_LOG[@]}"; do
        echo -e "  $entry"
    done
    # Move cursor back to top for fzf
    tput cup 0 0
}

press_enter() {
    echo ""
    read -rp "Press Enter to continue..."
}

run_in_terminal() {
    local title="$1"
    shift
    $TERMINAL --title "$title" -e bash -c "$* ; echo ''; read -rp 'Press Enter to close...'" &
    disown
}

# ========== MICROVM ==========

get_microvms() {
    # Match microvm-* names (excluding router)
    nix eval "$FLAKE_DIR#nixosConfigurations" --apply 'builtins.attrNames' --json 2>/dev/null | \
        jq -r '.[]' | grep -E '^microvm-(browsing|pentest|dev|comms|lurking)' || true
}

microvm_state() {
    local vm="$1"
    if systemctl is-active --quiet "microvm@${vm}.service" 2>/dev/null; then
        echo "running"
    elif [[ -d "/var/lib/microvms/${vm}" ]] && [[ -e "/var/lib/microvms/${vm}/current" ]]; then
        echo "stopped"
    else
        echo "not-built"
    fi
}

microvm_cid() {
    nix eval --json "$FLAKE_DIR#nixosConfigurations.${1}.config.hydrix.microvm.vsockCid" 2>/dev/null || echo ""
}

microvm_build() {
    local vm="$1"
    if run_logged microvm build "$vm"; then
        log_action ok "$vm built"
    else
        log_action err "$vm build failed"
        return 1
    fi
}

microvm_start() {
    local vm="$1"
    if run_logged microvm start "$vm"; then
        log_action ok "$vm started"
    else
        log_action err "$vm start failed"
        return 1
    fi
}

microvm_stop() {
    local vm="$1"
    if run_logged microvm stop "$vm"; then
        log_action ok "$vm stopped"
    else
        log_action err "$vm stop failed"
        return 1
    fi
}

microvm_restart() {
    local vm="$1"
    if run_logged microvm restart "$vm"; then
        log_action ok "$vm restarted"
    else
        log_action err "$vm restart failed"
        return 1
    fi
}

microvm_update() {
    local vm="$1"
    if run_logged microvm update "$vm"; then
        log_action ok "$vm updated (live)"
    else
        log_action err "$vm update failed"
        return 1
    fi
}

microvm_purge() {
    local vm="$1"
    local vm_dir="/var/lib/microvms/${vm}"

    if [[ ! -d "$vm_dir" ]]; then
        log_action warn "No data found for $vm"
        return 0
    fi

    # Show size and confirm
    local total_size
    total_size=$(du -sh "$vm_dir" 2>/dev/null | cut -f1)
    echo -e "${RED}${BOLD}WARNING: This will delete all data for ${vm} (${total_size})!${NC}"
    read -rp "Type 'yes' to confirm: " confirm
    [[ "$confirm" != "yes" ]] && { log_action warn "$vm purge aborted"; return 0; }

    # Use --force since we already confirmed
    if run_logged microvm purge "$vm" --force; then
        log_action ok "$vm purged"
    else
        log_action err "$vm purge failed"
        return 1
    fi
}

microvm_attach() {
    local vm="$1"
    vm-app "$vm" --attach &>/dev/null &
    disown
    log_action ok "Attached to $vm"
}

microvm_app() {
    local vm="$1"
    local apps=("firefox" "alacritty" "chromium" "pcmanfm" "Custom...")

    local app
    app=$(printf '%s\n' "${apps[@]}" | fzf --height=10 --reverse --disabled --no-info --prompt="") || return

    if [[ "$app" == "Custom..." ]]; then
        read -rp "Command: " app
        [[ -z "$app" ]] && return
    fi

    vm-app "$vm" "$app" &
    disown
    log_action ok "Launched $app on $vm"
}

show_microvm_menu() {
    local pinned_vm=""

    while true; do
        # Build list with state prefix for easy parsing
        # Format: STATE|VMNAME (we strip the state for display but use it for icons)
        local entries=()
        local vms=()

        while IFS= read -r vm; do
            [[ -z "$vm" ]] && continue
            vms+=("$vm")
            local state
            state=$(microvm_state "$vm")
            entries+=("${state}|${vm}")
        done < <(get_microvms)

        [[ ${#vms[@]} -eq 0 ]] && { log_action err "No MicroVMs declared"; return; }

        # Add actions
        entries+=("action|Build All")
        entries+=("action|Back")

        # Format for display (convert STATE|NAME to "icon name (state)")
        local display=()
        for entry in "${entries[@]}"; do
            local state="${entry%%|*}"
            local name="${entry#*|}"
            local indent=""
            [[ "$name" == "$pinned_vm" ]] && indent="   "
            case "$state" in
                running)   display+=("${indent}[*] $name (running)") ;;
                stopped)   display+=("${indent}[-] $name (stopped)") ;;
                not-built) display+=("${indent}[?] $name (not-built)") ;;
                action)    display+=("--- $name") ;;
                *)         display+=("${indent}[!] $name ($state)") ;;  # Catch unexpected states
            esac
        done

        clear
        show_session_log_bottom

        # Build header with pin status
        local header="MicroVM Management"
        if [[ -n "$pinned_vm" ]]; then
            header+=$'\n'"Pinned: ${pinned_vm}"
        fi
        header+=$'\n[/]search [space]pin [s]tart [k]ill [u]pdate [r]estart [b]uild [p]urge [a]ttach [l]aunch [C-/]log'

        local sel
        sel=$(printf '%s\n' "${display[@]}" | fzf --height=85% --reverse --ansi \
            --header="$header" \
            --disabled --no-info --expect=/,space,s,k,u,r,b,p,a,l \
            --preview="bash -c 'if [[ -s \"$CMD_LOG\" ]]; then tail -20 \"$CMD_LOG\"; fi'" \
            --preview-window=bottom:5:wrap:hidden \
            --bind='ctrl-/:toggle-preview') || sel=""

        [[ -z "$sel" ]] && return

        # Parse fzf output: first line is key pressed, rest is selection
        local key line
        key=$(echo "$sel" | head -1)
        line=$(echo "$sel" | tail -n +2 | head -1)

        # Handle search
        if [[ "$key" == "/" ]]; then
            local query
            query=$(printf '%s\n' "${display[@]}" | fzf --height=85% --reverse --ansi \
                --prompt="Search: " --no-info --print-query | head -1) || true
            if [[ -n "$query" ]]; then
                line=$(printf '%s\n' "${display[@]}" | grep -i "$query" | head -1) || true
            fi
            [[ -z "$line" ]] && continue
            key=""
        fi

        # Extract VM name from selection (format: "   [x] vmname (state)" or "--- action")
        local vm=""
        if [[ -n "$line" ]]; then
            vm=$(echo "$line" | sed 's/^   //' | sed 's/^\[[^]]*\] //' | sed 's/^--- //' | sed 's/ (.*)$//')
        fi

        # Handle pin/mark toggle
        if [[ "$key" == "space" ]]; then
            if [[ -n "$vm" && "$vm" != "Back" && "$vm" != "Build All" ]]; then
                if [[ "$pinned_vm" == "$vm" ]]; then
                    pinned_vm=""
                    log_action info "Unpinned $vm"
                else
                    pinned_vm="$vm"
                    log_action ok "Pinned $vm"
                fi
            fi
            continue
        fi

        # For action hotkeys, always use pinned VM if one is set
        local target_vm="$vm"
        if [[ -n "$pinned_vm" && ("$key" == "s" || "$key" == "k" || "$key" == "u" || "$key" == "r" || "$key" == "b" || "$key" == "p" || "$key" == "a" || "$key" == "l") ]]; then
            target_vm="$pinned_vm"
        fi

        # Handle actions
        [[ "$target_vm" == "Back" ]] && return
        [[ -z "$target_vm" && -z "$pinned_vm" ]] && continue

        if [[ "$target_vm" == "Build All" ]]; then
            for v in "${vms[@]}"; do
                microvm_build "$v" || true
            done
            log_action ok "Built all MicroVMs"
            continue
        fi

        # Handle hotkeys (no press_enter - return to menu immediately)
        # Use || true to prevent set -e from exiting on command failure
        case "$key" in
            s) microvm_start "$target_vm" || true ;;
            k) microvm_stop "$target_vm" || true ;;
            u) microvm_update "$target_vm" || true ;;
            r) microvm_restart "$target_vm" || true ;;
            b) microvm_build "$target_vm" || true ;;
            p) microvm_purge "$target_vm" || true ;;
            a) microvm_attach "$target_vm" ;;
            l) microvm_app "$target_vm" ;;
            "") # Enter pressed - show submenu
                [[ -n "$target_vm" ]] && show_microvm_actions "$target_vm"
                ;;
        esac
    done
}

show_microvm_actions() {
    local vm="$1"

    while true; do
        local state
        state=$(microvm_state "$vm")

        local actions=()
        case "$state" in
            running)
                actions+=("Attach" "Launch App" "Stop" "Update (live)" "Restart" "Rebuild & Restart")
                ;;
            stopped)
                actions+=("Start" "Rebuild" "Purge")
                ;;
            not-built)
                actions+=("Build")
                ;;
        esac
        actions+=("Logs" "Back")

        clear
        show_session_log_bottom

        local action
        action=$(printf '%s\n' "${actions[@]}" | fzf --height=85% --reverse --disabled --no-info \
            --header="$vm ($state)") || action="Back"

        case "$action" in
            Start) microvm_start "$vm" || true ;;
            Stop) microvm_stop "$vm" || true ;;
            Restart) microvm_restart "$vm" || true ;;
            "Update (live)") microvm_update "$vm" || true ;;
            Build) microvm_build "$vm" || true ;;
            "Rebuild & Restart") { microvm_build "$vm" && microvm_restart "$vm"; } || true ;;
            Rebuild) microvm_build "$vm" || true ;;
            Purge) microvm_purge "$vm" || true; return ;;
            Attach) microvm_attach "$vm" ;;
            "Launch App") microvm_app "$vm" ;;
            Logs)
                sudo journalctl -u "microvm@${vm}.service" -n 100 --no-pager
                press_enter  # Keep for logs - user needs time to read
                ;;
            Back) return ;;
        esac
    done
}

# ========== LIBVIRT BASE IMAGES ==========

readonly LIBVIRT_TYPES=("pentest" "browsing" "comms" "dev" "lurking" "transfer")

base_image_status() {
    local t="$1"
    local img="$BASE_IMAGE_DIR/base-${t}.qcow2"
    if [[ -f "$img" ]]; then
        local size date
        size=$(du -h "$img" 2>/dev/null | cut -f1)
        date=$(stat -c %y "$img" 2>/dev/null | cut -d' ' -f1)
        echo "built ($size, $date)"
    else
        echo "not built"
    fi
}

build_base_image() {
    local t="$1"
    log "Building base-${t}..."

    cd "$FLAKE_DIR"
    git add -A 2>/dev/null || true
    git add -f local/*.nix local/machines/*.nix 2>/dev/null || true

    local name="base-${t}"
    if command -v nom &>/dev/null; then
        nom build ".#${name}" --out-link "result-${name}" || { log_action err "base-${t} build failed"; return 1; }
    else
        nix build ".#${name}" --out-link "result-${name}" || { log_action err "base-${t} build failed"; return 1; }
    fi

    local img=""
    for f in "result-${name}/nixos.qcow2" "result-${name}/qcow/nixos.qcow2" "result-${name}"/*.qcow2; do
        [[ -f "$f" ]] && { img="$f"; break; }
    done
    [[ -z "$img" ]] && { log_action err "base-${t} no qcow2 found"; return 1; }

    sudo mkdir -p "$BASE_IMAGE_DIR"
    sudo cp "$img" "$BASE_IMAGE_DIR/${name}.qcow2"
    sudo chown root:libvirtd "$BASE_IMAGE_DIR/${name}.qcow2" 2>/dev/null || true
    sudo chmod 644 "$BASE_IMAGE_DIR/${name}.qcow2"
    rm -f "result-${name}"

    log_action ok "base-${t} built"
}

show_base_images_menu() {
    while true; do
        local entries=()
        for t in "${LIBVIRT_TYPES[@]}"; do
            local st
            st=$(base_image_status "$t")
            entries+=("$t ($st)")
        done
        entries+=("--- Build All" "--- Back")

        clear
        show_session_log_bottom

        local sel
        sel=$(printf '%s\n' "${entries[@]}" | fzf --height=85% --reverse --disabled --no-info \
            --header="Libvirt Base Images") || sel=""

        [[ -z "$sel" || "$sel" == "--- Back" ]] && return

        if [[ "$sel" == "--- Build All" ]]; then
            for t in "${LIBVIRT_TYPES[@]}"; do
                build_base_image "$t" || true
            done
            log_action ok "Built all base images"
            continue
        fi

        local t
        t=$(echo "$sel" | cut -d' ' -f1)
        build_base_image "$t"
    done
}

# ========== HOST REBUILD ==========

show_host_menu() {
    while true; do
        local actions=(
            "Rebuild (current mode)"
            "Rebuild + Update flake"
            "--- Specialisations ---"
            "Rebuild lockdown (hardened, no internet)"
            "Rebuild administrative (router VM, full packages)"
            "Rebuild fallback (emergency direct WiFi)"
            "Back"
        )

        clear
        show_session_log_bottom

        local sel
        sel=$(printf '%s\n' "${actions[@]}" | fzf --height=85% --reverse --disabled --no-info \
            --header="Host Rebuild") || sel="Back"

        case "$sel" in
            "Rebuild (current mode)")
                run_in_terminal "Rebuild" "$SCRIPT_DIR/rebuild"
                log_action ok "Host rebuild launched"
                ;;
            "Rebuild + Update"*)
                run_in_terminal "Rebuild+Update" "$SCRIPT_DIR/rebuild -u"
                log_action ok "Host rebuild+update launched"
                ;;
            "Rebuild lockdown"*)
                run_in_terminal "Lockdown" "$SCRIPT_DIR/rebuild lockdown"
                log_action ok "Lockdown rebuild launched"
                ;;
            "Rebuild administrative"*)
                run_in_terminal "Administrative" "$SCRIPT_DIR/rebuild administrative"
                log_action ok "Administrative rebuild launched"
                ;;
            "Rebuild fallback"*)
                run_in_terminal "Fallback" "$SCRIPT_DIR/rebuild fallback"
                log_action ok "Fallback rebuild launched"
                ;;
            "---"*) continue ;;
            Back) return ;;
        esac
    done
}

# ========== ROUTER ==========

router_libvirt_state() {
    if command -v virsh &>/dev/null; then
        local state
        state=$(sudo virsh --connect qemu:///system domstate router-vm 2>/dev/null | head -1)
        case "$state" in
            running) echo "running" ;;
            "shut off"|"") echo "stopped" ;;
            *) echo "$state" ;;
        esac
    else
        echo "n/a"
    fi
}

router_microvm_state() {
    for router_name in microvm-router; do
        if systemctl is-active --quiet "microvm@${router_name}.service" 2>/dev/null; then
            echo "running"
            return
        elif [[ -d "/var/lib/microvms/${router_name}" ]] && [[ -e "/var/lib/microvms/${router_name}/current" ]]; then
            echo "stopped"
            return
        fi
    done
    echo "not-built"
}

show_router_menu() {
    while true; do
        local microvm_st libvirt_st
        microvm_st=$(router_microvm_state)
        libvirt_st=$(router_libvirt_state)

        clear
        show_session_log_bottom

        local header
        header="Router"$'\n'"MicroVM: $microvm_st | Libvirt: $libvirt_st"

        local actions=(
            "--- MicroVM ---"
            "Start MicroVM router"
            "Stop MicroVM router"
            "Restart MicroVM router"
            "Build MicroVM router"
            "MicroVM Console"
            "--- Libvirt ---"
            "Start libvirt router"
            "Stop libvirt router"
            "Restart libvirt router"
            "Rebuild libvirt router"
            "Libvirt Console (SSH)"
            "---"
            "Back"
        )

        local sel
        sel=$(printf '%s\n' "${actions[@]}" | fzf --height=85% --reverse --disabled --no-info \
            --header="$header") || sel="Back"

        case "$sel" in
            "Start MicroVM"*)
                if [[ "$libvirt_st" == "running" ]]; then
                    sudo virsh --connect qemu:///system destroy router-vm 2>/dev/null || true
                    log_action info "Stopped libvirt router"
                fi
                # Router doesn't have xpra, use systemctl directly
                # Try new name first, fall back to legacy
                sudo systemctl start microvm@microvm-router.service
                log_action ok "MicroVM router started"
                ;;
            "Stop MicroVM"*)
                # Router doesn't have xpra, use systemctl directly
                sudo systemctl stop microvm@microvm-router.service 2>/dev/null || true
                log_action ok "MicroVM router stopped"
                ;;
            "Restart MicroVM"*)
                # Router doesn't have xpra, use systemctl directly
                sudo systemctl restart microvm@microvm-router.service 2>/dev/null || true
                log_action ok "MicroVM router restarted"
                ;;
            "Build MicroVM"*)
                # Try new name first, fall back to legacy
                microvm_build "microvm-router"
                ;;
            "MicroVM Console")
                if [[ "$microvm_st" != "running" ]]; then
                    log_action err "MicroVM router not running"
                else
                    log "Ctrl+] to detach"
                    sudo socat -,rawer unix-connect:/var/lib/microvms/microvm-router/console.sock || true
                fi
                ;;
            "Start libvirt"*)
                if [[ "$microvm_st" == "running" ]]; then
                    sudo systemctl stop microvm@microvm-router.service
                    log_action info "Stopped MicroVM router"
                fi
                sudo virsh --connect qemu:///system start router-vm
                log_action ok "Libvirt router started"
                ;;
            "Stop libvirt"*)
                sudo virsh --connect qemu:///system destroy router-vm
                log_action ok "Libvirt router stopped"
                ;;
            "Restart libvirt"*)
                sudo virsh --connect qemu:///system destroy router-vm 2>/dev/null || true
                sleep 1
                sudo virsh --connect qemu:///system start router-vm
                log_action ok "Libvirt router restarted"
                ;;
            "Rebuild libvirt"*)
                run_in_terminal "Router" "rebuild-libvirt-router"
                log_action ok "Router rebuild launched"
                ;;
            "Libvirt Console"*)
                if [[ "$libvirt_st" != "running" ]]; then
                    log_action err "Libvirt router not running"
                else
                    log "Connecting via SSH to 192.168.100.253..."
                    ssh 192.168.100.253 || true
                    press_enter  # Keep for SSH - user needs to see they're back
                fi
                ;;
            "---"*) continue ;;
            Back) return ;;
        esac
    done
}

# ========== DEVSHELLS (Package Development) ==========

# Get color for VM type
devshells_get_vm_color() {
    local vm_type="$1"
    case "$vm_type" in
        browsing) echo "$GREEN" ;;
        pentest)  echo "$RED" ;;
        dev)      echo "$BLUE" ;;
        *)        echo "$NC" ;;
    esac
}

# Parse packages from a dev flake.nix
# Extracts package names from packages.${system} = { <name> = ... }
devshells_parse_flake_packages() {
    local flake_path="$1"
    [[ ! -f "$flake_path" ]] && return

    FLAKE_PATH="$flake_path" python3 -c "
import re
import sys
import os

flake_path = os.environ.get('FLAKE_PATH', '')
if not flake_path:
    sys.exit(0)

with open(flake_path, 'r') as f:
    content = f.read()

# Find packages.\${system} = { and then parse with brace matching
start_match = re.search(r'packages\.\\\$\{system\}\s*=\s*\{', content)
if not start_match:
    sys.exit(0)

# Find the matching closing brace
start = start_match.end()
depth = 1
end = start
for i, char in enumerate(content[start:], start):
    if char == '{':
        depth += 1
    elif char == '}':
        depth -= 1
        if depth == 0:
            end = i
            break

block = content[start:end]

# Parse the block for top-level assignments
found_packages = []
i = 0
while i < len(block):
    # Skip whitespace
    while i < len(block) and block[i] in ' \t\n':
        i += 1
    if i >= len(block):
        break

    # Skip comments
    if block[i] == '#':
        while i < len(block) and block[i] != '\n':
            i += 1
        continue

    # Look for identifier = pattern
    match = re.match(r'([a-zA-Z_][a-zA-Z0-9_-]*)\s*=', block[i:])
    if match:
        name = match.group(1)
        i += match.end()

        # Skip the derivation (handle nested braces)
        depth = 0
        in_string = False
        while i < len(block):
            char = block[i]
            if char == '\"' and (i == 0 or block[i-1] != '\\\\'):
                in_string = not in_string
            elif not in_string:
                if char == '{':
                    depth += 1
                elif char == '}':
                    depth -= 1
                elif char == ';' and depth == 0:
                    if name != 'default':
                        found_packages.append(name)
                    i += 1
                    break
            i += 1
    else:
        i += 1

for pkg in found_packages:
    print(pkg)
"
}

# Vsock staging server port
readonly STAGING_PORT=14502

# Query a VM's staging server via vsock
# Usage: devshells_query_vm <cid> <command>
devshells_query_vm() {
    local cid="$1"
    local cmd="$2"
    echo "$cmd" | timeout 2 socat - "VSOCK-CONNECT:${cid}:${STAGING_PORT}" 2>/dev/null || echo ""
}

# Get running microVMs with type info
# Returns: vmname:vmtype:cid
devshells_get_running_vms() {
    # Get all declared microVMs (both new short names and legacy)
    local declared
    declared=$(nix eval "$FLAKE_DIR#nixosConfigurations" --apply 'builtins.attrNames' --json 2>/dev/null | jq -r '.[]' | \
        grep -E '^microvm-(browsing|pentest|dev|comms|lurking)' || true)

    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        # Check if running
        if systemctl is-active --quiet "microvm@${vm}.service" 2>/dev/null; then
            local cid
            cid=$(microvm_cid "$vm")
            [[ -z "$cid" ]] && continue
            # Extract type from name
            # Extract type from microvm-<type> pattern
            local vm_type
            case "$vm" in
                microvm-browsing*) vm_type="browsing" ;;
                microvm-pentest*)  vm_type="pentest" ;;
                microvm-dev*)      vm_type="dev" ;;
                microvm-comms*)    vm_type="comms" ;;
                microvm-lurking*)  vm_type="lurking" ;;
                microvm-*)         vm_type=$(echo "$vm" | sed 's/microvm-//' | sed 's/-test$//' | sed 's/-[0-9]*$//') ;;
                *)                 vm_type="unknown" ;;
            esac
            echo "${vm}:${vm_type}:${cid}"
        fi
    done <<< "$declared"
}

# Get development packages (from running VMs via vsock)
devshells_get_dev() {
    local running_vms
    running_vms=$(devshells_get_running_vms)

    while IFS=':' read -r vm_name vm_type cid; do
        [[ -z "$vm_name" ]] && continue
        # Query VM for dev packages
        local response
        response=$(devshells_query_vm "$cid" "dev")
        [[ -z "$response" ]] && continue

        # Parse JSON response: {"packages":[{"name":"pkg","staged":false},...]}
        local packages
        packages=$(echo "$response" | jq -r '.packages[]? | select(.staged == false) | .name' 2>/dev/null || true)
        while IFS= read -r pkg; do
            [[ -n "$pkg" ]] && echo "dev:$vm_type:$pkg:$vm_name"
        done <<< "$packages"
    done <<< "$running_vms"
}

# Get staged packages (from running VMs via vsock)
devshells_get_staged() {
    local running_vms
    running_vms=$(devshells_get_running_vms)

    while IFS=':' read -r vm_name vm_type cid; do
        [[ -z "$vm_name" ]] && continue
        # Query VM for staged packages
        local response
        response=$(devshells_query_vm "$cid" "list")
        [[ -z "$response" ]] && continue

        # Parse JSON response: {"packages":["pkg1","pkg2"],...}
        local packages
        packages=$(echo "$response" | jq -r '.packages[]?' 2>/dev/null || true)
        while IFS= read -r pkg; do
            [[ -n "$pkg" ]] && echo "stg:$vm_type:$pkg:$vm_name"
        done <<< "$packages"
    done <<< "$running_vms"
}

# Get installed packages (from profiles/<type>/packages/<name>.nix)
devshells_get_installed() {
    for vm_type in "${VM_TYPES[@]}"; do
        local packages_dir="$PROFILES_DIR/$vm_type/packages"
        if [[ -d "$packages_dir" ]]; then
            for pkg_file in "$packages_dir"/*.nix; do
                [[ ! -f "$pkg_file" ]] && continue
                local pkg_name=$(basename "$pkg_file" .nix)
                [[ "$pkg_name" == "default" ]] && continue
                echo "ins:$vm_type:$pkg_name:profile"
            done
        fi
    done
}

# Collect all packages, deduplicated with priority: ins > stg > dev
devshells_collect_all() {
    declare -A seen

    # First pass: installed packages (highest priority)
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local stage vm_type pkg_name source
        IFS=':' read -r stage vm_type pkg_name source <<< "$entry"
        local key="${vm_type}:${pkg_name}"
        if [[ -z "${seen[$key]:-}" ]]; then
            seen[$key]="$entry"
        fi
    done < <(devshells_get_installed)

    # Second pass: staged packages
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local stage vm_type pkg_name source
        IFS=':' read -r stage vm_type pkg_name source <<< "$entry"
        local key="${vm_type}:${pkg_name}"
        if [[ -z "${seen[$key]:-}" ]]; then
            seen[$key]="$entry"
        fi
    done < <(devshells_get_staged)

    # Third pass: dev packages (lowest priority)
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local stage vm_type pkg_name source
        IFS=':' read -r stage vm_type pkg_name source <<< "$entry"
        local key="${vm_type}:${pkg_name}"
        if [[ -z "${seen[$key]:-}" ]]; then
            seen[$key]="$entry"
        fi
    done < <(devshells_get_dev)

    # Output all entries
    for entry in "${seen[@]}"; do
        echo "$entry"
    done | sort -t: -k2,2 -k3,3
}

# Format a package entry for display
devshells_format_entry() {
    local entry="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$entry"

    local stage_display
    case "$stage" in
        dev) stage_display="$STAGE_DEV" ;;
        stg) stage_display="$STAGE_STG" ;;
        ins) stage_display="$STAGE_INS" ;;
        *)   stage_display="[???]" ;;
    esac

    local vm_color
    vm_color=$(devshells_get_vm_color "$vm_type")

    # Fixed-width formatting for alignment
    printf "%b  ${vm_color}%-10s${NC} %s\n" "$stage_display" "$vm_type" "$pkg_name"
}

# Raw list for fzf (includes data in format fzf can parse)
devshells_list_raw() {
    local filter="${1:-}"
    local packages
    packages=$(devshells_collect_all)

    if [[ -z "$packages" ]]; then
        return
    fi

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        # Apply filter if set
        if [[ -n "$filter" ]]; then
            local stage vm_type pkg_name source
            IFS=':' read -r stage vm_type pkg_name source <<< "$entry"
            if [[ ! "$pkg_name" =~ $filter && ! "$vm_type" =~ $filter ]]; then
                continue
            fi
        fi
        # Output: formatted_display \t raw_data
        local formatted
        formatted=$(devshells_format_entry "$entry")
        echo -e "${formatted}\t${entry}"
    done <<< "$packages"
}

# Extract derivation from flake.nix and create package.nix
devshells_extract_derivation() {
    local flake_path="$1"
    local pkg_name="$2"

    python3 << EOF
import re
import sys

with open("$flake_path", "r") as f:
    content = f.read()

# Find the package definition
pkg_name = "$pkg_name"

# Match: pkg_name = <derivation>;
pattern = rf'{pkg_name}\s*=\s*'
match = re.search(pattern, content)
if not match:
    sys.exit(1)

start = match.end()
# Find the complete derivation (handle nested braces)
depth = 0
in_string = False
escape_next = False
end = start

for i, char in enumerate(content[start:], start):
    if escape_next:
        escape_next = False
        continue
    if char == '\\\\':
        escape_next = True
        continue
    if char == '"' and not in_string:
        in_string = True
        continue
    if char == '"' and in_string:
        in_string = False
        continue
    if in_string:
        continue

    if char == '{':
        depth += 1
    elif char == '}':
        depth -= 1
    elif char == ';' and depth == 0:
        end = i
        break

derivation = content[start:end].strip()

# Create standalone package.nix
print("{ pkgs }:")
print("")
print(derivation)
EOF
}

# Stage a package - now done inside VM via vm-sync push
# This function shows instructions to the user
devshells_stage() {
    local entry="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$entry"

    if [[ "$stage" != "dev" ]]; then
        log_action warn "Package is not in development stage"
        return 1
    fi

    # source now contains the VM name (e.g., microvm-browsing)
    local vm_name="$source"

    echo ""
    echo -e "${BOLD}To stage '$pkg_name':${NC}"
    echo ""
    echo -e "Run inside ${CYAN}$vm_name${NC}:"
    echo -e "  ${GREEN}vm-sync push --name $pkg_name${NC}"
    echo ""
    echo "Then refresh this menu to see the staged package."
    echo ""
    log_action warn "Staging now happens inside VM"
}

# Regenerate default.nix for a profile
devshells_regenerate_default() {
    local vm_type="$1"
    local packages_dir="$PROFILES_DIR/$vm_type/packages"
    local default_file="$packages_dir/default.nix"

    # Collect package files
    local package_files=()
    for pkg_file in "$packages_dir"/*.nix; do
        [[ ! -f "$pkg_file" ]] && continue
        [[ "$(basename "$pkg_file")" == "default.nix" ]] && continue
        package_files+=("$(basename "$pkg_file" .nix)")
    done

    # Write default.nix
    cat > "$default_file" << EOF
# Auto-generated package list for $vm_type profile
# Managed by vm-sync - do not edit manually
{ pkgs }:
[
EOF

    for pkg_name in "${package_files[@]}"; do
        echo "  (import ./${pkg_name}.nix { inherit pkgs; })" >> "$default_file"
    done

    echo "]" >> "$default_file"
}

# Pull package from VM staging via vsock
devshells_pull() {
    local entry="$1"
    shift
    local targets=("$@")

    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$entry"

    if [[ "$stage" != "stg" ]]; then
        log_action warn "Package must be staged before pulling"
        return 1
    fi

    # source contains the VM name (e.g., microvm-browsing)
    local vm_name="$source"

    # Get CID for the VM
    local cid
    cid=$(microvm_cid "$vm_name")
    if [[ -z "$cid" ]]; then
        log_action err "Cannot get CID for $vm_name"
        return 1
    fi

    # Check if VM is running
    if ! systemctl is-active --quiet "microvm@${vm_name}.service" 2>/dev/null; then
        log_action err "VM $vm_name is not running"
        return 1
    fi

    # If no targets specified, use the source VM type
    if [[ ${#targets[@]} -eq 0 ]]; then
        targets=("$vm_type")
    fi

    # Pull via vsock
    log "Pulling $pkg_name from $vm_name..."
    local temp_dir
    temp_dir=$(mktemp -d)

    if ! devshells_query_vm "$cid" "get $pkg_name" | tar xf - -C "$temp_dir" 2>/dev/null; then
        rm -rf "$temp_dir"
        log_action err "Failed to pull package from VM"
        return 1
    fi

    # Copy to profiles
    for target in "${targets[@]}"; do
        local packages_dir="$PROFILES_DIR/$target/packages"
        mkdir -p "$packages_dir"

        if [[ -f "$temp_dir/$pkg_name/package.nix" ]]; then
            cp "$temp_dir/$pkg_name/package.nix" "$packages_dir/${pkg_name}.nix"
            log "Installed to $target/packages/${pkg_name}.nix"
            devshells_regenerate_default "$target"
        else
            log_action warn "No package.nix found for $pkg_name"
        fi
    done

    rm -rf "$temp_dir"
    log_action ok "Pulled $pkg_name to: ${targets[*]}"
}

# Remove package from profile
devshells_remove() {
    local entry="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$entry"

    if [[ "$stage" != "ins" ]]; then
        log_action warn "Package is not installed"
        return 1
    fi

    local pkg_file="$PROFILES_DIR/$vm_type/packages/${pkg_name}.nix"
    if [[ -f "$pkg_file" ]]; then
        rm "$pkg_file"
        devshells_regenerate_default "$vm_type"
        log_action ok "Removed $pkg_name from $vm_type"
    else
        log_action warn "Package file not found"
    fi
}

# Get list of profiles that have been modified
devshells_get_modified_profiles() {
    local modified=()

    for vm_type in "${VM_TYPES[@]}"; do
        local packages_dir="$PROFILES_DIR/$vm_type/packages"
        if git -C "$FLAKE_DIR" status --porcelain "$packages_dir" 2>/dev/null | grep -q .; then
            modified+=("$vm_type")
        fi
    done

    printf '%s\n' "${modified[@]}"
}

# Preview package content
devshells_preview() {
    local raw_data="$1"

    # Handle special entries
    case "$raw_data" in
        __back__|"")
            echo "Select a package to preview"
            return
            ;;
    esac

    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$raw_data"

    local vm_color
    vm_color=$(devshells_get_vm_color "$vm_type")

    echo -e "${BOLD}Package: ${NC}$pkg_name"
    echo -e "${BOLD}VM Type: ${NC}${vm_color}$vm_type${NC}"
    echo -e "${BOLD}Stage:   ${NC}$stage"
    echo -e "${BOLD}VM:      ${NC}$source"
    echo ""

    case "$stage" in
        dev)
            # source contains VM name
            local vm_name="$source"
            echo -e "${DIM}Source: $vm_name:~/dev/packages/$pkg_name/flake.nix${NC}"
            echo ""
            echo -e "${YELLOW}Package in development (not yet staged)${NC}"
            echo ""
            echo "To stage this package, run inside the VM:"
            echo -e "  ${GREEN}vm-sync push --name $pkg_name${NC}"
            echo ""
            echo -e "${DIM}Actions: [s]tage (shows instructions)${NC}"
            ;;
        stg)
            # source contains VM name
            local vm_name="$source"
            echo -e "${DIM}Source: $vm_name:~/staging/$pkg_name/package.nix${NC}"
            echo ""

            # Try to fetch and show package content via vsock
            local cid
            cid=$(microvm_cid "$vm_name")
            if [[ -n "$cid" ]] && systemctl is-active --quiet "microvm@${vm_name}.service" 2>/dev/null; then
                local temp_dir
                temp_dir=$(mktemp -d)
                if devshells_query_vm "$cid" "get $pkg_name" | tar xf - -C "$temp_dir" 2>/dev/null; then
                    if [[ -f "$temp_dir/$pkg_name/package.nix" ]]; then
                        head -30 "$temp_dir/$pkg_name/package.nix"
                        if [[ $(wc -l < "$temp_dir/$pkg_name/package.nix") -gt 30 ]]; then
                            echo "..."
                        fi
                    fi
                else
                    echo "(Could not fetch package content)"
                fi
                rm -rf "$temp_dir"
            else
                echo "(VM not running - cannot preview)"
            fi
            echo ""
            echo -e "${DIM}Actions: [p]ull to profile${NC}"
            ;;
        ins)
            echo -e "${DIM}Source: profiles/$vm_type/packages/$pkg_name.nix${NC}"
            echo ""
            local pkg_path="$PROFILES_DIR/$vm_type/packages/${pkg_name}.nix"
            if [[ -f "$pkg_path" ]]; then
                head -30 "$pkg_path"
                if [[ $(wc -l < "$pkg_path") -gt 30 ]]; then
                    echo "..."
                fi
            fi
            echo ""
            echo -e "${DIM}Actions: [x] remove${NC}"
            ;;
    esac
}

# Show diff between staged (in VM) and installed (on host)
devshells_diff() {
    local raw_data="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$raw_data"

    local installed_path="$PROFILES_DIR/$vm_type/packages/${pkg_name}.nix"
    local vm_name="$source"

    # Try to fetch staged version from VM
    local staged_content=""
    if [[ "$stage" == "stg" && -n "$vm_name" ]]; then
        local cid
        cid=$(microvm_cid "$vm_name")
        if [[ -n "$cid" ]] && systemctl is-active --quiet "microvm@${vm_name}.service" 2>/dev/null; then
            local temp_dir
            temp_dir=$(mktemp -d)
            if devshells_query_vm "$cid" "get $pkg_name" | tar xf - -C "$temp_dir" 2>/dev/null; then
                if [[ -f "$temp_dir/$pkg_name/package.nix" ]]; then
                    staged_content="$temp_dir/$pkg_name/package.nix"
                fi
            fi
            if [[ -n "$staged_content" && -f "$installed_path" ]]; then
                diff --color=always "$installed_path" "$staged_content" || true
            elif [[ -n "$staged_content" ]]; then
                echo -e "${GREEN}New package (not yet installed)${NC}"
                cat "$staged_content"
            fi
            rm -rf "$temp_dir"
            return
        fi
    fi

    if [[ -f "$installed_path" ]]; then
        echo -e "${YELLOW}Installed version:${NC}"
        cat "$installed_path"
    else
        echo "No source files found"
    fi
}

# Rebuild menu for devshells
devshells_rebuild_menu() {
    local modified
    modified=$(devshells_get_modified_profiles)
    if [[ -z "$modified" ]]; then
        log_action warn "No modified profiles"
        return
    fi

    local modified_list
    modified_list=$(echo "$modified" | tr '\n' ' ')

    local opts=("Rebuild MicroVMs" "Rebuild Base Images" "Rebuild Both" "Back")
    local sel
    sel=$(printf '%s\n' "${opts[@]}" | fzf --height=85% --reverse --disabled --no-info \
        --header="Modified: $modified_list") || sel="Back"

    case "$sel" in
        *MicroVMs*)
            while read -r profile; do
                [[ -z "$profile" ]] && continue
                # Find microVMs of this type
                local vms
                vms=$(nix eval "$FLAKE_DIR#nixosConfigurations" --apply 'builtins.attrNames' --json 2>/dev/null | \
                    jq -r '.[]' | grep "^microvm-${profile}" | grep -v 'router' || true)
                while read -r vm; do
                    [[ -z "$vm" ]] && continue
                    microvm_build "$vm" || true
                done <<< "$vms"
            done <<< "$modified"
            log_action ok "MicroVMs rebuilt"
            ;;
        *"Base Images"*)
            while read -r profile; do
                [[ -z "$profile" ]] && continue
                build_base_image "$profile" || true
            done <<< "$modified"
            log_action ok "Base images rebuilt"
            ;;
        *Both*)
            # MicroVMs first (fast)
            while read -r profile; do
                [[ -z "$profile" ]] && continue
                local vms
                vms=$(nix eval "$FLAKE_DIR#nixosConfigurations" --apply 'builtins.attrNames' --json 2>/dev/null | \
                    jq -r '.[]' | grep "^microvm-${profile}" | grep -v 'router' || true)
                while read -r vm; do
                    [[ -z "$vm" ]] && continue
                    microvm_build "$vm" || true
                done <<< "$vms"
            done <<< "$modified"
            # Then base images
            while read -r profile; do
                [[ -z "$profile" ]] && continue
                build_base_image "$profile" || true
            done <<< "$modified"
            log_action ok "MicroVMs and base images rebuilt"
            ;;
        Back) return ;;
    esac
}

# Show actions menu for a specific package
show_devshells_actions() {
    local raw_data="$1"
    local stage vm_type pkg_name source
    IFS=':' read -r stage vm_type pkg_name source <<< "$raw_data"

    local actions=()

    case "$stage" in
        dev)
            actions+=("Stage package")
            actions+=("View source")
            ;;
        stg)
            actions+=("Pull to profile")
            actions+=("Pull to multiple profiles...")
            actions+=("View source")
            actions+=("View diff")
            ;;
        ins)
            actions+=("Remove from profile")
            actions+=("View source")
            ;;
    esac

    actions+=("Back")

    local action
    action=$(printf '%s\n' "${actions[@]}" | fzf --height=85% --reverse --disabled --no-info \
        --header="$pkg_name ($stage)") || action="Back"

    case "$action" in
        "Stage package")
            devshells_stage "$raw_data"
            ;;
        "Pull to profile")
            devshells_pull "$raw_data"
            ;;
        "Pull to multiple profiles...")
            local targets
            targets=$(printf '%s\n' "${VM_TYPES[@]}" | fzf --multi --height=85% --reverse --disabled --no-info \
                --header="Select profiles (Tab to multi-select)")
            if [[ -n "$targets" ]]; then
                devshells_pull "$raw_data" $targets
            fi
            ;;
        "Remove from profile")
            devshells_remove "$raw_data"
            ;;
        "View source")
            devshells_preview "$raw_data" | less -R
            ;;
        "View diff")
            devshells_diff "$raw_data" | less -R
            ;;
        "Back"|"")
            return
            ;;
    esac
}

show_devshells_menu() {
    local filter=""
    while true; do
        clear
        show_session_log_bottom

        # Check if there are any packages
        local packages header
        packages=$(devshells_list_raw "$filter")
        header=$'Package Development\n[/]search [s]tage [p]ull [x]remove [R]ebuild [r]efresh'

        if [[ -z "$packages" ]]; then
            packages="Back	__back__"
            header+=$'\nNo packages. Use: vm-dev build <url>'
        fi

        local sel
        sel=$(echo -e "$packages" | fzf \
            --ansi --disabled --no-info --height=85% --reverse \
            --header="$header" \
            --delimiter=$'\t' --with-nth=1 \
            --preview="$SELF_PATH --devshells-preview {-1}" \
            --preview-window="right:50%:wrap" \
            --expect=/,s,p,x,R,r) || sel=""

        [[ -z "$sel" ]] && return

        local key
        key=$(head -1 <<< "$sel")
        local raw_data
        raw_data=$(tail -n +2 <<< "$sel" | awk -F'\t' '{print $NF}')

        case "$key" in
            /)
                # Enable search
                filter=$(echo | fzf --print-query --prompt="Search: " --height=3 --reverse --no-info | head -1) || filter=""
                ;;
            s)
                [[ -n "$raw_data" && "$raw_data" != "__back__" ]] && devshells_stage "$raw_data"
                ;;
            p)
                [[ -n "$raw_data" && "$raw_data" != "__back__" ]] && devshells_pull "$raw_data"
                ;;
            x)
                [[ -n "$raw_data" && "$raw_data" != "__back__" ]] && devshells_remove "$raw_data"
                ;;
            R)
                devshells_rebuild_menu
                ;;
            r)
                filter=""
                ;;
            "")
                [[ "$raw_data" == "__back__" ]] && return
                [[ -n "$raw_data" ]] && show_devshells_actions "$raw_data"
                ;;
        esac
    done
}

# ========== MAIN ==========

main_menu() {
    while true; do
        clear
        show_session_log_bottom

        local opts=(
            "[M] MicroVMs"
            "[B] Base Images"
            "[H] Host Rebuild"
            "[R] Router"
            "[D] Devshells"
            "[E] Exit"
        )

        local sel
        sel=$(printf '%s\n' "${opts[@]}" | fzf --height=85% --reverse --no-info \
            --header=$'Hydrix VM Manager\n[m]icroVMs [b]ase images [h]ost rebuild [r]outer [d]evshells [e]xit' \
            --disabled --expect=m,b,h,r,d,e) || sel=""

        [[ -z "$sel" ]] && exit 0

        local key line
        key=$(echo "$sel" | head -1)
        line=$(echo "$sel" | tail -n +2 | head -1)

        # Handle hotkeys or selection
        case "$key" in
            m) show_microvm_menu ;;
            b) show_base_images_menu ;;
            h) show_host_menu ;;
            r) show_router_menu ;;
            d) show_devshells_menu ;;
            e) exit 0 ;;
            "") # Enter pressed - use selection
                [[ -z "$line" ]] && continue
                case "$line" in
                    *MicroVMs) show_microvm_menu ;;
                    *"Base Images") show_base_images_menu ;;
                    *"Host Rebuild") show_host_menu ;;
                    *Router) show_router_menu ;;
                    *Devshells) show_devshells_menu ;;
                    *Exit) exit 0 ;;
                esac
                ;;
        esac
    done
}

# Check deps
command -v fzf &>/dev/null || { echo "fzf required"; exit 1; }
command -v nix &>/dev/null || { echo "nix required"; exit 1; }

# CLI dispatch for callbacks
case "${1:-}" in
    --devshells-preview)
        devshells_preview "${2:-}"
        exit 0
        ;;
    --devshells-diff)
        devshells_diff "${2:-}"
        exit 0
        ;;
    --devshells-menu|-d)
        # Direct launch of devshells menu
        show_devshells_menu
        exit 0
        ;;
    *)
        main_menu
        ;;
esac
