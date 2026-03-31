# Rofi Application Launcher Configuration
#
# Provides host-rofi command with:
# - Dynamic theming from xrdb colors and scaling.json
# - Unified launcher: host apps + apps from all running microvms
#
# The scaling.json values come from hydrix.graphical.* Nix options.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  fontFamily = config.hydrix.graphical.font.family;

  # host-rofi script with dynamic theming
  hostRofi = pkgs.writeShellScriptBin "host-rofi" ''
    set -euo pipefail

    readonly SCALING_JSON="$HOME/.config/hydrix/scaling.json"

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
        color=$(${pkgs.xorg.xrdb}/bin/xrdb -query 2>/dev/null | ${pkgs.gnugrep}/bin/grep -E "^\*\.?$name:" | head -1 | ${pkgs.gawk}/bin/awk '{print $2}')
        echo "''${color:-$fallback}"
    }

    get_overlay_alpha() {
        if [[ -f "$SCALING_JSON" ]]; then
            ${pkgs.jq}/bin/jq -r '.sizes.overlay_alpha_hex // "D9"' "$SCALING_JSON" 2>/dev/null || echo "D9"
        else
            echo "D9"
        fi
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
        width: 250px;
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

    # Get running microvms
    get_running_microvms() {
        ${pkgs.systemd}/bin/systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z]+(-[a-z0-9-]+)?(?=\.service)' \
            | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    # Locate the VM's current NixOS system path in the nix store
    get_vm_system_path() {
        local vm_name="$1"
        local vm_system

        vm_system=$(${pkgs.systemd}/bin/systemctl show "microvm@''${vm_name}.service" \
            --property=ExecStart --value 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -oP '/nix/store/\S+-nixos-system-\S+' | head -1)

        if [[ -z "$vm_system" ]]; then
            for p in \
                "/var/lib/microvms/''${vm_name}/current" \
                "/var/lib/microvms/''${vm_name}/system"; do
                [[ -L "$p" ]] && { vm_system=$(readlink -f "$p"); break; }
            done
        fi

        [[ -n "$vm_system" ]] && echo "$vm_system" || return 1
    }

    # Populate out_dir with synthetic .desktop files for all running VM apps
    build_vm_desktop_dir() {
        local out_dir="$1"
        local running_vms
        running_vms=$(get_running_microvms)
        [[ -z "$running_vms" ]] && return

        while IFS= read -r vm; do
            [[ -z "$vm" ]] && continue
            local vm_system
            vm_system=$(get_vm_system_path "''${vm}") || continue
            [[ -d "''${vm_system}/sw/share/applications" ]] || continue

            local vm_short="''${vm#microvm-}"

            for desktop in "''${vm_system}/sw/share/applications"/*.desktop; do
                [[ -f "$desktop" ]] || continue
                ${pkgs.gnugrep}/bin/grep -q "^NoDisplay=true" "$desktop" 2>/dev/null && continue
                ${pkgs.gnugrep}/bin/grep -q "^Hidden=true"    "$desktop" 2>/dev/null && continue
                ${pkgs.gnugrep}/bin/grep -q "^Type=Application" "$desktop" 2>/dev/null || continue

                local name exec_line
                name=$(${pkgs.gnugrep}/bin/grep -m1 "^Name=" "$desktop" | cut -d= -f2-)
                exec_line=$(${pkgs.gnugrep}/bin/grep -m1 "^Exec=" "$desktop" | cut -d= -f2- \
                    | ${pkgs.gnused}/bin/sed 's/ *%[a-zA-Z]//g' \
                    | ${pkgs.gawk}/bin/awk '{print $1}')
                [[ -n "$name" && -n "$exec_line" ]] || continue

                local safe="''${vm}__''${name// /_}"
                {
                    echo '[Desktop Entry]'
                    echo 'Type=Application'
                    echo "Name=[''${vm_short}] ''${name}"
                    echo "Exec=vm-app ''${vm} ''${exec_line}"
                    echo 'Terminal=false'
                } > "''${out_dir}/applications/''${safe}.desktop"
            done
        done <<< "$running_vms"
    }

    show_app_launcher() {
        local theme_file vm_apps_dir
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
        vm_apps_dir=$(${pkgs.coreutils}/bin/mktemp -d /tmp/host-rofi-apps-XXXXXX)
        mkdir -p "''${vm_apps_dir}/applications"

        build_theme > "$theme_file"
        build_vm_desktop_dir "$vm_apps_dir"

        XDG_DATA_DIRS="''${vm_apps_dir}:''${XDG_DATA_DIRS:-/run/current-system/sw/share:$HOME/.nix-profile/share}" \
            ${pkgs.rofi}/bin/rofi -show drun -theme "$theme_file" -m -4 \
            -drun-reload-desktop-files 2>/dev/null || true

        ${pkgs.coreutils}/bin/rm -rf "$vm_apps_dir"
        ${pkgs.coreutils}/bin/rm -f "$theme_file"
    }

    show_app_launcher
  '';

in {
  config = lib.mkIf config.hydrix.graphical.enable {
    # Add host-rofi to system packages
    environment.systemPackages = [ hostRofi ];

    home-manager.users.${username} = { pkgs, ... }: {
      # Disable Stylix rofi theming - we use runtime colors via host-rofi
      stylix.targets.rofi.enable = false;

      programs.rofi = {
        enable = true;
        package = pkgs.rofi;
        terminal = "${pkgs.alacritty}/bin/alacritty";
      };
    };
  };
}
