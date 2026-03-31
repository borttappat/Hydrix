# Rofi Application Launcher Configuration
#
# Provides host-rofi command with:
# - Dynamic theming from xrdb colors and scaling.json
# - Workspace-aware VM prompts (WS2=pentest, WS3=browsing)
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

    get_current_workspace() {
        ${pkgs.i3}/bin/i3-msg -t get_workspaces 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[] | select(.focused==true) | .name' || echo "1"
    }

    readonly ACTIVE_VMS_FILE="$HOME/.cache/hydrix/active-vms.json"
    readonly COMMON_APPS="firefox
alacritty
thunar
chromium
code
burpsuite"

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
        tmp=$(${pkgs.coreutils}/bin/mktemp)
        ${pkgs.jq}/bin/jq ".\"$vm_type\" = \"$vm_name\"" "$ACTIVE_VMS_FILE" > "$tmp" && mv "$tmp" "$ACTIVE_VMS_FILE"
    }

    # Get running VMs (both microVM and libvirt)
    get_running_vms() {
        local libvirt_vms
        libvirt_vms=$(sudo ${pkgs.libvirt}/bin/virsh --connect qemu:///system list --name 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -E '^(browsing|pentest|comms|dev|lurking)-' || true)

        local microvms
        microvms=$(${pkgs.systemd}/bin/systemctl list-units --type=service --state=running --no-legend 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z]+(-[a-z0-9-]+)?(?=\.service)' || true)

        { echo "$libvirt_vms"; echo "$microvms"; } | ${pkgs.gnugrep}/bin/grep -v '^$' || true
    }

    # Find running VMs of a given type
    find_vms_by_type() {
        local vm_type="$1"
        local running_vms
        running_vms=$(get_running_vms)

        {
            echo "$running_vms" | ${pkgs.gnugrep}/bin/grep "^microvm-$vm_type$" || true
            echo "$running_vms" | ${pkgs.gnugrep}/bin/grep "^microvm-$vm_type-" || true
            echo "$running_vms" | ${pkgs.gnugrep}/bin/grep "^$vm_type-" || true
        } | ${pkgs.gnugrep}/bin/grep -v '^$' | ${pkgs.coreutils}/bin/sort -u || true
    }

    # Check if a specific VM is running
    is_specific_vm_running() {
        local vm_name="$1"
        if [[ "$vm_name" == microvm-* ]]; then
            ${pkgs.systemd}/bin/systemctl is-active --quiet "microvm@''${vm_name}.service" 2>/dev/null
        else
            local state
            state=$(sudo ${pkgs.libvirt}/bin/virsh --connect qemu:///system domstate "$vm_name" 2>/dev/null || echo "")
            [[ "$state" == "running" ]]
        fi
    }

    # Check if ANY VM of type is running
    is_vm_running() {
        local vm_type="$1"
        local vms
        vms=$(find_vms_by_type "$vm_type")
        [[ -n "$vms" ]]
    }

    build_theme() {
        local bar_gaps corner_radius font_size font_name overlay_alpha
        bar_gaps=$(get_scaling_value '.sizes.bar_gaps' '10')
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
        kb-row-up: "Up,k";
        kb-row-down: "Down,j";
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
        x-offset: -18%;
        y-offset: ''${bar_gaps}px;
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

    build_prompt_theme() {
        local bar_gaps corner_radius font_size font_name overlay_alpha
        bar_gaps=$(get_scaling_value '.sizes.bar_gaps' '10')
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
        kb-row-up: "Up,k";
        kb-row-down: "Down,j";
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
        x-offset: -18%;
        y-offset: ''${bar_gaps}px;
        width: 180px;
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
        lines: 2;
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

    # List all available VMs of a type (microVM + libvirt, running or not)
    list_available_vms() {
        local vm_type="$1"

        # Map VM types to microvm-* names
        local microvm_name="microvm-''${vm_type}"

        # MicroVM (check /var/lib/microvms directory)
        if [[ -d "/var/lib/microvms/''${microvm_name}" ]]; then
            echo "''${microvm_name}|microvm"
        fi

        # Libvirt VMs (all defined, not just running)
        local libvirt_vms
        libvirt_vms=$(sudo ${pkgs.libvirt}/bin/virsh --connect qemu:///system list --all --name 2>/dev/null | \
            ${pkgs.gnugrep}/bin/grep "^''${vm_type}-" || true)

        while IFS= read -r vm; do
            [[ -z "$vm" ]] && continue
            echo "''${vm}|libvirt"
        done <<< "$libvirt_vms"
    }

    show_vm_prompt() {
        local vm_type="$1"

        # Get all available VMs of this type
        local available_vms
        available_vms=$(list_available_vms "$vm_type")

        if [[ -z "$available_vms" ]]; then
            ${pkgs.libnotify}/bin/notify-send -t 3000 "VM" "No ''${vm_type} VMs available"
            return
        fi

        # Build display list with numbers and [M]/[L] markers
        local display_list=""
        local -a vm_names=()
        local -a vm_types=()
        local i=1

        while IFS='|' read -r vm_name vm_backend; do
            [[ -z "$vm_name" ]] && continue
            local indicator
            if [[ "$vm_backend" == "microvm" ]]; then
                indicator="[M]"
            else
                indicator="[L]"
            fi
            display_list+="''${i}. ''${indicator} ''${vm_name}"$'\n'
            vm_names+=("$vm_name")
            vm_types+=("$vm_backend")
            ((i++))
        done <<< "$available_vms"

        display_list+="q. cancel"
        local num_items=$i

        local theme_file
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
        build_prompt_theme > "$theme_file"

        local selection
        selection=$(echo -n "$display_list" | ${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -m -4 -i -auto-select -p "" -mesg "Start ''${vm_type} VM" -format 'i' -selected-row 0 2>/dev/null) || true

        ${pkgs.coreutils}/bin/rm -f "$theme_file"

        # Empty or last item (cancel) = exit
        if [[ -z "$selection" || "$selection" -eq $((num_items - 1)) ]]; then
            return
        fi

        if [[ "$selection" -lt ''${#vm_names[@]} ]]; then
            local selected_vm="''${vm_names[$selection]}"
            local selected_type="''${vm_types[$selection]}"

            if [[ "$selected_type" == "microvm" ]]; then
                ${pkgs.libnotify}/bin/notify-send -t 2000 "MicroVM" "Starting ''${selected_vm}..."
                "$MICROVM_SCRIPT" start "$selected_vm" &
            else
                ${pkgs.libnotify}/bin/notify-send -t 2000 "Libvirt" "Starting ''${selected_vm}..."
                sudo ${pkgs.libvirt}/bin/virsh --connect qemu:///system start "$selected_vm" &
            fi
            disown 2>/dev/null || true

            # Set as active VM for this type
            set_active_vm "$vm_type" "$selected_vm"
        fi
    }

    show_app_launcher() {
        local theme_file
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
        build_theme > "$theme_file"

        ${pkgs.rofi}/bin/rofi -show drun -theme "$theme_file" -m -4 2>/dev/null || true

        ${pkgs.coreutils}/bin/rm -f "$theme_file"
    }

    # Show VM app menu, with optional VM selection if multiple are running
    show_vm_app_launcher() {
        local vm_type="$1"
        local running_vms vm_count selected

        running_vms=$(find_vms_by_type "$vm_type")
        vm_count=$(echo "$running_vms" | ${pkgs.gnugrep}/bin/grep -c . 2>/dev/null || echo 0)

        if [[ "$vm_count" -eq 1 ]]; then
            # Only one VM running — skip selection step
            selected=$(echo "$running_vms" | head -1)
        else
            # Multiple VMs — show selection menu with active marker
            local active_vm display_list theme_file
            active_vm=$(get_active_vm "$vm_type")
            display_list=""

            while IFS= read -r vm; do
                [[ -z "$vm" ]] && continue
                if [[ "$vm" == "$active_vm" ]] && is_specific_vm_running "$vm"; then
                    display_list+="★ $vm"$'\n'
                else
                    display_list+="  $vm"$'\n'
                fi
            done <<< "$running_vms"

            theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
            build_prompt_theme > "$theme_file"

            selected=$(echo -n "$display_list" | ${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -m -4 -i -no-custom -p "" -mesg "Select $vm_type VM" 2>/dev/null) || true
            ${pkgs.coreutils}/bin/rm -f "$theme_file"

            [[ -z "$selected" ]] && return
            selected=$(echo "$selected" | ${pkgs.gnused}/bin/sed 's/^★ //; s/^  //')
        fi

        set_active_vm "$vm_type" "$selected"

        # Show app menu for the selected VM
        local theme_file app
        theme_file=$(${pkgs.coreutils}/bin/mktemp /tmp/host-rofi-XXXXXX.rasi)
        build_theme > "$theme_file"

        app=$(echo -n "$COMMON_APPS" | ${pkgs.rofi}/bin/rofi -dmenu -theme "$theme_file" -m -4 -i -p "$selected" 2>/dev/null) || true
        ${pkgs.coreutils}/bin/rm -f "$theme_file"

        if [[ -n "$app" ]]; then
            vm-app "$selected" "$app" &
            disown 2>/dev/null || true
        fi
    }

    # Get workspace VM config
    # Returns: "type:select" or "type:fixed_vm" or "host" or "router"
    ws_to_vm_config() {
        case "$1" in
            2)   echo "pentest:select" ;;              # Pentest workspace
            3)   echo "browsing:select" ;;             # Browsing workspace
            4)   echo "comms:microvm-comms" ;;
            5)   echo "dev:select" ;;                  # Dev workspace
            10)  echo "router" ;;
            *)   echo "host" ;;
        esac
    }

    main() {
        local ws config
        ws=$(get_current_workspace)
        config=$(ws_to_vm_config "$ws")

        case "$config" in
            host)
                show_app_launcher
                ;;
            router)
                # On router workspace, just show app launcher (router has no GUI)
                show_app_launcher
                ;;
            *)
                # VM workspace
                local vm_type vm_spec
                vm_type="''${config%%:*}"
                vm_spec="''${config##*:}"

                if ! is_vm_running "$vm_type"; then
                    # No VM running - fall back to host launcher
                    show_app_launcher
                else
                    show_vm_app_launcher "$vm_type"
                fi
                ;;
        esac
    }

    main "$@"
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
