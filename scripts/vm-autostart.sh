#!/usr/bin/env bash
# Auto-detect running VMs and place them on designated workspaces
# Uses vm-workspaces.json for configuration
# Sends notification if multiple VMs of the same type are detected

set -euo pipefail

HYDRIX_DIR="${HYDRIX_DIR:-$HOME/Hydrix}"
CONFIG_FILE="$HYDRIX_DIR/configs/vm-workspaces.json"
FULLSCREEN_SCRIPT="$HYDRIX_DIR/scripts/vm-fullscreen.sh"
SPLASH_LOG="/tmp/vm-autostart.log"

# VM type to workspace mapping (fallback if config not found)
declare -A TYPE_TO_WORKSPACE=(
    ["pentest"]="2"
    ["browsing"]="3"
    ["comms"]="4"
    ["dev"]="5"
    ["office"]="6"
)

log() {
    echo "$(date '+%H:%M:%S') [vm-autostart] $*" >> "$SPLASH_LOG"
    echo "$*"
}

# =============================================================================
# SPLASH SCREEN CODE - DISABLED
# =============================================================================
# The splash screen approach doesn't work because:
# 1. vm-fullscreen-hack.sh requires xdotool windowactivate + clicking menubar
# 2. windowactivate brings virt-manager to foreground, breaking splash coverage
# 3. You cannot click on a hidden window's menubar
# 4. virt-manager has no CLI option to start in fullscreen mode
#
# virt-viewer is NOT a valid alternative because:
# - It does NOT trigger xrandr mode updates when window/resolution changes
# - This breaks vm-auto-resize.sh which polls xrandr for "preferred" changes
# - Even --auto-resize=always doesn't help
#
# Keeping code below for future reference if a solution is found.
# =============================================================================

# SPLASH_DIR="/tmp/splash-cover"
# declare -a SPLASH_PIDS=()
# WATCHDOG_PID=""
# declare -A SPLASH_WINDOWS=()
#
# cleanup_on_exit() {
#     kill_all_splashes 2>/dev/null || true
#     [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
# }
# trap cleanup_on_exit EXIT
#
# spawn_splash_on_workspace() {
#     local workspace="$1"
#     local splash_img="$SPLASH_DIR/splash.png"
#     i3-msg "workspace $workspace" >/dev/null 2>&1
#     sleep 0.2
#     feh --fullscreen --auto-zoom "$splash_img" &
#     local feh_pid=$!
#     SPLASH_PIDS+=("$feh_pid")
#     sleep 0.3
#     local splash_win
#     splash_win=$(xdotool search --pid "$feh_pid" 2>/dev/null | head -1)
#     if [ -n "$splash_win" ]; then
#         i3-msg "[id=$splash_win] fullscreen enable" >/dev/null 2>&1
#         SPLASH_WINDOWS["$workspace"]="$splash_win"
#         log "Spawned splash on workspace $workspace (PID: $feh_pid, WIN: $splash_win)"
#     fi
# }
#
# raise_splash_on_workspace() {
#     local workspace="$1"
#     local splash_win="${SPLASH_WINDOWS[$workspace]:-}"
#     if [ -n "$splash_win" ]; then
#         i3-msg "workspace $workspace" >/dev/null 2>&1
#         i3-msg "[id=$splash_win] focus, fullscreen enable" >/dev/null 2>&1
#     fi
# }
#
# generate_splash_image() {
#     mkdir -p "$SPLASH_DIR"
#     local splash_img="$SPLASH_DIR/splash.png"
#     local bg_color fg_color accent_color
#     if [ -f ~/.cache/wal/colors.json ]; then
#         bg_color=$(jq -r '.special.background // .colors.color0' ~/.cache/wal/colors.json)
#         fg_color=$(jq -r '.special.foreground // .colors.color7' ~/.cache/wal/colors.json)
#         accent_color=$(jq -r '.colors.color4' ~/.cache/wal/colors.json)
#     else
#         bg_color="#0B0E1B"
#         fg_color="#91ded4"
#         accent_color="#1C7787"
#     fi
#     local font="CozetteVector"
#     local config_file="$HYDRIX_DIR/configs/display-config.json"
#     if [ -f "$config_file" ]; then
#         local font_base
#         font_base=$(jq -r '.fonts.default // "cozette"' "$config_file")
#         case "$font_base" in
#             cozette|Cozette) font="CozetteVector" ;;
#             *) font="$font_base" ;;
#         esac
#     fi
#     local res width height
#     res=$(xrandr --query 2>/dev/null | grep " connected primary" | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
#     [ -z "$res" ] && res=$(xrandr --query 2>/dev/null | grep " connected" | head -1 | grep -oP '\d{3,5}x\d{3,5}' | head -n1)
#     [ -z "$res" ] && res="1920x1080"
#     width=$(echo "$res" | cut -d'x' -f1)
#     height=$(echo "$res" | cut -d'x' -f2)
#     local main_font_size=$((height / 10))
#     local sub_font_size=$((height / 30))
#     magick -size "${width}x${height}" "xc:${bg_color}" \
#         -gravity center \
#         -font "$font" -pointsize "$main_font_size" -fill "$fg_color" \
#         -annotate +0-50 "HYDRIX" \
#         -font "$font" -pointsize "$sub_font_size" -fill "$accent_color" \
#         -annotate +0+80 "setting up workspaces..." \
#         "$splash_img" 2>/dev/null
#     [ -f "$splash_img" ] && return 0 || return 1
# }
#
# kill_all_splashes() {
#     for pid in "${SPLASH_PIDS[@]}"; do
#         kill "$pid" 2>/dev/null || true
#     done
#     SPLASH_PIDS=()
#     pkill -f "feh.*splash-cover" 2>/dev/null || true
#     rm -rf "$SPLASH_DIR" 2>/dev/null || true
# }

