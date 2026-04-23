# Xpra host module - connect to VM apps seamlessly via virtio-vsock
#
# Provides:
#   - xpra client package
#   - vm-app script on PATH for launching VM applications on the host desktop
#
# Usage:
#   vm-app <vm-name> <command>           Start app and attach (background)
#   vm-app <vm-name> --start <command>   Start app only (non-blocking)
#   vm-app <vm-name> --attach            Attach to see all running apps
#   vm-app <vm-name> --stop              Stop the xpra session
#   vm-app <vm-name> --info              Show session info
#
# Border colors are DYNAMIC - read from:
#   1. profiles/<type>.nix -> hydrix.colorscheme = "..."
#   2. colorschemes/<scheme>.json -> colors.color4
#
# This matches the VM's i3 focused border color automatically.
#
# Requirements:
#   - VM must have xpra-guest.nix imported (runs xpra server on vsock:14500)
#   - VM must have a vsock device (deploy-vm.sh adds --vsock cid.auto=yes)
#
{ config, pkgs, lib, ... }:

let
  fontFamily = config.hydrix.graphical.font.family;

  # DPI-aware alacritty launcher - shared between host keybindings and ws-app fallback
  # Reads unified font size from scaling.json and pywal colors from colors.json
  # WINIT_X11_SCALE_FACTOR=1 disables alacritty's own DPI scaling - we handle it ourselves
  alacrittyDpi = pkgs.writeShellScriptBin "alacritty-dpi" ''
    SCALING_JSON="$HOME/.config/hydrix/scaling.json"
    SCALING_JSON_VM="/mnt/hydrix-config/scaling.json"
    WAL_COLORS="$HOME/.cache/wal/colors.json"

    # Build color options from pywal if available
    # Optimized: single jq call extracts all 19 colors at once (was 18 separate calls)
    color_opts=()
    if [ -f "$WAL_COLORS" ]; then
        IFS=$'\t' read -r bg fg cursor c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 <<< "$(${pkgs.jq}/bin/jq -r '[
            (.special.background // .colors.color0),
            (.special.foreground // .colors.color7),
            (.special.cursor // .colors.color7),
            .colors.color0, .colors.color1, .colors.color2, .colors.color3,
            .colors.color4, .colors.color5, .colors.color6, .colors.color7,
            .colors.color8, .colors.color9, .colors.color10, .colors.color11,
            .colors.color12, .colors.color13, .colors.color14, .colors.color15
        ] | @tsv' "$WAL_COLORS" 2>/dev/null)"

        color_opts=(
            -o "colors.primary.background=\"$bg\""
            -o "colors.primary.foreground=\"$fg\""
            -o "colors.cursor.cursor=\"$cursor\""
            -o "colors.cursor.text=\"$bg\""
            -o "colors.normal.black=\"$c0\""
            -o "colors.normal.red=\"$c1\""
            -o "colors.normal.green=\"$c2\""
            -o "colors.normal.yellow=\"$c3\""
            -o "colors.normal.blue=\"$c4\""
            -o "colors.normal.magenta=\"$c5\""
            -o "colors.normal.cyan=\"$c6\""
            -o "colors.normal.white=\"$c7\""
            -o "colors.bright.black=\"$c8\""
            -o "colors.bright.red=\"$c9\""
            -o "colors.bright.green=\"$c10\""
            -o "colors.bright.yellow=\"$c11\""
            -o "colors.bright.blue=\"$c12\""
            -o "colors.bright.magenta=\"$c13\""
            -o "colors.bright.cyan=\"$c14\""
            -o "colors.bright.white=\"$c15\""
        )
    fi

    # Find scaling.json (host or VM mount)
    if [ -f "$SCALING_JSON" ]; then
        json_path="$SCALING_JSON"
    elif [ -f "$SCALING_JSON_VM" ]; then
        json_path="$SCALING_JSON_VM"
    else
        # No scaling.json - use default font, still apply colors
        exec env WINIT_X11_SCALE_FACTOR=1 ${pkgs.alacritty}/bin/alacritty "''${color_opts[@]}" "$@"
    fi

    # Read unified font settings (single jq call)
    IFS=$'\t' read -r font_size font_name <<< "$(${pkgs.jq}/bin/jq -r '[(.fonts.alacritty // 10 | tostring), (.font_name // "${fontFamily}")] | @tsv' "$json_path" 2>/dev/null)"

    # WINIT_X11_SCALE_FACTOR=1 prevents alacritty from doing its own DPI scaling
    # We control font size via scaling.json instead
    exec env WINIT_X11_SCALE_FACTOR=1 ${pkgs.alacritty}/bin/alacritty \
        -o "font.size=$font_size" \
        -o "font.normal.family=\"$font_name\"" \
        "''${color_opts[@]}" \
        "$@"
  '';

  vmApp = pkgs.writeShellScriptBin "vm-app" ''
    set -euo pipefail

    XPRA_PORT=14500
    DEFAULT_COLOR="#888888"
    BORDER_SIZE=3
    DEFAULT_DPI=96

    # Directories for layered lookup (user config first, then framework)
    CONFIG_DIR="${config.hydrix.paths.configDir}"
    HYDRIX_DIR="${config.hydrix.paths.hydrixDir}"

    # Find profile file (check config dir first, then framework)
    find_profile() {
        local vm_type="$1"
        local candidates=(
            "$CONFIG_DIR/profiles/$vm_type/default.nix"
            "$CONFIG_DIR/profiles/$vm_type.nix"
            "$HYDRIX_DIR/profiles/$vm_type/default.nix"
            "$HYDRIX_DIR/profiles/$vm_type.nix"
        )
        for f in "''${candidates[@]}"; do
            [[ -f "$f" ]] && echo "$f" && return 0
        done
        echo ""
    }

    # Find colorscheme JSON (check config dir first, then framework)
    find_colorscheme() {
        local name="$1"
        local candidates=(
            "$CONFIG_DIR/colorschemes/$name.json"
            "$HYDRIX_DIR/colorschemes/$name.json"
        )
        for f in "''${candidates[@]}"; do
            [[ -f "$f" ]] && echo "$f" && return 0
        done
        echo ""
    }

    usage() {
        cat <<USAGE
Usage: vm-app <vm-name> <command> [args...]
       vm-app <vm-name> --start <command>
       vm-app <vm-name> --attach
       vm-app <vm-name> --stop
       vm-app <vm-name> --info

Launch graphical applications from VMs seamlessly on the host desktop.
Uses xpra over virtio-vsock (no network required).

Border colors are dynamically read from:
  profiles/<type>.nix -> hydrix.colorscheme
  colorschemes/<scheme>.json -> colors.color4

This automatically matches the VM's i3 focused border color.

Modes:
  <command>          Start the app and attach (runs in background)
  --start <command>  Start an app without attaching (non-blocking)
  --attach           Attach to see all running VM app windows
  --stop             Stop the xpra session on the VM
  --info             Show xpra session info

Examples:
  vm-app microvm-browsing firefox
  vm-app microvm-pentest burpsuite
  vm-app microvm-browsing --start firefox    # non-blocking
  vm-app microvm-browsing --attach           # view all apps
  vm-app microvm-browsing --stop
USAGE
        exit 0
    }

    error() { echo "[vm-app] ERROR: $*" >&2; exit 1; }
    log()   { echo "[vm-app] $*" >&2; }

    is_microvm() {
        local vm_name="$1"
        [[ "$vm_name" == microvm-* ]]
    }

    get_vm_type() {
        local vm_name="$1"
        local vm_type

        if is_microvm "$vm_name"; then
            # MicroVM: extract type from microvm-<type> pattern
            # e.g., "microvm-browsing" -> "browsing"
            vm_type=$(echo "$vm_name" | ${pkgs.gnused}/bin/sed -n 's/^microvm-\([a-z]*\).*/\1/p')
        else
            # Libvirt: extract type from <type>-<name> pattern
            # e.g., "browsing-vm" -> "browsing"
            vm_type=$(echo "$vm_name" | ${pkgs.gnused}/bin/sed -n 's/^\([a-z]*\).*/\1/p')
        fi
        echo "$vm_type"
    }

    get_border_color() {
        local vm_type="$1"

        # Find profile (config dir first, then framework)
        local profile
        profile=$(find_profile "$vm_type")
        if [[ -z "$profile" ]]; then
            echo "$DEFAULT_COLOR"
            return
        fi

        # Extract: hydrix.colorscheme = "nvid";
        local colorscheme
        colorscheme=$(${pkgs.gnugrep}/bin/grep -oP 'hydrix\.colorscheme\s*=\s*"\K[^"]+' "$profile" 2>/dev/null || true)
        if [[ -z "$colorscheme" ]]; then
            echo "$DEFAULT_COLOR"
            return
        fi

        # Find colorscheme JSON (config dir first, then framework)
        local colorfile
        colorfile=$(find_colorscheme "$colorscheme")
        if [[ -z "$colorfile" ]]; then
            echo "$DEFAULT_COLOR"
            return
        fi

        # Extract: "color4": "#9DE001"
        local color4
        color4=$(${pkgs.jq}/bin/jq -r '.colors.color4 // empty' "$colorfile" 2>/dev/null || true)
        if [[ -n "$color4" ]]; then
            echo "$color4"
        else
            echo "$DEFAULT_COLOR"
        fi
    }

    # Static CIDs for infrastructure VMs (not profile-driven, not in registry)
    declare -A INFRA_MICROVM_CIDS=(
        ["microvm-router"]=200
        ["microvm-builder"]=210
        ["microvm-gitsync"]=211
    )

    # Registry file: generated at activation from profile meta.nix files
    VM_REGISTRY="/etc/hydrix/vm-registry.json"

    get_cid() {
        local vm_name="$1"

        if is_microvm "$vm_name"; then
            # MicroVM: check systemd service status
            local service="microvm@''${vm_name}.service"

            # Check if microVM service is running
            if ! systemctl is-active --quiet "$service" 2>/dev/null; then
                error "MicroVM '$vm_name' is not running.
Start with: sudo systemctl start $service"
            fi

            # Fast path 1: infrastructure VMs (fixed CIDs)
            if [[ -v "INFRA_MICROVM_CIDS[$vm_name]" ]]; then
                echo "''${INFRA_MICROVM_CIDS[$vm_name]}"
                return
            fi

            # Fast path 2: registry file (profile-based VMs)
            if [[ -f "$VM_REGISTRY" ]]; then
                local profile="''${vm_name#microvm-}"
                local cid
                cid=$(${pkgs.jq}/bin/jq -r --arg p "$profile" '.[$p].cid // empty' "$VM_REGISTRY" 2>/dev/null || echo "")
                if [[ -n "$cid" ]]; then
                    echo "$cid"
                    return
                fi
            fi

            # Fallback: Get CID from the flake configuration (requires nix-daemon)
            local cid
            cid=$(nix eval --json ".#nixosConfigurations.''${vm_name}.config.hydrix.microvm.vsockCid" 2>/dev/null) || \
                error "Cannot read vsock CID for microVM '$vm_name'.
Is it defined in the flake?"

            echo "$cid"
        else
            # Libvirt VM: existing logic
            # Check VM exists and is running
            local state
            state=$(sudo virsh --connect qemu:///system domstate "$vm_name" 2>/dev/null) || \
                error "VM '$vm_name' not found. Check 'sudo virsh list --all'."
            [[ "$state" != "running" ]] && \
                error "VM '$vm_name' is not running (state: $state)"

            # Extract vsock CID from live domain XML
            local cid
            # libvirt uses 'address' attribute and single quotes
            cid=$(sudo virsh --connect qemu:///system dumpxml "$vm_name" | \
                ${pkgs.gnugrep}/bin/grep -oP "<cid auto=['\"]yes['\"] address=['\"]\\K[0-9]+") || \
                error "No vsock device on VM '$vm_name'.
Fix: sudo virsh edit $vm_name
Add inside <devices>:
  <vsock model=\"virtio\"><cid auto=\"yes\"/></vsock>
Then restart the VM."

            echo "$cid"
        fi
    }

    wait_for_xpra() {
        local conn="$1"
        local max=20
        local i=0

        log "Waiting for xpra server..."
        while [[ $i -lt $max ]]; do
            if ${pkgs.xpra}/bin/xpra info "$conn" &>/dev/null; then
                return 0
            fi
            i=$((i + 1))
            sleep 1
        done

        error "xpra server not responding on $conn after ''${max}s.
Is the VM fully booted? Is xpra-vsock service running inside the VM?
Check with: virt-viewer $vm_name"
    }

    # Check if xpra client is already attached to this connection
    # Returns 0 if attached, 1 if not
    is_xpra_attached() {
        local cid="$1"
        # Check for running xpra attach process for this VM's vsock
        # Note: Nix wraps xpra as .xpra-wrapped, so match on "attach.*vsock://"
        ${pkgs.procps}/bin/pgrep -f "xpra.*attach.*vsock://$cid:$XPRA_PORT" >/dev/null 2>&1
    }

    do_attach() {
        local vm_name="$1"
        local conn="$2"
        local vm_type="$3"
        local border_color="$4"
        local background="''${5:-false}"

        # Read DPI from scaling.json if available, fallback to 96
        local xpra_dpi=96
        local scaling_json="$HOME/.config/hydrix/scaling.json"
        if [[ -f "$scaling_json" ]]; then
            local master_dpi
            master_dpi=$(${pkgs.jq}/bin/jq -r '.master_dpi // empty' "$scaling_json" 2>/dev/null)
            if [[ -n "$master_dpi" ]]; then
                # Round to integer (use LC_ALL=C for locale-safe printf)
                xpra_dpi=$(LC_ALL=C printf "%.0f" "$master_dpi")
            fi
        fi

        local title_prefix="[$vm_type]"
        local xpra_args=(
            "$conn"
            "--sharing=yes"
            "--border=off"
            "--headerbar=no"
            "--title=$title_prefix @title@"
            "--desktop-scaling=off"
            "--dpi=$xpra_dpi"
            "--splash=no"
            "--opengl=no"
            "--notifications=no"
            # Audio forwarding
            "--speaker=yes"
            # Encoding: rgb over vsock = zero compression, zero CPU
            # quality/speed/auto-refresh flags must NOT be set — quality=100 triggers
            # xpra's lossless path which silently overrides encoding=rgb back to png
            "--encoding=rgb"
            "-z0"
            "--auto-refresh-delay=0"  # Disable periodic full-screen lossless PNG refreshes
            "--video=no"
            "--modal-windows=yes"
            "--windows=yes"
        )

        if [[ "$background" == "true" ]]; then
            log "Attaching to $vm_name in background (border: $border_color)..."
            nohup ${pkgs.xpra}/bin/xpra attach "''${xpra_args[@]}" >/dev/null 2>&1 &
            disown
            log "Attached. Windows should appear on your desktop."
        else
            log "Attaching to $vm_name (border: $border_color)..."
            exec ${pkgs.xpra}/bin/xpra attach "''${xpra_args[@]}"
        fi
    }

    main() {
        [[ $# -lt 1 ]] && usage
        [[ "$1" == "-h" || "$1" == "--help" ]] && usage

        local vm_name="$1"
        shift
        [[ $# -lt 1 ]] && error "Missing command. Run 'vm-app --help' for usage."

        local cid vm_type border_color app_cmd
        app_cmd="$*" # Capture command before case statement modifies it
        cid=$(get_cid "$vm_name")
        vm_type=$(get_vm_type "$vm_name")
        border_color=$(get_border_color "$vm_type")
        local conn="vsock://''${cid}:''${XPRA_PORT}"

        case "$1" in
            --stop)
                log "Stopping xpra session on $vm_name..."
                ${pkgs.xpra}/bin/xpra stop "$conn" || true
                log "Done."
                ;;
            --info)
                ${pkgs.xpra}/bin/xpra info "$conn"
                ;;
            --attach)
                wait_for_xpra "$conn"
                do_attach "$vm_name" "$conn" "$vm_type" "$border_color" "false"
                ;;
            --attach-bg)
                wait_for_xpra "$conn"
                do_attach "$vm_name" "$conn" "$vm_type" "$border_color" "true"
                ;;
            --start)
                shift
                [[ $# -lt 1 ]] && error "Missing command after --start"
                local start_cmd="$*"
                wait_for_xpra "$conn"
                log "Starting '$start_cmd' on $vm_name..."
                ${pkgs.xpra}/bin/xpra control "$conn" start "$start_cmd"
                log "Started. Use 'vm-app $vm_name --attach' to view."
                ;;
            *)
                wait_for_xpra "$conn"

                # VM's alacritty uses its own config (font/colors from Stylix + colors-runtime.toml).
                # No host-side overrides needed — WINIT_X11_SCALE_FACTOR=1 is set in VM session env.
                log "Starting '$app_cmd' on $vm_name..."
                ${pkgs.xpra}/bin/xpra control "$conn" start -- sh -c "$app_cmd"

                # Only attach if not already attached
                # This avoids xpra client re-sync which causes visual glitches
                if is_xpra_attached "$cid"; then
                    log "Already attached to $vm_name, skipping re-attach"
                else
                    do_attach "$vm_name" "$conn" "$vm_type" "$border_color" "true"
                fi
                ;;
        esac
    }

    main "$@"
  '';

  # Rofi launcher for VM apps
  vmLaunch = pkgs.writeShellScriptBin "vm-launch" ''
    set -euo pipefail

    readonly SCALING_JSON="$HOME/.config/hydrix/scaling.json"

    # Common apps to offer in menu
    COMMON_APPS=(
        "firefox"
        "alacritty"
        "obsidian"
        "chromium"
        "nautilus"
        "code"
    )

    error() { echo "[vm-launch] ERROR: $*" >&2; ${pkgs.libnotify}/bin/notify-send -u critical "vm-launch" "$*"; exit 1; }

    # Get scaling value from scaling.json
    get_scaling_value() {
        local key="$1"
        local default="$2"
        if [[ -f "$SCALING_JSON" ]]; then
            ${pkgs.jq}/bin/jq -r "$key // $default" "$SCALING_JSON" 2>/dev/null || echo "$default"
        else
            echo "$default"
        fi
    }

    # Get color from xrdb (wal colors)
    get_color() {
        local name="$1"
        local fallback="$2"
        local color
        color=$(${pkgs.xorg.xrdb}/bin/xrdb -query 2>/dev/null | ${pkgs.gnugrep}/bin/grep -E "^\*\.?$name:" | head -1 | ${pkgs.gawk}/bin/awk '{print $2}')
        echo "''${color:-$fallback}"
    }

    # Build themed rofi config
    build_theme() {
        local num_items="''${1:-5}"
        local prompt="''${2:-}"
        local bar_gaps corner_radius font_size font_name
        bar_gaps=$(get_scaling_value '.sizes.bar_gaps' '10')
        corner_radius=$(get_scaling_value '.sizes.corner_radius' '8')
        font_size=$(get_scaling_value '.fonts.rofi' '12')
        font_name=$(get_scaling_value '.font_name' '${fontFamily}')

        local bg fg accent
        bg=$(get_color "color0" "#1a1b26")
        fg=$(get_color "color7" "#c0caf5")
        accent=$(get_color "color4" "#7aa2f7")

        cat <<EOF
configuration {
    font: "$font_name Bold $font_size";
    show-icons: false;
    disable-history: true;
    hover-select: true;
    me-select-entry: "";
    me-accept-entry: "MousePrimary";
    kb-cancel: "Escape,q";
    kb-accept-entry: "Return,KP_Enter";
    kb-row-up: "Up,k";
    kb-row-down: "Down,j";
}

* {
    bg: ''${bg}B3;
    bg-solid: $bg;
    fg: $fg;
    accent: $accent;
}

window {
    location: north;
    anchor: north;
    x-offset: -25%;
    y-offset: ''${bar_gaps}px;
    width: 200px;
    background-color: @bg;
    border: 0px;
    border-radius: ''${corner_radius}px;
}

mainbox {
    background-color: transparent;
    children: [inputbar, listview];
    padding: 4px;
}

listview {
    lines: $num_items;
    fixed-height: false;
    dynamic: true;
    scrollbar: false;
    background-color: transparent;
    spacing: 2px;
}

element {
    padding: 8px 12px;
    background-color: transparent;
    text-color: @fg;
    border-radius: ''${corner_radius}px;
    cursor: pointer;
}

element selected.normal {
    background-color: @accent;
    text-color: @bg-solid;
}

element-text {
    background-color: transparent;
    text-color: inherit;
    highlight: none;
}

inputbar {
    enabled: true;
    children: [prompt, entry];
    padding: 8px 12px;
    margin: 0;
    background-color: transparent;
    border: 0;
}

prompt {
    enabled: true;
    background-color: transparent;
    text-color: @accent;
}

entry {
    enabled: true;
    padding: 0 0 0 8px;
    background-color: transparent;
    text-color: @fg;
    cursor: text;
    placeholder: "";
}

scrollbar { enabled: false; }
EOF
    }

    # Run rofi with theme
    themed_rofi() {
        local prompt="$1"
        local num_items="$2"
        shift 2

        local theme_file
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/vm-launch-rofi-XXXXXX.rasi)
        build_theme "$num_items" "$prompt" > "$theme_file"

        local result
        result=$(${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -p "$prompt" "$@") || true

        rm -f "$theme_file"
        echo "$result"
    }

    # Get list of running VMs with xpra-compatible names (type-name pattern)
    get_running_vms() {
        # Get libvirt VMs
        local libvirt_vms
        libvirt_vms=$(sudo virsh --connect qemu:///system list --name 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -E '^(browsing|pentest|comms|dev)-' || true)

        # Get running microVMs (check systemd services)
        local microvms
        microvms=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z0-9-]+(?=\.service)' || true)

        # Combine results
        { echo "$libvirt_vms"; echo "$microvms"; } | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    # Main logic
    main() {
        # If arguments provided, use them directly
        if [[ $# -ge 2 ]]; then
            local vm_name="$1"
            shift
            local app_cmd="$*"
            exec ${vmApp}/bin/vm-app "$vm_name" "$app_cmd"
        fi

        if [[ $# -eq 1 ]]; then
            # Single arg could be "vm-name" (show app menu) or "type-app" shorthand
            local arg="$1"

            # Check if it's a running VM name
            if get_running_vms | ${pkgs.gnugrep}/bin/grep -qx "$arg"; then
                # It's a VM name, show app menu
                local app
                app=$(printf '%s\n' "''${COMMON_APPS[@]}" | themed_rofi "App" 6 -i)
                [[ -z "$app" ]] && exit 0
                exec ${vmApp}/bin/vm-app "$arg" "$app"
            fi

            # Try parsing as "type-app" shorthand (e.g., "browsing-firefox")
            local vm_type app_name
            vm_type=$(echo "$arg" | ${pkgs.gnused}/bin/sed -n 's/^\([a-z]*\)-\(.*\)/\1/p')
            app_name=$(echo "$arg" | ${pkgs.gnused}/bin/sed -n 's/^\([a-z]*\)-\(.*\)/\2/p')

            if [[ -n "$vm_type" && -n "$app_name" ]]; then
                # Find a running VM of this type
                local vm_name
                vm_name=$(get_running_vms | ${pkgs.gnugrep}/bin/grep "^$vm_type-" | head -1)
                [[ -z "$vm_name" ]] && error "No running $vm_type VM found"
                exec ${vmApp}/bin/vm-app "$vm_name" "$app_name"
            fi

            error "Invalid argument: $arg"
        fi

        # No arguments - full interactive mode
        local running_vms
        running_vms=$(get_running_vms)
        [[ -z "$running_vms" ]] && error "No xpra-compatible VMs running"

        # Count VMs for theme
        local vm_count
        vm_count=$(echo "$running_vms" | wc -l)

        # Select VM
        local vm_name
        vm_name=$(echo "$running_vms" | themed_rofi "VM" "$vm_count" -i)
        [[ -z "$vm_name" ]] && exit 0

        # Select or type app
        local app
        app=$(printf '%s\n' "''${COMMON_APPS[@]}" | themed_rofi "App" 6 -i)
        [[ -z "$app" ]] && exit 0

        exec ${vmApp}/bin/vm-app "$vm_name" "$app"
    }

    main "$@"
  '';

  # Workspace-aware app launcher
  # Workspace mapping:
  #   WS1, WS6-9: Host (no VM)
  #   WS2: Pentest (active VM tracking)
  #   WS3: Browsing (active VM tracking)
  #   WS4: Comms (microvm-comms-test)
  #   WS5: Dev (active VM tracking)
  #   WS10: Router terminal
  #
  # Active VM Tracking:
  #   - Remembers which VM you last selected per type
  #   - Super+Return uses the active VM if still running
  #   - If active VM stopped, auto-selects remaining VM or shows menu
  #   - App launcher (rofi) always shows menu and updates active VM
  wsApp = pkgs.writeShellScriptBin "ws-app" ''
    set -euo pipefail

    readonly ACTIVE_VMS_FILE="$HOME/.cache/hydrix/active-vms.json"
    readonly SCALING_JSON="$HOME/.config/hydrix/scaling.json"

    log()   { echo "[ws-app] $*" >&2; }
    notify() { ${pkgs.libnotify}/bin/notify-send -u normal "ws-app" "$*"; }
    error() { echo "[ws-app] ERROR: $*" >&2; ${pkgs.libnotify}/bin/notify-send -u critical "ws-app" "$*"; exit 1; }

    # Get scaling value from scaling.json
    get_scaling_value() {
        local key="$1"
        local default="$2"
        if [[ -f "$SCALING_JSON" ]]; then
            ${pkgs.jq}/bin/jq -r "$key // $default" "$SCALING_JSON" 2>/dev/null || echo "$default"
        else
            echo "$default"
        fi
    }

    # Get color from xrdb (wal colors)
    get_color() {
        local name="$1"
        local fallback="$2"
        local color
        color=$(${pkgs.xorg.xrdb}/bin/xrdb -query 2>/dev/null | ${pkgs.gnugrep}/bin/grep -E "^\*\.?$name:" | head -1 | ${pkgs.gawk}/bin/awk '{print $2}')
        echo "''${color:-$fallback}"
    }

    # Build themed rofi config
    build_theme() {
        local num_items="''${1:-5}"
        local bar_gaps corner_radius font_size font_name
        bar_gaps=$(get_scaling_value '.sizes.bar_gaps' '10')
        corner_radius=$(get_scaling_value '.sizes.corner_radius' '8')
        font_size=$(get_scaling_value '.fonts.rofi' '12')
        font_name=$(get_scaling_value '.font_name' '${fontFamily}')

        local bg fg accent
        bg=$(get_color "color0" "#1a1b26")
        fg=$(get_color "color7" "#c0caf5")
        accent=$(get_color "color4" "#7aa2f7")

        cat <<EOF
configuration {
    font: "$font_name Bold $font_size";
    show-icons: false;
    disable-history: true;
    hover-select: true;
    me-select-entry: "";
    me-accept-entry: "MousePrimary";
    kb-cancel: "Escape,q";
    kb-row-up: "Up,k";
    kb-row-down: "Down,j";
}
* {
    bg: ''${bg}B3;
    bg-solid: $bg;
    fg: $fg;
    accent: $accent;
}
window {
    location: north;
    anchor: north;
    x-offset: -25%;
    y-offset: ''${bar_gaps}px;
    width: 220px;
    background-color: @bg;
    border: 0px;
    border-radius: ''${corner_radius}px;
}
mainbox {
    background-color: transparent;
    children: [inputbar, listview];
    padding: 4px;
}
listview {
    lines: $num_items;
    fixed-height: false;
    dynamic: true;
    scrollbar: false;
    background-color: transparent;
    spacing: 2px;
}
element {
    padding: 8px 12px;
    background-color: transparent;
    text-color: @fg;
    border-radius: ''${corner_radius}px;
    cursor: pointer;
}
element selected.normal {
    background-color: @accent;
    text-color: @bg-solid;
}
element-text {
    background-color: transparent;
    text-color: inherit;
}
inputbar {
    enabled: true;
    children: [prompt, entry];
    padding: 8px 12px;
    background-color: transparent;
}
prompt {
    background-color: transparent;
    text-color: @accent;
}
entry {
    padding: 0 0 0 8px;
    background-color: transparent;
    text-color: @fg;
}
scrollbar { enabled: false; }
EOF
    }

    # Run rofi with theme
    themed_rofi() {
        local prompt="$1"
        local num_items="$2"
        shift 2

        local theme_file
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/ws-app-rofi-XXXXXX.rasi)
        build_theme "$num_items" > "$theme_file"

        local result
        result=$(${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -p "$prompt" "$@") || true

        rm -f "$theme_file"
        echo "$result"
    }

    # Ensure cache directory exists
    init_cache() {
        mkdir -p "$(dirname "$ACTIVE_VMS_FILE")"
        if [[ ! -f "$ACTIVE_VMS_FILE" ]]; then
            echo '{}' > "$ACTIVE_VMS_FILE"
        fi
    }

    # Get active VM for a type (returns empty if not set or not running)
    get_active_vm() {
        local vm_type="$1"
        init_cache
        ${pkgs.jq}/bin/jq -r ".\"$vm_type\" // empty" "$ACTIVE_VMS_FILE" 2>/dev/null || true
    }

    # Set active VM for a type
    set_active_vm() {
        local vm_type="$1"
        local vm_name="$2"
        init_cache
        local tmp
        tmp=$(mktemp)
        ${pkgs.jq}/bin/jq ".\"$vm_type\" = \"$vm_name\"" "$ACTIVE_VMS_FILE" > "$tmp" && mv "$tmp" "$ACTIVE_VMS_FILE"
    }

    # Clear active VM for a type
    clear_active_vm() {
        local vm_type="$1"
        init_cache
        local tmp
        tmp=$(mktemp)
        ${pkgs.jq}/bin/jq "del(.\"$vm_type\")" "$ACTIVE_VMS_FILE" > "$tmp" && mv "$tmp" "$ACTIVE_VMS_FILE"
    }

    # Get current focused workspace number
    get_workspace() {
        ${pkgs.i3}/bin/i3-msg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[] | select(.focused==true) | .num'
    }

    # Get list of running VMs
    get_running_vms() {
        local libvirt_vms
        libvirt_vms=$(sudo virsh --connect qemu:///system list --name 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -E '^(browsing|pentest|comms|dev|lurking)-' || true)

        local microvms
        microvms=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z0-9-]+(?=\.service)' || true)

        { echo "$libvirt_vms"; echo "$microvms"; } | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    # Find ALL running VMs of a given type (returns newline-separated list)
    find_vms_by_type() {
        local vm_type="$1"
        local running_vms
        running_vms=$(get_running_vms)

        # Get both microvm and libvirt VMs of this type
        {
            echo "$running_vms" | ${pkgs.gnugrep}/bin/grep -E "^microvm-$vm_type(-|$)" || true
            echo "$running_vms" | ${pkgs.gnugrep}/bin/grep "^$vm_type-" || true
        } | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    # Check if a specific VM is running
    is_vm_running() {
        local vm_name="$1"
        if [[ "$vm_name" == microvm-* ]]; then
            systemctl is-active --quiet "microvm@''${vm_name}.service" 2>/dev/null
        else
            local state
            state=$(sudo virsh --connect qemu:///system domstate "$vm_name" 2>/dev/null || echo "")
            [[ "$state" == "running" ]]
        fi
    }

    # Get VM for type with active VM tracking
    # Logic:
    #   1. If active VM is set and running, use it
    #   2. If active VM stopped, find running VMs of same type
    #      - If exactly one, use it and update active
    #      - If multiple, show menu and update active
    #      - If none, return empty
    get_vm_with_tracking() {
        local vm_type="$1"
        local active_vm running_vms count

        active_vm=$(get_active_vm "$vm_type")

        # If we have an active VM and it's still running, use it
        if [[ -n "$active_vm" ]] && is_vm_running "$active_vm"; then
            echo "$active_vm"
            return
        fi

        # Active VM not running (or not set) - find running VMs of this type
        running_vms=$(find_vms_by_type "$vm_type")

        if [[ -z "$running_vms" ]]; then
            # No VMs running - clear active and return empty
            clear_active_vm "$vm_type"
            return
        fi

        count=$(echo "$running_vms" | wc -l)

        if [[ "$count" -eq 1 ]]; then
            # Exactly one VM running - use it and update active
            set_active_vm "$vm_type" "$running_vms"
            echo "$running_vms"
        else
            # Multiple VMs - show selection menu
            local selected
            selected=$(echo "$running_vms" | themed_rofi "$vm_type" "$count" -i -no-custom)
            if [[ -n "$selected" ]]; then
                set_active_vm "$vm_type" "$selected"
                echo "$selected"
            fi
        fi
    }

    # Get VM config for workspace
    # Returns: "type:select" or "host" or "router"
    ws_to_vm_config() {
        local ws="$1"
        # Focus mode override
        local focus_file="$HOME/.cache/hydrix/focus-mode"
        if [[ -f "$focus_file" ]]; then
            local focus_type
            focus_type=$(cat "$focus_file")
            if [[ -n "$focus_type" ]]; then
                case "$ws" in
                    1|10) ;;  # Host and router workspaces never overridden
                    *)    echo "$focus_type:select"; return ;;
                esac
            fi
        fi
        # Fixed infrastructure workspaces
        case "$ws" in
            1)  echo "host"; return ;;
            10) echo "router"; return ;;
        esac
        # Registry lookup: find the profile assigned to this workspace number
        local VM_REGISTRY="/etc/hydrix/vm-registry.json"
        if [[ -f "$VM_REGISTRY" ]]; then
            local profile
            profile=$(${pkgs.jq}/bin/jq -r --argjson w "$ws" \
                'to_entries[] | select(.value.workspace == $w) | .key' \
                "$VM_REGISTRY" 2>/dev/null | head -1)
            if [[ -n "$profile" ]]; then
                echo "$profile:select"
                return
            fi
        fi
        echo "host"
    }

    # Run command on host (use alacritty-dpi for alacritty)
    run_on_host() {
        if [[ "$1" == "alacritty" ]]; then
            shift
            exec ${alacrittyDpi}/bin/alacritty-dpi "$@"
        else
            exec "$@"
        fi
    }

    # Open router console
    open_router_console() {
        # Try microvm-router first, then libvirt router-vm
        # Uses serial console (works without network connectivity)
        if systemctl is-active --quiet "microvm@microvm-router.service" 2>/dev/null; then
            notify "Connecting to microvm-router console..."
            exec ${alacrittyDpi}/bin/alacritty-dpi -e sudo socat -,rawer unix-connect:/var/lib/microvms/microvm-router/console.sock
        elif sudo virsh --connect qemu:///system domstate router-vm 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q running; then
            notify "Connecting to router-vm console..."
            exec ${alacrittyDpi}/bin/alacritty-dpi -e sudo virsh console router-vm
        else
            notify "No router VM running"
            exec ${alacrittyDpi}/bin/alacritty-dpi
        fi
    }

    main() {
        [[ $# -lt 1 ]] && error "Usage: ws-app <command> [args...]"

        local ws config
        ws=$(get_workspace)
        config=$(ws_to_vm_config "$ws")

        # Handle special cases
        case "$config" in
            host)
                run_on_host "$@"
                ;;
            router)
                open_router_console
                ;;
        esac

        # Parse config: "type:vm_name" or "type:select"
        local vm_type vm_spec
        vm_type="''${config%%:*}"
        vm_spec="''${config##*:}"

        local vm_name
        if [[ "$vm_spec" == "select" ]]; then
            # Dynamic selection with active VM tracking
            vm_name=$(get_vm_with_tracking "$vm_type")
        else
            # Fixed VM - check if running
            if systemctl is-active --quiet "microvm@''${vm_spec}.service" 2>/dev/null; then
                vm_name="$vm_spec"
            else
                vm_name=""
            fi
        fi

        if [[ -z "$vm_name" ]]; then
            ${pkgs.libnotify}/bin/notify-send -u normal "No VM found" "No $vm_type VM running - launching on host"
            run_on_host "$@"
        fi

        log "WS$ws -> $vm_name: $*"
        exec ${vmApp}/bin/vm-app "$vm_name" "$@"
    }

    main "$@"
  '';

  # Workspace-aware rofi launcher
  # Always shows VM selection menu and updates active VM
  # This is how users change which VM is "active" for ws-app
  wsRofi = pkgs.writeShellScriptBin "ws-rofi" ''
    set -euo pipefail

    readonly ACTIVE_VMS_FILE="$HOME/.cache/hydrix/active-vms.json"
    readonly SCALING_JSON="$HOME/.config/hydrix/scaling.json"

    COMMON_APPS=(
        "firefox"
        "alacritty"
        "thunar"
        "chromium"
        "nautilus"
        "code"
    )

    notify() { ${pkgs.libnotify}/bin/notify-send -u normal "ws-rofi" "$*"; }

    # Get scaling value from scaling.json
    get_scaling_value() {
        local key="$1"
        local default="$2"
        if [[ -f "$SCALING_JSON" ]]; then
            ${pkgs.jq}/bin/jq -r "$key // $default" "$SCALING_JSON" 2>/dev/null || echo "$default"
        else
            echo "$default"
        fi
    }

    # Get color from xrdb (wal colors)
    get_color() {
        local name="$1"
        local fallback="$2"
        local color
        color=$(${pkgs.xorg.xrdb}/bin/xrdb -query 2>/dev/null | ${pkgs.gnugrep}/bin/grep -E "^\*\.?$name:" | head -1 | ${pkgs.gawk}/bin/awk '{print $2}')
        echo "''${color:-$fallback}"
    }

    # Build themed rofi config
    build_theme() {
        local num_items="''${1:-5}"
        local bar_gaps corner_radius font_size font_name
        bar_gaps=$(get_scaling_value '.sizes.bar_gaps' '10')
        corner_radius=$(get_scaling_value '.sizes.corner_radius' '8')
        font_size=$(get_scaling_value '.fonts.rofi' '12')
        font_name=$(get_scaling_value '.font_name' '${fontFamily}')

        local bg fg accent
        bg=$(get_color "color0" "#1a1b26")
        fg=$(get_color "color7" "#c0caf5")
        accent=$(get_color "color4" "#7aa2f7")

        cat <<EOF
configuration {
    font: "$font_name Bold $font_size";
    show-icons: false;
    disable-history: true;
    hover-select: true;
    me-select-entry: "";
    me-accept-entry: "MousePrimary";
    kb-cancel: "Escape,q";
    kb-row-up: "Up,k";
    kb-row-down: "Down,j";
}
* {
    bg: ''${bg}B3;
    bg-solid: $bg;
    fg: $fg;
    accent: $accent;
}
window {
    location: north;
    anchor: north;
    x-offset: -25%;
    y-offset: ''${bar_gaps}px;
    width: 220px;
    background-color: @bg;
    border: 0px;
    border-radius: ''${corner_radius}px;
}
mainbox {
    background-color: transparent;
    children: [inputbar, listview];
    padding: 4px;
}
listview {
    lines: $num_items;
    fixed-height: false;
    dynamic: true;
    scrollbar: false;
    background-color: transparent;
    spacing: 2px;
}
element {
    padding: 8px 12px;
    background-color: transparent;
    text-color: @fg;
    border-radius: ''${corner_radius}px;
    cursor: pointer;
}
element selected.normal {
    background-color: @accent;
    text-color: @bg-solid;
}
element-text {
    background-color: transparent;
    text-color: inherit;
}
inputbar {
    enabled: true;
    children: [prompt, entry];
    padding: 8px 12px;
    background-color: transparent;
}
prompt {
    background-color: transparent;
    text-color: @accent;
}
entry {
    padding: 0 0 0 8px;
    background-color: transparent;
    text-color: @fg;
}
scrollbar { enabled: false; }
EOF
    }

    # Run rofi with theme
    themed_rofi() {
        local prompt="$1"
        local num_items="$2"
        shift 2

        local theme_file
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/ws-rofi-XXXXXX.rasi)
        build_theme "$num_items" > "$theme_file"

        local result
        result=$(${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -p "$prompt" "$@") || true

        rm -f "$theme_file"
        echo "$result"
    }

    # Ensure cache directory exists
    init_cache() {
        mkdir -p "$(dirname "$ACTIVE_VMS_FILE")"
        if [[ ! -f "$ACTIVE_VMS_FILE" ]]; then
            echo '{}' > "$ACTIVE_VMS_FILE"
        fi
    }

    # Get active VM for a type
    get_active_vm() {
        local vm_type="$1"
        init_cache
        ${pkgs.jq}/bin/jq -r ".\"$vm_type\" // empty" "$ACTIVE_VMS_FILE" 2>/dev/null || true
    }

    # Set active VM for a type
    set_active_vm() {
        local vm_type="$1"
        local vm_name="$2"
        init_cache
        local tmp
        tmp=$(mktemp)
        ${pkgs.jq}/bin/jq ".\"$vm_type\" = \"$vm_name\"" "$ACTIVE_VMS_FILE" > "$tmp" && mv "$tmp" "$ACTIVE_VMS_FILE"
    }

    get_workspace() {
        ${pkgs.i3}/bin/i3-msg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[] | select(.focused==true) | .num'
    }

    get_running_vms() {
        local libvirt_vms
        libvirt_vms=$(sudo virsh --connect qemu:///system list --name 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -E '^(browsing|pentest|comms|dev|lurking)-' || true)

        local microvms
        microvms=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z0-9-]+(?=\.service)' || true)

        { echo "$libvirt_vms"; echo "$microvms"; } | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    find_vms_by_type() {
        local vm_type="$1"
        local running_vms
        running_vms=$(get_running_vms)

        {
            echo "$running_vms" | ${pkgs.gnugrep}/bin/grep -E "^microvm-$vm_type(-|$)" || true
            echo "$running_vms" | ${pkgs.gnugrep}/bin/grep "^$vm_type-" || true
        } | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    # Check if a specific VM is running
    is_vm_running() {
        local vm_name="$1"
        if [[ "$vm_name" == microvm-* ]]; then
            systemctl is-active --quiet "microvm@''${vm_name}.service" 2>/dev/null
        else
            local state
            state=$(sudo virsh --connect qemu:///system domstate "$vm_name" 2>/dev/null || echo "")
            [[ "$state" == "running" ]]
        fi
    }

    # Select VM from running VMs, always showing menu
    # Marks the current active VM with a star
    # Updates active VM on selection
    select_vm_for_app() {
        local vm_type="$1"
        local running_vms active_vm display_list vm_count

        running_vms=$(find_vms_by_type "$vm_type")
        [[ -z "$running_vms" ]] && return

        active_vm=$(get_active_vm "$vm_type")
        vm_count=$(echo "$running_vms" | wc -l)

        # Build display list with active marker
        display_list=""
        while IFS= read -r vm; do
            [[ -z "$vm" ]] && continue
            if [[ "$vm" == "$active_vm" ]] && is_vm_running "$vm"; then
                display_list+="★ $vm"$'\n'
            else
                display_list+="  $vm"$'\n'
            fi
        done <<< "$running_vms"

        # Show selection (pre-select active if it exists)
        local selected
        selected=$(echo -n "$display_list" | themed_rofi "$vm_type" "$vm_count" -i -no-custom)

        if [[ -n "$selected" ]]; then
            # Strip the marker prefix (either "★ " or "  ")
            selected=$(echo "$selected" | ${pkgs.gnused}/bin/sed 's/^★ //; s/^  //')
            set_active_vm "$vm_type" "$selected"
            echo "$selected"
        fi
    }

    # Get VM config for workspace (matches ws-app)
    ws_to_vm_config() {
        local ws="$1"
        # Focus mode override
        local focus_file="$HOME/.cache/hydrix/focus-mode"
        if [[ -f "$focus_file" ]]; then
            local focus_type
            focus_type=$(cat "$focus_file")
            if [[ -n "$focus_type" ]]; then
                case "$ws" in
                    1|10) ;;  # Host and router workspaces never overridden
                    *)    echo "$focus_type:select"; return ;;
                esac
            fi
        fi
        # Fixed infrastructure workspaces
        case "$ws" in
            1)  echo "host"; return ;;
            10) echo "router"; return ;;
        esac
        # Registry lookup: find the profile assigned to this workspace number
        local VM_REGISTRY="/etc/hydrix/vm-registry.json"
        if [[ -f "$VM_REGISTRY" ]]; then
            local profile
            profile=$(${pkgs.jq}/bin/jq -r --argjson w "$ws" \
                'to_entries[] | select(.value.workspace == $w) | .key' \
                "$VM_REGISTRY" 2>/dev/null | head -1)
            if [[ -n "$profile" ]]; then
                echo "$profile:select"
                return
            fi
        fi
        echo "host"
    }

    main() {
        local ws config
        ws=$(get_workspace)
        config=$(ws_to_vm_config "$ws")

        case "$config" in
            host|router)
                exec ${pkgs.rofi}/bin/rofi -show drun
                ;;
        esac

        local vm_type vm_spec
        vm_type="''${config%%:*}"
        vm_spec="''${config##*:}"

        local vm_name
        if [[ "$vm_spec" == "select" ]]; then
            # Always show VM selection menu - this is how users change active VM
            vm_name=$(select_vm_for_app "$vm_type")
        else
            if systemctl is-active --quiet "microvm@''${vm_spec}.service" 2>/dev/null; then
                vm_name="$vm_spec"
            else
                vm_name=""
            fi
        fi

        if [[ -z "$vm_name" ]]; then
            notify "No $vm_type VM running - showing host launcher"
            exec ${pkgs.rofi}/bin/rofi -show drun
        fi

        # Show app menu for this VM
        local app
        app=$(printf '%s\n' "''${COMMON_APPS[@]}" | themed_rofi "$vm_name" 6 -i)
        [[ -z "$app" ]] && exit 0

        exec ${vmApp}/bin/vm-app "$vm_name" "$app"
    }

    main "$@"
  '';

  # Pre-attach to all running VMs (microVMs and libvirt)
  # This ensures first app launch is instant even after login
  xpraPreAttach = pkgs.writeShellScriptBin "xpra-preattach" ''
    set -euo pipefail

    XPRA_PORT=14500
    LOG="/tmp/xpra-preattach.log"

    # Registry file: generated at activation from profile meta.nix files
    VM_REGISTRY="/etc/hydrix/vm-registry.json"

    log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

    # Check if already attached to a VM
    is_attached() {
        local cid="$1"
        ${pkgs.procps}/bin/pgrep -f "xpra.*attach.*vsock://$cid:$XPRA_PORT" >/dev/null 2>&1
    }

    # Get CID for microVM (registry lookup, fallback to nix eval)
    get_microvm_cid() {
        local vm_name="$1"
        # Registry lookup (profile-based VMs)
        if [[ -f "$VM_REGISTRY" ]]; then
            local profile="''${vm_name#microvm-}"
            local cid
            cid=$(${pkgs.jq}/bin/jq -r --arg p "$profile" '.[$p].cid // empty' "$VM_REGISTRY" 2>/dev/null || echo "")
            if [[ -n "$cid" ]]; then
                echo "$cid"
                return
            fi
        fi
        # Fallback to nix eval
        nix eval --json ".#nixosConfigurations.''${vm_name}.config.hydrix.microvm.vsockCid" 2>/dev/null || true
    }

    # Try to attach to a VM
    try_attach() {
        local vm_name="$1"
        local cid="$2"
        local conn="vsock://$cid:$XPRA_PORT"

        # Check if xpra is responding
        if ! ${pkgs.xpra}/bin/xpra info "$conn" &>/dev/null; then
            log "  xpra not ready on $vm_name (CID:$cid), skipping"
            return 1
        fi

        # Check if already attached
        if is_attached "$cid"; then
            log "  Already attached to $vm_name"
            return 0
        fi

        # Attach in background
        log "  Pre-attaching to $vm_name (CID:$cid)..."
        vm-app "$vm_name" --attach >/dev/null 2>&1 &
        disown
        return 0
    }

    log "=== Pre-attach starting ==="

    attached_count=0

    # ===== MicroVMs =====
    running_microvms=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | \
        ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z0-9-]+(?=\.service)' || true)

    if [ -n "$running_microvms" ]; then
        log "Found running microVMs"
        while IFS= read -r vm_name; do
            [ -z "$vm_name" ] && continue

            # Skip router and builder (no xpra)
            [[ "$vm_name" == *-router* || "$vm_name" == *-builder* ]] && continue

            log "Checking microVM: $vm_name..."

            # Get CID (cached or fallback)
            cid=$(get_microvm_cid "$vm_name")
            if [ -z "$cid" ] || [ "$cid" = "null" ]; then
                log "  No vsock CID for $vm_name, skipping"
                continue
            fi

            if try_attach "$vm_name" "$cid"; then
                ((attached_count++)) || true
            fi
        done <<< "$running_microvms"
    fi

    # ===== Libvirt VMs =====
    # Get running libvirt VMs that match our naming convention
    running_libvirt=$(sudo virsh --connect qemu:///system list --name 2>/dev/null | \
        ${pkgs.gnugrep}/bin/grep -E '^(browsing|pentest|comms|dev|lurking)-' || true)

    if [ -n "$running_libvirt" ]; then
        log "Found running libvirt VMs"
        while IFS= read -r vm_name; do
            [ -z "$vm_name" ] && continue

            log "Checking libvirt VM: $vm_name..."

            # Get CID from libvirt XML
            cid=$(sudo virsh --connect qemu:///system dumpxml "$vm_name" 2>/dev/null | \
                ${pkgs.gnugrep}/bin/grep -oP "<cid auto=['\"]yes['\"] address=['\"]\\K[0-9]+" || true)

            if [ -z "$cid" ]; then
                log "  No vsock CID for $vm_name, skipping"
                continue
            fi

            if try_attach "$vm_name" "$cid"; then
                ((attached_count++)) || true
            fi
        done <<< "$running_libvirt"
    fi

    if [ "$attached_count" -eq 0 ]; then
        log "No VMs to pre-attach"
    else
        log "Pre-attached to $attached_count VM(s)"
    fi

    log "=== Pre-attach complete ==="
  '';

  # Status command - show running VMs and their xpra apps
  vmStatus = pkgs.writeShellScriptBin "vm-status" ''
    set -euo pipefail

    # Registry file: generated at activation from profile meta.nix files
    VM_REGISTRY="/etc/hydrix/vm-registry.json"

    # Directories for layered lookup (user config first, then framework)
    CONFIG_DIR="${config.hydrix.paths.configDir}"
    FRAMEWORK_DIR="${config.hydrix.paths.hydrixDir}"
    XPRA_PORT=14500

    # Find profile file (check config dir first, then framework)
    find_profile() {
        local vm_type="$1"
        local candidates=(
            "$CONFIG_DIR/profiles/$vm_type/default.nix"
            "$CONFIG_DIR/profiles/$vm_type.nix"
            "$FRAMEWORK_DIR/profiles/$vm_type/default.nix"
            "$FRAMEWORK_DIR/profiles/$vm_type.nix"
        )
        for f in "''${candidates[@]}"; do
            [[ -f "$f" ]] && echo "$f" && return 0
        done
        echo ""
    }

    # Find colorscheme JSON (check config dir first, then framework)
    find_colorscheme() {
        local name="$1"
        local candidates=(
            "$CONFIG_DIR/colorschemes/$name.json"
            "$FRAMEWORK_DIR/colorschemes/$name.json"
        )
        for f in "''${candidates[@]}"; do
            [[ -f "$f" ]] && echo "$f" && return 0
        done
        echo ""
    }

    # Get border color for VM type
    get_color() {
        local vm_type="$1"

        local profile
        profile=$(find_profile "$vm_type")
        [[ -z "$profile" ]] && echo "#888888" && return

        local colorscheme
        colorscheme=$(${pkgs.gnugrep}/bin/grep -oP 'hydrix\.colorscheme\s*=\s*"\K[^"]+' "$profile" 2>/dev/null || true)
        [[ -z "$colorscheme" ]] && echo "#888888" && return

        local colorfile
        colorfile=$(find_colorscheme "$colorscheme")
        [[ -z "$colorfile" ]] && echo "#888888" && return

        ${pkgs.jq}/bin/jq -r '.colors.color4 // "#888888"' "$colorfile" 2>/dev/null
    }

    # Get running VMs with xpra support
    get_vms() {
        # Get libvirt VMs
        local libvirt_vms
        libvirt_vms=$(sudo virsh --connect qemu:///system list --name 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -E '^(browsing|pentest|comms|dev)-' || true)

        # Get running microVMs (check systemd services)
        local microvms
        microvms=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z0-9-]+(?=\.service)' || true)

        # Combine results
        { echo "$libvirt_vms"; echo "$microvms"; } | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    is_microvm() {
        [[ "$1" == microvm-* ]]
    }

    # Get CID for a VM
    get_cid() {
        local vm_name="$1"
        if is_microvm "$vm_name"; then
            # Registry lookup (profile-based VMs)
            if [[ -f "$VM_REGISTRY" ]]; then
                local profile="''${vm_name#microvm-}"
                local cid
                cid=$(${pkgs.jq}/bin/jq -r --arg p "$profile" '.[$p].cid // empty' "$VM_REGISTRY" 2>/dev/null || echo "")
                if [[ -n "$cid" ]]; then
                    echo "$cid"
                    return
                fi
            fi
            # Fallback: MicroVM get from flake (use --json since vsockCid is an integer)
            nix eval --json ".#nixosConfigurations.''${vm_name}.config.hydrix.microvm.vsockCid" 2>/dev/null || true
        else
            # Libvirt: get from XML
            sudo virsh --connect qemu:///system dumpxml "$vm_name" 2>/dev/null | \
                ${pkgs.gnugrep}/bin/grep -oP "<cid auto=['\"]yes['\"] address=['\"]\\K[0-9]+" || true
        fi
    }

    # Get VM type from name
    get_vm_type() {
        local vm_name="$1"
        if is_microvm "$vm_name"; then
            echo "$vm_name" | ${pkgs.gnused}/bin/sed -n 's/^microvm-\([a-z]*\).*/\1/p'
        else
            echo "$vm_name" | ${pkgs.gnused}/bin/sed -n 's/^\([a-z]*\).*/\1/p'
        fi
    }

    # Get windows from xpra session
    get_windows() {
        local cid="$1"
        ${pkgs.xpra}/bin/xpra info "vsock://$cid:$XPRA_PORT" 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -E '^windows\.[0-9]+\.(title|class-instance)=' | \
            ${pkgs.gnused}/bin/sed 's/windows\.\([0-9]*\)\.\(.*\)=\(.*\)/\1|\2|\3/' || true
    }

    main() {
        local vms
        vms=$(get_vms)

        if [[ -z "$vms" ]]; then
            echo "No xpra-compatible VMs running"
            exit 0
        fi

        echo "╭─────────────────────────────────────────────────────────╮"
        echo "│                    VM App Status                        │"
        echo "╰─────────────────────────────────────────────────────────╯"
        echo ""

        while IFS= read -r vm_name; do
            [[ -z "$vm_name" ]] && continue

            local vm_type cid color window_count
            vm_type=$(get_vm_type "$vm_name")
            cid=$(get_cid "$vm_name")
            color=$(get_color "$vm_type")

            if [[ -z "$cid" ]]; then
                echo "  $vm_name (no vsock)"
                continue
            fi

            # Check if xpra is responding
            if ! ${pkgs.xpra}/bin/xpra info "vsock://$cid:$XPRA_PORT" &>/dev/null; then
                echo "  $vm_name [$vm_type] CID:$cid $color - xpra not responding"
                continue
            fi

            window_count=$(${pkgs.xpra}/bin/xpra info "vsock://$cid:$XPRA_PORT" 2>/dev/null | \
                ${pkgs.gnugrep}/bin/grep -oP '^state\.windows=\K[0-9]+' || echo "0")

            echo "  $vm_name [$vm_type] CID:$cid $color"

            if [[ "$window_count" -gt 0 ]]; then
                # Get window titles
                ${pkgs.xpra}/bin/xpra info "vsock://$cid:$XPRA_PORT" 2>/dev/null | \
                    ${pkgs.gnugrep}/bin/grep -E '^windows\.[0-9]+\.title=' | \
                    ${pkgs.gnused}/bin/sed 's/windows\.[0-9]*\.title=/    ├─ /' | head -10
            else
                echo "    └─ (no windows)"
            fi
            echo ""
        done <<< "$vms"
    }

    main "$@"
  '';

  # Generate i3 config snippet for xpra window rules
  # Run: vm-i3-config >> ~/.config/i3/config
  vmI3Config = pkgs.writeShellScriptBin "vm-i3-config" ''
    cat <<'I3CONFIG'
# VM App Window Rules (generated by vm-i3-config)
# Disable i3 borders for xpra windows - use xpra's colored internal border instead
for_window [title="^\[browsing\]"] border none
for_window [title="^\[pentest\]"] border none
for_window [title="^\[comms\]"] border none
for_window [title="^\[dev\]"] border none

# Optional: float VM app windows
# for_window [title="^\[browsing\]"] floating enable
# for_window [title="^\[pentest\]"] floating enable
I3CONFIG
  '';

  # i3 focus daemon - dynamically changes border color based on focused window
  # Monitors focus events and updates Xresources + reloads i3 when focus changes
  #
  # Respects walrgb temporary mode:
  # - When ~/.cache/wal/.active exists, ALL windows use wal cache colors
  # - When it doesn't exist, VM windows use their profile colorscheme
  i3FocusDaemon = pkgs.writers.writePython3Bin "vm-focus-daemon" {
    libraries = [ pkgs.python3Packages.i3ipc ];
    flakeIgnore = [ "E501" "E305" "E302" ];
  } ''
    import i3ipc
    import signal
    import subprocess
    import json
    import re
    import sys
    from pathlib import Path

    # Paths to binaries (interpolated from Nix)
    I3_MSG = "${pkgs.i3}/bin/i3-msg"
    XRDB = "${pkgs.xorg.xrdb}/bin/xrdb"


    # Directories for layered lookup (user config first, then framework)
    CONFIG_DIR = Path("${config.hydrix.paths.configDir}")
    FRAMEWORK_DIR = Path("${config.hydrix.paths.hydrixDir}")
    SEARCH_DIRS = [CONFIG_DIR, FRAMEWORK_DIR]


    def find_profile(vm_type):
        """Find profile file (config dir first, then framework)."""
        for d in SEARCH_DIRS:
            for candidate in [
                d / "profiles" / vm_type / "default.nix",
                d / "profiles" / f"{vm_type}.nix",
            ]:
                if candidate.exists():
                    return candidate
        return None


    def find_colorscheme_file(name):
        """Find colorscheme JSON (config dir first, then framework)."""
        for d in SEARCH_DIRS:
            candidate = d / "colorschemes" / f"{name}.json"
            if candidate.exists():
                return candidate
        return None


    def get_wal_color():
        """Get color4 from wal cache."""
        wal_colors = Path.home() / ".cache/wal/colors.json"
        if wal_colors.exists():
            try:
                data = json.loads(wal_colors.read_text())
                return data.get("colors", {}).get("color4")
            except Exception:
                pass
        return None


    def get_color_for_type(vm_type):
        """Get border color from profile -> colorscheme -> color4.

        Uses layered lookup: config dir first, then framework dir.
        No caching - always reads fresh so profile changes take effect immediately.
        """
        profile = find_profile(vm_type)
        if not profile:
            return None

        colorscheme = None
        try:
            content = profile.read_text()
            match = re.search(r'hydrix\.colorscheme\s*=\s*"([^"]+)"', content)
            if match:
                colorscheme = match.group(1)
        except Exception:
            return None

        if not colorscheme:
            return None

        colorfile = find_colorscheme_file(colorscheme)
        if not colorfile:
            return None

        try:
            data = json.loads(colorfile.read_text())
            return data.get("colors", {}).get("color4")
        except Exception:
            return None


    def update_i3_color(color):
        """Update i3 focus color via Xresources and reload."""
        if not color:
            return

        # Update Xresources (specific property override)
        resource_data = f"i3wm.color4: {color}\n"
        try:
            subprocess.run([XRDB, "-merge"], input=resource_data.encode(), check=True)
        except Exception as e:
            print(f"Error running xrdb: {e}")
            return

        # Reload i3 config to apply the color change
        try:
            subprocess.run([I3_MSG, "reload"], stdout=subprocess.DEVNULL, check=True)
        except Exception as e:
            print(f"Error reloading i3: {e}")


    def main():
        """Main entry point."""
        # Track current state to avoid redundant reloads
        state = {
            "current_color": None,
            "i3": None,
        }

        def refresh_color():
            """Re-read color for the currently focused window and apply it."""
            i3conn = state["i3"]
            if not i3conn:
                return
            try:
                tree = i3conn.get_tree()
                focused = tree.find_focused()
                if not focused:
                    return
                title = focused.name or ""
                m = re.match(r'^\[(\w+)\]', title)
                if m:
                    new_color = get_color_for_type(m.group(1))
                else:
                    new_color = get_wal_color()
                if new_color:
                    state["current_color"] = new_color
                    update_i3_color(new_color)
                    print(f"vm-focus-daemon: refreshed color to {new_color}", flush=True)
            except Exception as e:
                print(f"vm-focus-daemon: refresh error: {e}", flush=True)

        def handle_sigusr1(signum, frame):
            """SIGUSR1: force re-read and re-apply colors (e.g. after display-setup)."""
            state["current_color"] = None  # Clear cache to force update
            refresh_color()

        signal.signal(signal.SIGUSR1, handle_sigusr1)

        def on_window_focus(i3conn, event):
            window = event.container
            title = window.name or ""

            # Detect VM type from title "[type] title"
            match = re.match(r'^\[(\w+)\]', title)

            if match:
                # VM window: ALWAYS use VM's profile colorscheme (regardless of wal state)
                # Re-reads profile each time so changes take effect immediately
                vm_type = match.group(1)
                new_color = get_color_for_type(vm_type)
            else:
                # Host window: use wal cache colors
                new_color = get_wal_color()

            # Only update if color actually changed
            if new_color and new_color != state["current_color"]:
                state["current_color"] = new_color
                update_i3_color(new_color)

        # Connect to i3
        try:
            # Try auto-discovery first
            i3 = i3ipc.Connection()
        except Exception:
            try:
                # Fallback: ask i3 for the socket path
                socket_path = subprocess.check_output(["${pkgs.i3}/bin/i3", "--get-socketpath"]).decode().strip()
                i3 = i3ipc.Connection(socket_path=socket_path)
            except Exception as e:
                print(f"Failed to connect to i3: {e}")
                sys.exit(1)

        state["i3"] = i3
        i3.on(i3ipc.Event.WINDOW_FOCUS, on_window_focus)
        print("vm-focus-daemon: listening for focus events (SIGUSR1 to refresh)...", flush=True)
        i3.main()


    if __name__ == "__main__":
        main()
  '';

in {
  environment.systemPackages = [
    pkgs.xpra
    pkgs.jq  # For parsing colorscheme JSON
    pkgs.fzf  # For TUI
    pkgs.bc  # For DPI calculation in vm-app
    pkgs.python3Packages.i3ipc  # For focus daemon
    alacrittyDpi  # DPI-aware alacritty (used by ws-app fallback and i3 keybindings)
    vmApp
    vmLaunch
    wsApp      # Workspace-aware app launcher
    wsRofi     # Workspace-aware rofi
    vmStatus
    vmI3Config
    i3FocusDaemon
    xpraPreAttach  # Pre-attach to all running VMs at session startup
  ];

  systemd.user.services.vm-focus-daemon = {
    description = "VM Focus Daemon (updates i3 border colors, X11 only)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "!WAYLAND_DISPLAY";
    serviceConfig = {
      ExecStart = "${i3FocusDaemon}/bin/vm-focus-daemon";
      Restart = "always";
      RestartSec = 3;
    };
  };
}
