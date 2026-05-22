# Wofi Launcher - Wayland Equivalent of host-rofi
#
# Workspace-aware launcher that:
# - Host workspace: shows host drun (applications)
# - VM workspace (VM running): shows VM's applications via wofi
# - VM workspace (VM stopped): prompts to start the VM
#
# Mirrors host-rofi functionality for Wayland/sway.
# Gated on hydrix.sway.enable.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  fontFamily = config.hydrix.graphical.font.family;
  scalingJson = "$HOME/.config/hydrix/scaling.json";

  # Compute font size from Nix options — same formula as waybar.nix.
  # Used as the fallback when scaling.json is absent (Hyprland/Wayland: hydrix-scale
  # is X11-only, so scaling.json is not regenerated under a Wayland session).
  wofiSize = let
    base     = config.hydrix.graphical.font.size;
    relation = config.hydrix.graphical.font.relations.wofi or
               config.hydrix.graphical.font.relations.rofi or 1.0;
    raw      = builtins.floor (base * relation);
  in toString (if raw < 11 then 11 else raw);

  wofiCornerRadius = toString (config.hydrix.graphical.ui.cornerRadius or 2);

  wofiLauncher = pkgs.writeShellScriptBin "wofi-launcher" ''
    set -euo pipefail

    readonly SCALING_JSON="${scalingJson}"
    readonly MICROVM_SCRIPT="microvm"
    readonly VM_REGISTRY="/etc/hydrix/vm-registry.json"

    # ── Scaling & Theme Functions ──────────────────────────────────────────

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

    # ── Workspace Detection ────────────────────────────────────────────────

    get_current_workspace() {
        if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
            ${pkgs.hyprland}/bin/hyprctl activeworkspace -j 2>/dev/null \
                | ${pkgs.jq}/bin/jq -r '.id' \
                || echo "1"
        else
            ${pkgs.sway}/bin/swaymsg -t get_workspaces 2>/dev/null \
                | ${pkgs.jq}/bin/jq -r '.[] | select(.focused==true) | .num' \
                || echo "1"
        fi
    }

    ws_to_vm_type() {
        local ws="$1"

        if [[ -f "$VM_REGISTRY" ]]; then
            local profile
            profile=$(${pkgs.jq}/bin/jq -r --argjson w "$ws" \
                'to_entries[] | select(.value.workspace == $w) | .key' \
                "$VM_REGISTRY" 2>/dev/null | head -1)
            if [[ -n "$profile" && "$profile" != "null" ]]; then
                echo "$profile"
                return
            fi
        fi
        echo "host"
    }

    # ── VM Detection ───────────────────────────────────────────────────────

    get_running_microvms() {
        ${pkgs.systemd}/bin/systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z]+(-[a-z0-9-]+)?(?=\.service)' \
            | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

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

    get_vm_system_path() {
        local vm_name="$1"
        local runner vm_system

        runner=""
        for p in \
            "/var/lib/microvms/''${vm_name}/current" \
            "/var/lib/microvms/''${vm_name}/booted"; do
            [[ -L "$p" ]] && { runner=$(readlink -f "$p"); break; }
        done

        [[ -z "$runner" ]] && return 1

        vm_system=$(${pkgs.gnugrep}/bin/grep -oP '/nix/store/\S+-nixos-system-\S+' \
            "''${runner}/bin/microvm-run" 2>/dev/null \
            | head -1 | ${pkgs.gnused}/bin/sed 's|/[^/]*$||')

        [[ -n "$vm_system" && -d "''${vm_system}/sw/share/applications" ]] \
            && echo "$vm_system" || return 1
    }

    # ── Theme Generation ───────────────────────────────────────────────────
    # Reads wal colors from colors.json (same data refresh-colors uses).
    # Falls back to colors.sh, then to puccy-neutral defaults matching Stylix.

    get_wal_color() {
        local key="$1"   # jq path, e.g. '.colors.color0'
        local fallback="$2"
        local wal_json="$HOME/.cache/wal/colors.json"
        local wal_sh="$HOME/.cache/wal/colors.sh"
        local color=""

        if [[ -f "$wal_json" ]]; then
            color=$(${pkgs.jq}/bin/jq -r "$key // empty" "$wal_json" 2>/dev/null)
        fi
        if [[ -z "$color" && -f "$wal_sh" ]]; then
            local sh_key
            sh_key=$(echo "$key" | ${pkgs.gnused}/bin/sed 's|.*\.\(color[0-9]*\)|\1|')
            color=$(${pkgs.gnugrep}/bin/grep -E "^''${sh_key}=" "$wal_sh" \
                | head -1 \
                | ${pkgs.gnused}/bin/sed "s/^[^=]*='//;s/'$//")
        fi
        echo "''${color:-$fallback}"
    }

    build_theme() {
        local corner_radius font_size font_name
        corner_radius=$(get_scaling_value '.sizes.corner_radius' '${wofiCornerRadius}')
        font_size=$(get_scaling_value '.fonts.wofi' '${wofiSize}')
        font_name=$(get_scaling_value '.font_names.wofi' "$(get_scaling_value '.font_name' '${fontFamily}')")

        local bg fg accent
        bg=$(get_wal_color '.colors.color0' '#0e0f17')
        fg=$(get_wal_color '.colors.color7' '#e4d1ef')
        accent=$(get_wal_color '.colors.color4' '#f09ea2')

        cat <<EOF
* {
    font-family: ''${font_name};
    font-size: ''${font_size}px;
    color: ''${fg};
}

#window {
    background-color: ''${bg};
    border-radius: ''${corner_radius}px;
    border: 0px solid transparent;
}

