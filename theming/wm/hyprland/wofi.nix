# Wofi Launcher - Wayland Equivalent of host-rofi
#
# Workspace-aware launcher that:
# - Host workspace: shows host drun (applications)
# - VM workspace (VM running): shows VM executables from /nix/store sw/bin/
# - VM workspace (VM stopped): prompts to start the VM
#
# VM apps are listed from the VM's nix store profile (sw/bin/), which is
# accessible from the host without SSH. Selected app is launched inside the
# VM via hypr-ws-app.
#
# Mirrors host-rofi functionality for Wayland/Hyprland.
# Gated on hydrix.hyprland.enable.
#
# Style: split like waybar (style.css imports colors.css). style.css is
# structural (font/padding/radius from Nix), written once per rebuild via
# home.activation and hand-editable in between. colors.css holds only
# @define-color background/foreground/accent, written by hypr-apply-colors
# on every colorscheme change, same as waybar's own colors.css.
{
  config,
  lib,
  pkgs,
  ...
}: let
  username = config.hydrix.username;
  fontFamily = config.hydrix.graphical.font.family;

  # Compute font size from Nix options - same formula as waybar.nix.
  wofiSize = let
    base = config.hydrix.graphical.font.size;
    relation = config.hydrix.graphical.font.relations.wofi or 1.0;
    raw = builtins.floor (base * relation);
  in
    toString (
      if raw < 11
      then 11
      else raw
    );

  # Scaled up from the shared waybar pill-radius formula (which stays sharp
  # at low cornerRadius values, e.g. 2px) so wofi reads as visibly rounded
  # without changing waybar's own pill radius.
  wofiCornerRadius = let
    ui = config.hydrix.graphical.ui;
    pillRadius =
      if (ui.pillRadius or null) != null
      then ui.pillRadius
      else builtins.floor ((ui.cornerRadius or 2) * (ui.pillRadiusScale or 2.0));
  in
    toString (pillRadius * 2);
  wofiWidth = toString config.hydrix.graphical.ui.rofiWidth;
  wofiHeight = toString config.hydrix.graphical.ui.rofiHeight;

  # wofi is a layer-shell surface, so Hyprland's decoration active_opacity
  # (window-only) never reaches it; transparency has to be baked into its
  # own GTK CSS instead, same as Alacritty manages its own opacity.
  wofiOpacity = let
    o = config.hydrix.graphical.ui.opacity;
  in
    toString (o.overlayOverrides.wofi or o.overlay);

  homeDir = "/home/${username}";

  # Structural CSS only - all color values come from colors.css via @import.
  wofiStyleContent = ''
    @import url("file://${homeDir}/.config/wofi/colors.css");

    * {
        font-family: ${fontFamily};
        font-size: ${wofiSize}px;
        color: @foreground;
        transition: none;
        animation: none;
    }

    #window {
        background-color: alpha(@background, ${wofiOpacity});
        border-radius: ${wofiCornerRadius}px;
        border: 0px solid transparent;
    }

    #outer-box {
        padding: 8px;
    }

    #input {
        background-color: transparent;
        box-shadow: none;
        outline: none;
        border: none;
        border-bottom: 1px solid @accent;
        border-radius: 0;
        padding: 4px 8px;
        margin-bottom: 4px;
        color: @foreground;
    }

    #scroll { }

    #inner-box {
        padding: 4px;
    }

    #entry {
        padding: 6px 8px;
        border-radius: ${wofiCornerRadius}px;
    }

    #entry:selected {
        background-color: @accent;
    }

    #text {
        color: @foreground;
    }

    #text:selected {
        color: @background;
    }

    #img {
        margin-right: 6px;
    }
  '';

  # Fallback only - hypr-apply-colors owns this file from here on (matches
  # waybar's colors.css default in modules/waybar.nix).
  defaultWofiColorsCss = ''
    @define-color background #0c0c0c;
    @define-color foreground #d8dee9;
    @define-color accent     #7aa2f7;
  '';

  wofiLauncher = pkgs.writeShellScriptBin "wofi-launcher" ''
    set -euo pipefail

    readonly MICROVM_SCRIPT="microvm"
    readonly VM_REGISTRY="/etc/hydrix/vm-registry.json"
    readonly WOFI_STYLE="$HOME/.config/wofi/style.css"

    # ── Workspace Detection ────────────────────────────────────────────────

    get_current_workspace() {
        ${pkgs.hyprland}/bin/hyprctl activeworkspace -j 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r '.id' \
            || echo "1"
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

        [[ -n "$vm_system" && -d "''${vm_system}/sw/bin" ]] \
            && echo "$vm_system" || return 1
    }

    # Lists real GUI apps from a VM's .desktop entries rather than every raw
    # executable in bin/ (which includes CLI noise like coreutils' own "[").
    # Both sw/share/applications (systemPackages) and the user's home-manager
    # profile (etc/profiles/per-user/<user>/share/applications, statically
    # part of the same system closure when useUserPackages is set) --
    # packages installed only via home-manager (e.g. programs.burp) ship
    # their .desktop file in the latter, not sw/share. Outputs "Name<TAB>exec"
    # pairs; exec is the bare command hypr-ws-app resolves via the VM's PATH.
    list_vm_apps() {
        local vm_system="$1" dir f name exec_line bin
        for dir in \
            "''${vm_system}/etc/profiles/per-user/${username}/share/applications" \
            "''${vm_system}/sw/share/applications"; do
            [[ -d "$dir" ]] || continue
            for f in "''${dir}"/*.desktop; do
                [[ -f "$f" ]] || continue
                # Terminal=true apps (htop, joshuto, etc.) need a terminal
                # emulator wrapped around them -- hypr-ws-app just execs the
                # bare command with no tty, so nothing visibly happens.
                ${pkgs.gnugrep}/bin/grep -qE '^(NoDisplay|Hidden|Terminal)=true' "$f" 2>/dev/null && continue
                name=$(${pkgs.gnugrep}/bin/grep -m1 '^Name=' "$f" 2>/dev/null | ${pkgs.coreutils}/bin/cut -d= -f2-)
                exec_line=$(${pkgs.gnugrep}/bin/grep -m1 '^Exec=' "$f" 2>/dev/null | ${pkgs.coreutils}/bin/cut -d= -f2-)
                # First token of Exec=, field codes (%f/%U/etc.) and any path stripped.
                bin=$(echo "$exec_line" | ${pkgs.gawk}/bin/awk '{print $1}' | ${pkgs.gnused}/bin/sed 's#.*/##')
                [[ -n "$name" && -n "$bin" ]] && printf '%s\t%s\n' "$name" "$bin"
            done
        done | ${pkgs.coreutils}/bin/sort -u -t $'\t' -k1,1
    }

    # Common wofi flags used by all invocations
    # use_search_box=false swaps the GtkSearchEntry for a plain GtkEntry,
    # dropping its built-in search glyph and clear-text button.
    # no_actions=true drops the expander arrow drun shows on .desktop entries
    # that declare multiple actions (e.g. "New Window").
    wofi_args() {
        echo "--show-icons --width=${wofiWidth} --height=${wofiHeight} --style=$WOFI_STYLE --define=icon_theme=Papirus --define=use_search_box=false --define=no_actions=true"
    }

    # ── Encrypted Volume Unlock ────────────────────────────────────────────
    # Mirrors the LUKS unlock in scripts/microvm cmd_start, but captures the
    # passphrase via wofi's own --password dmenu mode (same pattern as
    # vault-pick.nix) instead of requiring a terminal. sudo is passwordless
    # for the interactive host user (security.sudo.wheelNeedsPassword = false),
    # so only the LUKS passphrase itself needs to be collected here.

    unlock_encrypted_volume() {
        local vm_name="$1"
        local luks_path="/var/lib/microvms/''${vm_name}/home.luks"
        local mapper_name="vm-''${vm_name}-home"

        [[ -f "$luks_path" ]] || return 0
        [[ -b "/dev/mapper/''${mapper_name}" ]] && return 0

        local password
        password=$(echo | ${pkgs.wofi}/bin/wofi --show dmenu \
            $(wofi_args) \
            --password \
            --prompt="Unlock ''${vm_name}:" \
            --no-search \
            --lines=0 \
            --hide-scroll \
            2>/dev/null) || true

        if [[ -z "$password" ]]; then
            ${pkgs.libnotify}/bin/notify-send -t 3000 "MicroVM" "Unlock cancelled for ''${vm_name}"
            return 1
        fi

        if ! printf '%s' "$password" | sudo ${pkgs.cryptsetup}/bin/cryptsetup luksOpen --key-file=- "$luks_path" "$mapper_name"; then
            ${pkgs.libnotify}/bin/notify-send -t 3000 -u critical "MicroVM" "Failed to unlock ''${vm_name} — wrong passphrase?"
            return 1
        fi

        return 0
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

        local selection
        selection=$(echo -n "$display_list" \
            | ${pkgs.wofi}/bin/wofi --show dmenu \
              $(wofi_args) \
              --prompt="Start ''${vm_type} VM" \
              --no-search \
              2>/dev/null) || true

        [[ -z "$selection" || "$selection" == "cancel" ]] && return

        unlock_encrypted_volume "$selection" || return

        ${pkgs.libnotify}/bin/notify-send -t 2000 "MicroVM" "Starting ''${selection}..."
        "$MICROVM_SCRIPT" start "$selection" &
        disown 2>/dev/null || true
    }

    # ── VM App Launcher ────────────────────────────────────────────────────
    # Lists executables from the VM's nix store profile (sw/bin/), accessible
    # from the host since /nix/store is shared. Shows them via wofi dmenu.
    # On selection, launches the command in the VM via hypr-ws-app.

    show_vm_app_launcher() {
        local vm_type="$1"
        local running_vms vm_count selected

        running_vms=$(find_vms_by_type "$vm_type")
        vm_count=$(echo "$running_vms" | ${pkgs.gnugrep}/bin/grep -c . 2>/dev/null || echo 0)

        if [[ "$vm_count" -eq 1 ]]; then
            selected=$(echo "$running_vms" | head -1)
        else
            selected=$(echo "$running_vms" \
                | ${pkgs.wofi}/bin/wofi --show dmenu \
                  $(wofi_args) \
                  --prompt="Select VM" \
                  2>/dev/null) || true

            [[ -z "$selected" ]] && return
        fi

        # List VM apps from .desktop entries (host-accessible via /nix/store) --
        # see list_vm_apps for why, not a raw bin/ listing.
        local vm_system app_list selected_name selected_app
        if vm_system=$(get_vm_system_path "$selected"); then
            app_list=$(list_vm_apps "$vm_system")
            selected_name=$(echo "$app_list" | ${pkgs.coreutils}/bin/cut -f1 \
                | ${pkgs.wofi}/bin/wofi --show dmenu \
                  $(wofi_args) \
                  --prompt="''${selected}" \
                  --insensitive \
                  2>/dev/null) || true
            selected_app=$(echo "$app_list" \
                | ${pkgs.gawk}/bin/awk -F'\t' -v n="$selected_name" '$1==n{print $2; exit}')

            if [[ -n "$selected_app" ]]; then
                if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
                    hypr-ws-app "$selected_app" &
                else
                    microvm app "''${selected}" "$selected_app" &
                fi
                disown 2>/dev/null || true
            fi
        else
            # Fallback: VM runner not found — notify user
            ${pkgs.libnotify}/bin/notify-send -t 4000 "VM" \
                "''${selected}: could not read app list (VM built?)"
        fi
    }

    # ── Host App Launcher (drun — icon picker) ─────────────────────────────

    show_host_launcher() {
        ${pkgs.wofi}/bin/wofi --show drun $(wofi_args) --prompt= 2>/dev/null || true
    }

    # ── Host Run Launcher (run — typed commands, like rofi -show run) ──────

    show_host_run_launcher() {
        ${pkgs.wofi}/bin/wofi --show run $(wofi_args) --prompt= 2>/dev/null || true
    }

    # ── Main Entry Point ───────────────────────────────────────────────────

    main() {
        # --host flag: always show host run launcher regardless of workspace
        if [[ "''${1:-}" == "--host" ]]; then
            show_host_run_launcher
            return
        fi

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

  # Cross-VM launcher — lists all running display VMs (not workspace-scoped),
  # lets user pick one then pick an app from that VM's sw/bin/.
  # Uses the same style.css as wofi-launcher.
  vmLaunch = pkgs.writeShellScriptBin "vm-launch" ''
    set -euo pipefail

    readonly VM_REGISTRY="/etc/hydrix/vm-registry.json"
    readonly WOFI_STYLE="$HOME/.config/wofi/style.css"

    wofi_pick() {
        local prompt="$1"
        local result
        result=$(${pkgs.wofi}/bin/wofi --show dmenu \
            --style="$WOFI_STYLE" \
            --width=${wofiWidth} \
            --height=${wofiHeight} \
            --prompt="$prompt" \
            --insensitive \
            2>/dev/null) || true
        echo "$result"
    }

    # ── VM discovery ──────────────────────────────────────────────────────────
    # Lists all running microvms that have hasDisplay != false in the registry.
    # Infra VMs (router, builder, gitsync, etc.) have hasDisplay: false and are excluded.

    get_running_display_vms() {
        ${pkgs.systemd}/bin/systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -oP 'microvm@\Kmicrovm-[a-z]+(-[a-z0-9-]+)?(?=\.service)' \
            | ${pkgs.gnugrep}/bin/grep -v '^$' \
            | while IFS= read -r vm; do
                local profile="''${vm#microvm-}"
                if [[ -f "$VM_REGISTRY" ]]; then
                    local has_display
                    has_display=$(${pkgs.jq}/bin/jq -r --arg p "$profile" \
                        '.[$p].hasDisplay // true' "$VM_REGISTRY" 2>/dev/null)
                    [[ "$has_display" == "false" ]] && continue
                fi
                echo "$vm"
              done || true
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

        [[ -n "$vm_system" && -d "''${vm_system}/sw/bin" ]] \
            && echo "$vm_system" || return 1
    }

    # Lists real GUI apps from a VM's .desktop entries rather than every raw
    # executable in bin/ (which includes CLI noise like coreutils' own "[").
    # Both sw/share/applications (systemPackages) and the user's home-manager
    # profile (etc/profiles/per-user/<user>/share/applications, statically
    # part of the same system closure when useUserPackages is set) --
    # packages installed only via home-manager (e.g. programs.burp) ship
    # their .desktop file in the latter, not sw/share. Outputs "Name<TAB>exec"
    # pairs; exec is the bare command hypr-ws-app resolves via the VM's PATH.
    list_vm_apps() {
        local vm_system="$1" dir f name exec_line bin
        for dir in \
            "''${vm_system}/etc/profiles/per-user/${username}/share/applications" \
            "''${vm_system}/sw/share/applications"; do
            [[ -d "$dir" ]] || continue
            for f in "''${dir}"/*.desktop; do
                [[ -f "$f" ]] || continue
                # Terminal=true apps (htop, joshuto, etc.) need a terminal
                # emulator wrapped around them -- hypr-ws-app just execs the
                # bare command with no tty, so nothing visibly happens.
                ${pkgs.gnugrep}/bin/grep -qE '^(NoDisplay|Hidden|Terminal)=true' "$f" 2>/dev/null && continue
                name=$(${pkgs.gnugrep}/bin/grep -m1 '^Name=' "$f" 2>/dev/null | ${pkgs.coreutils}/bin/cut -d= -f2-)
                exec_line=$(${pkgs.gnugrep}/bin/grep -m1 '^Exec=' "$f" 2>/dev/null | ${pkgs.coreutils}/bin/cut -d= -f2-)
                # First token of Exec=, field codes (%f/%U/etc.) and any path stripped.
                bin=$(echo "$exec_line" | ${pkgs.gawk}/bin/awk '{print $1}' | ${pkgs.gnused}/bin/sed 's#.*/##')
                [[ -n "$name" && -n "$bin" ]] && printf '%s\t%s\n' "$name" "$bin"
            done
        done | ${pkgs.coreutils}/bin/sort -u -t $'\t' -k1,1
    }

    main() {
        local running_vms selected_vm selected_app

        running_vms=$(get_running_display_vms)
        if [[ -z "$running_vms" ]]; then
            ${pkgs.libnotify}/bin/notify-send -t 3000 "vm-launch" "No display VMs running"
            exit 0
        fi

        local vm_count
        vm_count=$(echo "$running_vms" | ${pkgs.gnugrep}/bin/grep -c . 2>/dev/null || echo 0)

        if [[ "$vm_count" -eq 1 ]]; then
            selected_vm=$(echo "$running_vms" | head -1)
        else
            selected_vm=$(echo "$running_vms" | wofi_pick "VM")
            [[ -z "$selected_vm" ]] && exit 0
        fi

        local vm_system app_list selected_name
        if vm_system=$(get_vm_system_path "$selected_vm"); then
            app_list=$(list_vm_apps "$vm_system")
            selected_name=$(echo "$app_list" | ${pkgs.coreutils}/bin/cut -f1 | wofi_pick "''${selected_vm}")
            [[ -z "$selected_name" ]] && exit 0
            selected_app=$(echo "$app_list" \
                | ${pkgs.gawk}/bin/awk -F'\t' -v n="$selected_name" '$1==n{print $2; exit}')
            [[ -z "$selected_app" ]] && exit 0

            if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
                hypr-ws-app "$selected_app" &
            fi
            disown 2>/dev/null || true
        else
            ${pkgs.libnotify}/bin/notify-send -t 4000 "vm-launch" \
                "''${selected_vm}: could not read app list (VM built?)"
        fi
    }

    main "$@"
  '';
in {
  config = lib.mkIf (config.hydrix.graphical.enable && config.hydrix.hyprland.enable) {
    environment.systemPackages = [wofiLauncher vmLaunch];

    home-manager.users.${username} = {
      lib,
      pkgs,
      ...
    }: {
      programs.wofi = {
        enable = lib.mkDefault true;
        package = lib.mkDefault pkgs.wofi;
      };

      # style.css: structural, rebuild-only, hand-editable in between.
      # colors.css: only written if absent - hypr-apply-colors owns it from
      # here on, same split as waybar's colors.css.
      home.activation.wofiStyle = lib.hm.dag.entryAfter ["writeBoundary"] ''
                _dir="$HOME/.config/wofi"
                mkdir -p "$_dir"
                cat > "$_dir/style.css" <<'WOFI_STYLE_EOF'
        ${wofiStyleContent}
        WOFI_STYLE_EOF
                [ -f "$_dir/colors.css" ] || cat > "$_dir/colors.css" <<'WOFI_COLORS_EOF'
        ${defaultWofiColorsCss}
        WOFI_COLORS_EOF
      '';
    };
  };
}
