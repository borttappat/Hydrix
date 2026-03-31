# Rofi Application Launcher Configuration
#
# Provides host-rofi command with:
# - Dynamic theming from xrdb colors and scaling.json
# - Workspace-aware: host launcher, VM app launcher, or VM start prompt
#
# The scaling.json values come from hydrix.graphical.* Nix options.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  fontFamily = config.hydrix.graphical.font.family;

  hostRofi = pkgs.writeShellScriptBin "host-rofi" ''
    set -euo pipefail

    readonly SCALING_JSON="$HOME/.config/hydrix/scaling.json"
    readonly MICROVM_SCRIPT="microvm"

    get_scaling_value() {
        local key="$1"
        local default="$2"
        if [[ -f "$SCALING_JSON" ]]; then
            local val
            val=$(${pkgs.jq}/bin/jq -r "$key // empty" "$SCALING_JSON" 2>/dev/null)
            echo "''${val:-$default}"
        else
            echo "$default"
        fi
    }

    get_color() {
        local name="$1"
        local fallback="$2"
        local color
        color=$(${pkgs.xorg.xrdb}/bin/xrdb -query 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -E "^\*\.?$name:" \
            | head -1 | ${pkgs.gawk}/bin/awk '{print $2}')
        echo "''${color:-$fallback}"
    }

    get_overlay_alpha() {
        if [[ -f "$SCALING_JSON" ]]; then
            ${pkgs.jq}/bin/jq -r '.sizes.overlay_alpha_hex // "D9"' "$SCALING_JSON" 2>/dev/null || echo "D9"
        else
            echo "D9"
        fi
    }

    get_current_workspace() {
        ${pkgs.i3}/bin/i3-msg -t get_workspaces 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r '.[] | select(.focused==true) | .name' \
            || echo "1"
    }

    build_theme() {
        local corner_radius font_size font_name overlay_alpha
        corner_radius=$(get_scaling_value '.sizes.corner_radius' '8')
        font_size=$(get_scaling_value '.fonts.rofi' '12')
        font_name=$(get_scaling_value '.font_names.rofi' "$(get_scaling_value '.font_name' '${fontFamily}')")
        overlay_alpha=$(get_overlay_alpha)

        local bg fg accent prefix
        bg=$(get_color "color0" "#101116")
        fg=$(get_color "color7" "#c0caf5")
        accent=$(get_color "color4" "#7aa2f7")
        prefix=$(get_color "color3" "#e0af68")

        cat <<EOF
    configuration {
        font: "''${font_name} Bold ''${font_size}";
        show-icons: false;
        disable-history: false;
        hover-select: true;
        me-select-entry: "";
        me-accept-entry: "MousePrimary";
        kb-cancel: "Escape,q";
        kb-accept-entry: "Return,KP_Enter";
        kb-row-up: "Up";
        kb-row-down: "Down";
    }

    * {
        bg: ''${bg}''${overlay_alpha};
        bg-solid: ''${bg};
        fg: ''${fg};
        accent: ''${accent};
        prefix: ''${prefix};
    }

    window {
        location: north;
        anchor: north;
        y-offset: 15%;
        width: 500px;
        background-color: @bg;
        border: 0px;
        border-radius: ''${corner_radius}px;
    }

    mainbox {
        background-color: transparent;
        children: [inputbar, listview];
        padding: 4px;
    }

    inputbar {
        enabled: true;
        children: [entry];
        background-color: transparent;
        padding: 8px 12px;
    }

    entry {
        enabled: true;
        background-color: transparent;
        text-color: @fg;
        cursor: text;
        placeholder: "Search...";
        placeholder-color: @prefix;
    }

    listview {
        lines: 8;
        fixed-height: false;
        dynamic: true;
        scrollbar: false;
        background-color: transparent;
        spacing: 2px;
        padding: 4px 0 0 0;
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

    scrollbar { enabled: false; }
    mode-switcher { enabled: false; }
EOF
    }

    build_prompt_theme() {
        local corner_radius font_size font_name overlay_alpha
        corner_radius=$(get_scaling_value '.sizes.corner_radius' '8')
        font_size=$(get_scaling_value '.fonts.rofi' '12')
        font_name=$(get_scaling_value '.font_names.rofi' "$(get_scaling_value '.font_name' '${fontFamily}')")
        overlay_alpha=$(get_overlay_alpha)

        local bg fg accent prefix
        bg=$(get_color "color0" "#101116")
        fg=$(get_color "color7" "#c0caf5")
        accent=$(get_color "color4" "#7aa2f7")
        prefix=$(get_color "color3" "#e0af68")

        cat <<EOF
    configuration {
        font: "''${font_name} Bold ''${font_size}";
        show-icons: false;
        disable-history: true;
        hover-select: true;
        me-select-entry: "";
        me-accept-entry: "MousePrimary";
        kb-cancel: "Escape,q,n";
        kb-accept-entry: "Return,KP_Enter,y";
        kb-row-up: "Up";
        kb-row-down: "Down";
    }

    * {
        bg: ''${bg}''${overlay_alpha};
        bg-solid: ''${bg};
        fg: ''${fg};
        accent: ''${accent};
        prefix: ''${prefix};
    }

    window {
        location: north;
        anchor: north;
        y-offset: 15%;
        width: 400px;
        background-color: @bg;
        border: 0px;
        border-radius: ''${corner_radius}px;
    }

    mainbox {
        background-color: transparent;
        children: [inputbar, message, listview];
        padding: 4px;
    }

    message {
        background-color: transparent;
        padding: 6px 10px;
    }

    textbox {
        background-color: transparent;
        text-color: @prefix;
    }

    inputbar {
        enabled: true;
        children: [entry];
        padding: 0;
        margin: 0;
        background-color: transparent;
        border: 0;
    }

    entry {
        enabled: true;
        padding: 0;
        margin: 0;
        background-color: transparent;
        text-color: transparent;
        cursor: text;
        placeholder: "";
    }

    listview {
        lines: 4;
        fixed-height: false;
        dynamic: true;
        scrollbar: false;
        background-color: transparent;
        spacing: 2px;
        padding: 4px 0 0 0;
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

    scrollbar { enabled: false; }
    mode-switcher { enabled: false; }
EOF
    }

    # Get running microvms by name
    get_running_microvms() {
        ${pkgs.systemd}/bin/systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z]+(-[a-z0-9-]+)?(?=\.service)' \
            | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    # Find running VMs matching a type (exact base name or prefixed variants)
    find_vms_by_type() {
        local vm_type="$1"
        local running
        running=$(get_running_microvms)
        {
            echo "$running" | ${pkgs.gnugrep}/bin/grep "^microvm-''${vm_type}$" || true
            echo "$running" | ${pkgs.gnugrep}/bin/grep "^microvm-''${vm_type}-" || true
        } | ${pkgs.gnugrep}/bin/grep -v '^$' | ${pkgs.coreutils}/bin/sort -u || true
    }

    is_vm_running() {
        local vm_type="$1"
        [[ -n "$(find_vms_by_type "$vm_type")" ]]
    }

    # Locate the VM's current NixOS system path via its microvm-run script
    get_vm_system_path() {
        local vm_name="$1"
        local runner vm_system

        # Resolve the microvm runner (current takes priority over booted)
        runner=""
        for p in \
            "/var/lib/microvms/''${vm_name}/current" \
            "/var/lib/microvms/''${vm_name}/booted"; do
            [[ -L "$p" ]] && { runner=$(readlink -f "$p"); break; }
        done

        [[ -z "$runner" ]] && return 1

        # The nixos-system path is embedded in the microvm-run script
        vm_system=$(${pkgs.gnugrep}/bin/grep -oP '/nix/store/\S+-nixos-system-\S+' \
            "''${runner}/bin/microvm-run" 2>/dev/null \
            | head -1 | ${pkgs.gnused}/bin/sed 's|/[^/]*$||')

        [[ -n "$vm_system" && -d "''${vm_system}/sw/share/applications" ]] \
            && echo "$vm_system" || return 1
    }

    # Prompt to start a VM of the given type
    show_vm_prompt() {
        local vm_type="$1"

        # Collect available (declared) microvms of this type
        local display_list=""
        local -a vm_names=()
        local microvm_base="microvm-''${vm_type}"

        if [[ -d "/var/lib/microvms/''${microvm_base}" ]]; then
            display_list+="''${microvm_base}"$'\n'
            vm_names+=("$microvm_base")
        fi

        # Also find any task/variant VMs (e.g. microvm-pentest-task1)
        for d in /var/lib/microvms/microvm-''${vm_type}-*/; do
            [[ -d "$d" ]] || continue
            local vname
            vname=$(${pkgs.coreutils}/bin/basename "$d")
            display_list+="''${vname}"$'\n'
            vm_names+=("$vname")
        done

        if [[ -z "$display_list" ]]; then
            ${pkgs.libnotify}/bin/notify-send -t 3000 "VM" "No ''${vm_type} VMs available"
            return
        fi

        display_list+="cancel"

        local theme_file selection
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
        build_prompt_theme > "$theme_file"

        selection=$(echo -n "$display_list" \
            | ${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -m -4 \
              -i -no-custom -p "" -mesg "Start ''${vm_type} VM" 2>/dev/null) || true
        ${pkgs.coreutils}/bin/rm -f "$theme_file"

        [[ -z "$selection" || "$selection" == "cancel" ]] && return

        ${pkgs.libnotify}/bin/notify-send -t 2000 "MicroVM" "Starting ''${selection}..."
        "$MICROVM_SCRIPT" start "$selection" &
        disown 2>/dev/null || true
    }

    # Show rofi drun scoped to the VM's installed apps
    show_vm_app_launcher() {
        local vm_type="$1"
        local running_vms vm_count selected

        running_vms=$(find_vms_by_type "$vm_type")
        vm_count=$(echo "$running_vms" | ${pkgs.gnugrep}/bin/grep -c . 2>/dev/null || echo 0)

        if [[ "$vm_count" -eq 1 ]]; then
            selected=$(echo "$running_vms" | head -1)
        else
            # Multiple — let user pick
            local theme_file
            theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
            build_prompt_theme > "$theme_file"
            selected=$(echo "$running_vms" \
                | ${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -m -4 \
                  -i -no-custom -p "" -mesg "Select VM" 2>/dev/null) || true
            ${pkgs.coreutils}/bin/rm -f "$theme_file"
            [[ -z "$selected" ]] && return
        fi

        local vm_system
        vm_system=$(get_vm_system_path "''${selected}") || true

        local theme_file
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
        build_theme > "$theme_file"

        if [[ -n "$vm_system" && -d "''${vm_system}/sw/share/applications" ]]; then
            XDG_DATA_DIRS="''${vm_system}/sw/share" \
                ${pkgs.rofi}/bin/rofi -show drun \
                -theme "$theme_file" -m -4 \
                -drun-reload-desktop-files \
                -run-command "vm-app ''${selected} {cmd}" \
                2>/dev/null || true
        else
            ${pkgs.libnotify}/bin/notify-send -t 3000 "VM" "Could not locate ''${selected} system path"
        fi

        ${pkgs.coreutils}/bin/rm -f "$theme_file"
    }

    # Host app launcher (no VM injection)
    show_app_launcher() {
        local theme_file
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
        build_theme > "$theme_file"
        ${pkgs.rofi}/bin/rofi -show drun -theme "$theme_file" -m -4 2>/dev/null || true
        ${pkgs.coreutils}/bin/rm -f "$theme_file"
    }

    # Map workspace number to VM type, or "host"
    ws_to_vm_type() {
        case "$1" in
            2)  echo "pentest" ;;
            3)  echo "browsing" ;;
            4)  echo "comms" ;;
            5)  echo "dev" ;;
            *)  echo "host" ;;
        esac
    }

    main() {
        local ws vm_type
        ws=$(get_current_workspace)
        vm_type=$(ws_to_vm_type "$ws")

        if [[ "$vm_type" == "host" ]]; then
            show_app_launcher
        elif is_vm_running "$vm_type"; then
            show_vm_app_launcher "$vm_type"
        else
            show_vm_prompt "$vm_type"
        fi
    }

    main "$@"
  '';

in {
  config = lib.mkIf config.hydrix.graphical.enable {
    environment.systemPackages = [ hostRofi ];

    home-manager.users.${username} = { pkgs, ... }: {
      stylix.targets.rofi.enable = false;

      programs.rofi = {
        enable = true;
        package = pkgs.rofi;
        terminal = "${pkgs.alacritty}/bin/alacritty";
      };
    };
  };
}