#outer-box {
    padding: 8px;
}

#input {
    background-color: transparent;
    border: none;
    border-bottom: 1px solid ''${accent};
    border-radius: 0;
    padding: 4px 8px;
    margin-bottom: 4px;
    color: ''${fg};
}

#scroll { }

#inner-box {
    padding: 4px;
}

#entry {
    padding: 6px 8px;
    border-radius: ''${corner_radius}px;
}

#entry:selected {
    background-color: ''${accent};
}

#text {
    color: ''${fg};
}

#text:selected {
    color: ''${bg};
}

#img {
    margin-right: 6px;
}
EOF
    }

    # Common wofi flags used by all invocations
    wofi_args() {
        local font_size font_name width height
        font_size=$(get_scaling_value '.fonts.wofi' '${wofiSize}')
        font_name=$(get_scaling_value '.font_names.wofi' "$(get_scaling_value '.font_name' '${fontFamily}')")
        width=$(get_scaling_value '.sizes.rofi_width' '600')
        height=$(get_scaling_value '.sizes.rofi_height' '400')
        echo "--show-icons --width=''${width} --height=''${height} --define=font=''${font_name} ''${font_size} --define=icon_theme=Papirus"
    }

    # ── VM Start Prompt ────────────────────────────────────────────────────

    show_vm_prompt() {
        local vm_type="$1"

        local display_list=""
        local microvm_base="microvm-''${vm_type}"

        if [[ -d "/var/lib/microvms/''${microvm_base}" ]]; then
            display_list+="''${microvm_base}"$'\n'
        fi

        for d in /var/lib/microvms/microvm-''${vm_type}-*/; do
            [[ -d "$d" ]] || continue
            local vname
            vname=$(${pkgs.coreutils}/bin/basename "$d")
            display_list+="''${vname}"$'\n'
        done

        if [[ -f "$VM_REGISTRY" ]]; then
            local registered_vm
            registered_vm=$(${pkgs.jq}/bin/jq -r --arg p "$vm_type" '.[$p].vmName // empty' "$VM_REGISTRY" 2>/dev/null)
            if [[ -n "$registered_vm" && "$registered_vm" != "null" ]]; then
                if ! echo "$display_list" | ${pkgs.gnugrep}/bin/grep -q "^''${registered_vm}$"; then
                    display_list+="''${registered_vm}"$'\n'
                fi
            fi
        fi

        if [[ -z "$display_list" ]]; then
            ${pkgs.libnotify}/bin/notify-send -t 3000 "VM" "No ''${vm_type} VMs available"
            return
        fi

        display_list+="cancel"

        local theme_file selection
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/wofi-launcher-XXXXXX.css)
        build_theme > "$theme_file"

        selection=$(echo -n "$display_list" \
            | ${pkgs.wofi}/bin/wofi --show dmenu \
              --style="$theme_file" \
              $(wofi_args) \
              --prompt="Start ''${vm_type} VM" \
              --no-search \
              2>/dev/null) || true

        ${pkgs.coreutils}/bin/rm -f "$theme_file"

        [[ -z "$selection" || "$selection" == "cancel" ]] && return

        ${pkgs.libnotify}/bin/notify-send -t 2000 "MicroVM" "Starting ''${selection}..."
        "$MICROVM_SCRIPT" start "$selection" &
        disown 2>/dev/null || true
    }

    # ── VM App Launcher ────────────────────────────────────────────────────

    show_vm_app_launcher() {
        local vm_type="$1"
        local running_vms vm_count selected

        running_vms=$(find_vms_by_type "$vm_type")
        vm_count=$(echo "$running_vms" | ${pkgs.gnugrep}/bin/grep -c . 2>/dev/null || echo 0)

        if [[ "$vm_count" -eq 1 ]]; then
            selected=$(echo "$running_vms" | head -1)
        else
            local theme_file
            theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/wofi-launcher-XXXXXX.css)
            build_theme > "$theme_file"

            selected=$(echo "$running_vms" \
                | ${pkgs.wofi}/bin/wofi --show dmenu \
                  --style="$theme_file" \
                  $(wofi_args) \
                  --prompt="Select VM" \
                  2>/dev/null) || true

            ${pkgs.coreutils}/bin/rm -f "$theme_file"
            [[ -z "$selected" ]] && return
        fi

        local vm_system
        vm_system=$(get_vm_system_path "''${selected}") || true

        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/wofi-launcher-XXXXXX.css)
        build_theme > "$theme_file"

        if [[ -n "$vm_system" && -d "''${vm_system}/sw/share/applications" ]]; then
            XDG_DATA_DIRS="''${vm_system}/sw/share:''${XDG_DATA_DIRS:-/run/current-system/sw/share}" \
                ${pkgs.wofi}/bin/wofi --show drun \
                --style="$theme_file" \
                $(wofi_args) \
                --run-command="vm-app ''${selected} {cmd}" \
                2>/dev/null || true
        else
            ${pkgs.libnotify}/bin/notify-send -t 3000 "VM" "Could not locate ''${selected} system path"
        fi

        ${pkgs.coreutils}/bin/rm -f "$theme_file"
    }

    # ── Host App Launcher ──────────────────────────────────────────────────

    show_host_launcher() {
        local theme_file
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/wofi-launcher-XXXXXX.css)
        build_theme > "$theme_file"
        ${pkgs.wofi}/bin/wofi --show drun --style="$theme_file" $(wofi_args) 2>/dev/null || true
        ${pkgs.coreutils}/bin/rm -f "$theme_file"
    }

    # ── Main Entry Point ───────────────────────────────────────────────────

    main() {
        local ws vm_type
        ws=$(get_current_workspace)
        vm_type=$(ws_to_vm_type "$ws")

        if [[ "$vm_type" == "host" ]]; then
            show_host_launcher
        elif is_vm_running "$vm_type"; then
            show_vm_app_launcher "$vm_type"
        else
            show_vm_prompt "$vm_type"
        fi
    }

    main "$@"
  '';

in {
  config = lib.mkIf (config.hydrix.graphical.enable && (config.hydrix.sway.enable || config.hydrix.hyprland.enable)) {
    environment.systemPackages = [ wofiLauncher ];

    home-manager.users.${username} = { pkgs, ... }: {
      programs.wofi = {
        enable = true;
        package = pkgs.wofi;
      };
    };
  };
}