# =============================================================================
# END SPLASH SCREEN CODE
# =============================================================================

# Ensure Super_L grab key is set (virt-manager reads this on console open)
dconf write /org/virt-manager/virt-manager/console/grab-keys "'65515'" 2>/dev/null || true

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed"
    exit 1
fi

if ! command -v notify-send &>/dev/null; then
    echo "Warning: notify-send not found, notifications disabled"
fi

# Load config if available
if [ -f "$CONFIG_FILE" ]; then
    log "Loading workspace config from $CONFIG_FILE"
    # Parse workspace mappings from JSON
    while IFS="=" read -r ws type; do
        if [ -n "$type" ] && [ "$type" != "null" ]; then
            TYPE_TO_WORKSPACE["$type"]="$ws"
        fi
    done < <(jq -r '.workspaces | to_entries[] | select(.value.type != null) | "\(.key)=\(.value.type)"' "$CONFIG_FILE")
fi

# Jump to workspace 2 first to establish external monitor focus
# This ensures subsequent VM-to-workspace placements go to external display
log "Switching to workspace 2 (external monitor)..."
i3-msg "workspace 2" >/dev/null 2>&1 || true
sleep 0.5

# Get list of running VMs (excluding router-vm)
log "Detecting running VMs..."
RUNNING_VMS=$(sudo virsh list --name 2>/dev/null | grep -v "^$" | grep -v "router-vm" || true)

if [ -z "$RUNNING_VMS" ]; then
    log "No running VMs found (excluding router-vm)"
    exit 0
fi

log "Running VMs:"
echo "$RUNNING_VMS" | sed 's/^/  /'

# Count VMs by type and collect target workspaces
declare -A TYPE_COUNT
declare -A TYPE_VMS
declare -a TARGET_WORKSPACES=()

while read -r vm_name; do
    [ -z "$vm_name" ] && continue

    # Extract type from VM name (e.g., "pentest-kali" -> "pentest", "browsing-test" -> "browsing")
    vm_type=""
    for type in pentest browsing comms dev office; do
        if [[ "$vm_name" == *"$type"* ]]; then
            vm_type="$type"
            break
        fi
    done

    if [ -n "$vm_type" ]; then
        TYPE_COUNT["$vm_type"]=$((${TYPE_COUNT["$vm_type"]:-0} + 1))
        TYPE_VMS["$vm_type"]="${TYPE_VMS["$vm_type"]:-} $vm_name"

        # Collect workspace if single VM of this type
        workspace=${TYPE_TO_WORKSPACE["$vm_type"]:-}
        if [ -n "$workspace" ] && [ "${TYPE_COUNT["$vm_type"]}" -eq 1 ]; then
            TARGET_WORKSPACES+=("$workspace")
        fi
    else
        log "  Warning: Could not determine type for VM '$vm_name'"
    fi
done <<< "$RUNNING_VMS"

# === Place VMs on their workspaces ===
log "=== Placing VMs on workspaces ==="
PLACED=0
CONFLICTS=""

for vm_type in "${!TYPE_COUNT[@]}"; do
    count=${TYPE_COUNT["$vm_type"]}
    vms=${TYPE_VMS["$vm_type"]}
    workspace=${TYPE_TO_WORKSPACE["$vm_type"]:-}

    if [ -z "$workspace" ]; then
        log "  No workspace mapping for type '$vm_type'"
        continue
    fi

    if [ "$count" -eq 1 ]; then
        # Single VM of this type - auto-place it
        vm_name=$(echo "$vms" | xargs)  # trim whitespace
        log "  Placing $vm_name on workspace $workspace"

        if [ -x "$FULLSCREEN_SCRIPT" ]; then
            # Run synchronously - vm-fullscreen.sh now blocks until complete
            "$FULLSCREEN_SCRIPT" "$vm_name" "$workspace"
            PLACED=$((PLACED + 1))
            sleep 3  # Wait for virt-manager to fully stabilize before next VM
        else
            log "  Error: $FULLSCREEN_SCRIPT not found or not executable"
        fi
    else
        # Multiple VMs of this type - don't auto-place
        log "  Conflict: $count VMs of type '$vm_type':$vms"
        CONFLICTS="${CONFLICTS}\n  $vm_type ($count):$vms"
    fi
done

# Send notification about conflicts
if [ -n "$CONFLICTS" ]; then
    msg="Multiple VMs of same type detected:$CONFLICTS\n\nUse vm-fullscreen.sh to place manually"
    echo -e "$msg"

    if command -v notify-send &>/dev/null; then
        notify-send -u normal "VM Autostart" "$(echo -e "$msg")"
    fi
fi

log ""
log "VM Autostart complete: $PLACED VMs placed"
