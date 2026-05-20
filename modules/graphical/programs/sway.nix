# Sway Home Manager Configuration
#
# Mirrors the i3 setup as closely as possible for drop-in parity.
# Keybindings live in hydrix-config/shared/sway.nix (same pattern as shared/i3.nix).
# Colors come from wal/Xresources via set_from_resource (same as i3).
# waypipe VM windows are routed to workspaces by title prefix.
#
# Workspace → VM mapping is driven by vm-registry at build time (no hardcoded list).
# WS 1 is always the host. Remaining workspaces come from vmRegistry entries
# that have hasDisplay=true and a non-null workspace number.
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  username = config.hydrix.username;
  cfg = config.hydrix.graphical;
  sc = config.hydrix.graphical.scaling.computed;
  bottomBar = config.hydrix.graphical.ui.bottomBar or false;
  xkbLayout = config.services.xserver.xkb.layout or "us";
  mod = "Mod4";
  vmType = config.hydrix.vmType or null;
  isVM = vmType != null && vmType != "host";
  polybarPkg = pkgs.polybar.override { i3Support = true; pulseSupport = true; };
  # waypipe window routing rules — generated from vmRegistry at build time.
  # The registry key is the profile/task name (e.g. "browsing", "pentest-task1").
  # waypipe-connect sets --title-prefix "[<key>] " so windows route to the right workspace.
  # Only display VMs with a declared workspace number are included.
  vmWindowRoutes = let
    registry = config.hydrix.networking.vmRegistry;
    displayVMs = lib.filterAttrs (_: v: (v.hasDisplay or true) && v.workspace != null) registry;
  in lib.concatStringsSep "\n          "
    (lib.mapAttrsToList (key: v:
      ''for_window [title="^\[${key}\] "] move to workspace ${toString v.workspace}''
    ) displayVMs);

  # Brightness control — Wayland/sway version.
  # Internal (eDP-*): brightnessctl (hardware backlight).
  # External: ddcutil (DDC/CI hardware brightness over i2c).
  #   Requires hardware.i2c.enable = true and user in the i2c group (set in packages.nix).
  #   ddcutil display number is matched by DRM connector name so multi-monitor works.
  hydrix-brightness-sway = pkgs.writeShellScriptBin "hydrix-brightness-sway" ''
    STEP=10

    MONITOR=$(${pkgs.sway}/bin/swaymsg -t get_outputs \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | .name')

    if [ -z "$MONITOR" ]; then exit 1; fi

    if [[ "$MONITOR" == eDP-* ]]; then
      case "$1" in
        +) ${pkgs.brightnessctl}/bin/brightnessctl set +''${STEP}% ;;
        -) ${pkgs.brightnessctl}/bin/brightnessctl set ''${STEP}%- ;;
        *) exit 1 ;;
      esac
    else
      # Match ddcutil display number by DRM connector name (e.g. DP-1, HDMI-A-1)
      DDC_DISP=$(${pkgs.ddcutil}/bin/ddcutil detect --terse 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -v out="$MONITOR" '
            /^Display/ { disp = $2 }
            /DRM connector/ { if (index($0, out) > 0) { print disp; exit } }
          ')
      : "''${DDC_DISP:=1}"

      CURRENT=$(${pkgs.ddcutil}/bin/ddcutil --display "$DDC_DISP" getvcp 10 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F'current value *= *' 'NF>1 { split($2,a,","); print a[1]+0; exit }')
      : "''${CURRENT:=50}"

      case "$1" in
        +) NEW=$(( CURRENT + STEP )) ;;
        -) NEW=$(( CURRENT - STEP )) ;;
        *) exit 1 ;;
      esac
      [ "$NEW" -lt 1  ] && NEW=1
      [ "$NEW" -gt 100 ] && NEW=100

      ${pkgs.ddcutil}/bin/ddcutil --display "$DDC_DISP" setvcp 10 "$NEW"
    fi
  '';

  # Vibrancy control — Wayland/sway version.
  # Uses ddcutil VCP code 0x8A (Color Saturation) — hardware DDC/CI equivalent of vibrant-cli.
  # Only works on external monitors; eDP does not expose DDC saturation.
  # Requires hardware.i2c.enable = true and user in the i2c group (set in packages.nix).
  hydrix-vibrancy-sway = pkgs.writeShellScriptBin "hydrix-vibrancy-sway" ''
    STEP=5

    MONITOR=$(${pkgs.sway}/bin/swaymsg -t get_outputs \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | .name')

    if [ -z "$MONITOR" ]; then exit 1; fi

    if [[ "$MONITOR" == eDP-* ]]; then
      ${pkgs.libnotify}/bin/notify-send "hydrix-vibrancy" \
        "Vibrancy not available on internal display (no DDC)" --urgency=low
      exit 0
    fi

    DDC_DISP=$(${pkgs.ddcutil}/bin/ddcutil detect --terse 2>/dev/null \
      | ${pkgs.gawk}/bin/awk -v out="$MONITOR" '
          /^Display/ { disp = $2 }
          /DRM connector/ { if (index($0, out) > 0) { print disp; exit } }
        ')
    : "''${DDC_DISP:=1}"

    CURRENT=$(${pkgs.ddcutil}/bin/ddcutil --display "$DDC_DISP" getvcp 0x8A 2>/dev/null \
      | ${pkgs.gawk}/bin/awk -F'current value *= *' 'NF>1 { split($2,a,","); print a[1]+0; exit }')
    : "''${CURRENT:=50}"

    case "$1" in
      +) NEW=$(( CURRENT + STEP )) ;;
      -) NEW=$(( CURRENT - STEP )) ;;
      *) exit 1 ;;
    esac
    [ "$NEW" -lt 0   ] && NEW=0
    [ "$NEW" -gt 100 ] && NEW=100

    ${pkgs.ddcutil}/bin/ddcutil --display "$DDC_DISP" setvcp 0x8A "$NEW"
  '';

  # sway-apply-colors: reads wal color cache and writes ~/.config/sway/colors.conf,
  # then reloads sway so client.focused/unfocused pick up the new values.
  # Called on startup and by refresh-colors when WAYLAND_DISPLAY is set.
  swayApplyColors = pkgs.writeShellScriptBin "sway-apply-colors" ''
    WAL="$HOME/.cache/wal/colors.sh"
    OUT="$HOME/.config/sway/colors.conf"
    mkdir -p "$(dirname "$OUT")"

    if [ -f "$WAL" ]; then
      . "$WAL"
    else
      # Fallback palette when wal hasn't run yet
      color0="#101116"; color1="#bf616a"
      color3="#e0af68"; color4="#7aa2f7"
      color7="#c0caf5"; color8="#414868"
    fi

    # Write client color directives (border background text indicator child_border)
    # Unfocused borders == background so they appear invisible (same as i3)
    cat > "$OUT" << EOF
    client.focused          $color4 $color0 $color7 $color4 $color4
    client.focused_inactive $color0 $color0 $color8 $color0 $color0
    client.unfocused        $color0 $color0 $color8 $color0 $color0
    client.urgent           $color1 $color1 $color7 $color1 $color1
    EOF

    # Reload sway to pick up the new colors.conf include
    ${pkgs.sway}/bin/swaymsg reload 2>/dev/null || true
  '';
in
  lib.mkIf (cfg.enable && config.hydrix.sway.enable) {
    # Make sway scripts and display control tools available system-wide
    environment.systemPackages = [
      swayApplyColors
      hydrix-brightness-sway
      hydrix-vibrancy-sway
      pkgs.brightnessctl
    ];

    home-manager.users.${username} = {
      pkgs,
      ...
    }: {
      wayland.windowManager.sway = {
        enable = true;

        # Raw config appended after the generated block.
        # Colors: set_from_resource reads from xrdb (same as i3; xrdb is loaded by startup).
        # waypipe routing: windows with "[profile] " title prefix go to the right workspace.
        # sway does not support set_from_resource (Wayland-native, no Xresources).
        # Colors are applied at runtime by the sway-apply-colors startup script,
        # which reads ~/.cache/wal/colors.sh and writes ~/.config/sway/colors.conf,
        # then triggers a swaymsg reload. The include below picks it up.
        # checkConfig = false required because the include path is user-home-relative.
        checkConfig = false;

        extraConfig = lib.mkAfter ''
          # Runtime colors — generated from wal by sway-apply-colors on startup.
          # File: ~/.config/sway/colors.conf (client.focused/unfocused/urgent lines)
          include ~/.config/sway/colors.conf

          # waypipe VM window routing — generated from vm-registry at build time
          ${vmWindowRoutes}

          # No title bars — pixel borders only (same as i3 default)
          default_border pixel 2
          default_floating_border pixel 2

          # Drag tiled windows with modifier (same feel as i3 floating drag)
          tiling_drag modifier
        '';

        config = {
          modifier = mod;
          terminal = config.hydrix.terminal;
          menu = "wofi-launcher";

          # ── Input ────────────────────────────────────────────────────────────
          input = {
            "type:keyboard" = {xkb_layout = xkbLayout;};
            "type:touchpad" = {
              natural_scroll = "enabled";
              tap = "enabled";
            };
          };

          # ── Output ──────────────────────────────────────────────────────────
          # Internal display: scale or mode override (external monitors unaffected).
          # `*` is set first so a more specific internal rule overrides it.
          output = {"*".scale = "1";} //
            lib.optionalAttrs (cfg.scaling.swayInternalScale != null) {
              "${cfg.scaling.swayInternalOutput}".scale =
                toString cfg.scaling.swayInternalScale;
            } //
            lib.optionalAttrs
              (cfg.scaling.swayInternalScale == null && cfg.scaling.swayInternalMode != null) {
              "${cfg.scaling.swayInternalOutput}".mode =
                cfg.scaling.swayInternalMode;
            };

          # ── Gaps & Borders ──────────────────────────────────────────────────
          # Mirrors i3: inner gap from ui.gaps, outer matches bar gap at runtime.
          # display-setup adjusts gaps at login to match scaling.json (same as i3).
          gaps = {
            inner  = lib.mkDefault sc.gaps;
            outer  = lib.mkDefault sc.outerGaps;
            top    = lib.mkDefault (sc.barGaps + sc.barHeight);
            bottom = lib.mkDefault (if bottomBar then (sc.barGaps + sc.barHeight) else 0);
          };
          window.border   = lib.mkDefault sc.border;
          floating.border = lib.mkDefault sc.border;

          # ── Focus ────────────────────────────────────────────────────────────
          focus.followMouse = false;
          focus.newWindow   = "smart";

          # ── Resize mode (same hjkl layout as i3) ─────────────────────────────
          modes.resize = {
            "h"      = "resize shrink width 15 px or 15 ppt";
            "j"      = "resize grow height 15 px or 15 ppt";
            "k"      = "resize shrink height 15 px or 15 ppt";
            "l"      = "resize grow width 15 px or 15 ppt";
            "Left"   = "resize shrink width 2 px or 2 ppt";
            "Up"     = "resize grow height 2 px or 2 ppt";
            "Down"   = "resize shrink height 2 px or 2 ppt";
            "Right"  = "resize grow width 2 px or 2 ppt";
            "Return" = "mode default";
            "Escape" = "mode default";
            "${mod}+r" = "mode default";
          };

          # ── Startup ─────────────────────────────────────────────────────────
          # Mirror i3 startup: restore pywal colors then launch services.
          # display-setup --no-move handles polybar launch (same as i3).
          startup = [
            # Restore wal colors: generate ~/.config/sway/colors.conf + reload sway
            { command = "wal -Rnq"; }
            { command = "${swayApplyColors}/bin/sway-apply-colors"; }
            # Restore wallpaper from wal cache (feh doesn't work in Wayland)
            { command = "sh -c '[ -f ~/.cache/wal/wal ] && ${pkgs.swaybg}/bin/swaybg -i \"$(cat ~/.cache/wal/wal)\" -m fill &'"; }
            # Export sway socket to systemd user env — required for services that use
            # sway IPC (sway-focus-daemon) and for polybar's internal/i3 module.
            # Must run before restarting sway-focus-daemon.
            { command = "systemctl --user set-environment SWAYSOCK=$SWAYSOCK WAYLAND_DISPLAY=$WAYLAND_DISPLAY"; }
            # Focus daemon: dynamic border colors per VM (reads [profile] title prefix)
            { command = "systemctl --user restart sway-focus-daemon"; }
            # Services
            { command = "${pkgs.dunst}/bin/dunst"; }
            # Bars + scaling: delay 3s for monitors to initialize before launching polybar.
            # I3SOCK=$SWAYSOCK: polybar's internal/i3 workspace module + i3-msg scripts
            # use $I3SOCK to find the WM socket; Sway exposes it as $SWAYSOCK.
            { command = "sleep 3 && I3SOCK=$SWAYSOCK display-setup --no-move"; }
            # Auto-connect waypipe for any profile VMs that are already running.
            # Polls each VM with PING until it responds OK, then connects immediately.
            { command = "waypipe-connect-all"; }
          ];

          # ── Keybindings ──────────────────────────────────────────────────────
          # Defined in hydrix-config/shared/sway.nix via lib.mkOptionDefault
          keybindings = lib.mkOptionDefault {};

          # ── Floating window rules ────────────────────────────────────────────
          # i3 uses instance= (X11 class); sway uses app_id (Wayland).
          # alacritty --class floating sets app_id to "floating".
          floating.criteria = [
            {app_id = "floating";}
            {app_id = "floating-term";}
            {app_id = "pavucontrol";}
            {app_id = "lxappearance";}
          ];

          # Window commands for floating size and opacity
          # Opacity: apply active opacity to all windows (Wayland-native via app_id, XWayland via class),
          # then restore full opacity for excluded apps.
          # Sway opacity is set once on window open (no active/inactive distinction).
          window.commands = [
            { criteria = {app_id = "floating";}; command = "resize set 800 450"; }
          ] ++ lib.optionals (cfg.ui.opacity.active < 1.0) (
            [
              { criteria = {app_id = ".*";}; command = "opacity ${toString cfg.ui.opacity.active}"; }
              { criteria = {class = ".*";}; command = "opacity ${toString cfg.ui.opacity.active}"; }
            ]
            ++ lib.concatMap (name: [
              { criteria = {app_id = name;}; command = "opacity 1"; }
              { criteria = {class = name;}; command = "opacity 1"; }
            ]) cfg.ui.opacity.exclude
          );

          # ── Bar ──────────────────────────────────────────────────────────────
          # Bars are launched by display-setup (polybar, same as i3); suppress sway's built-in bar.
          bars = [];
        };
      };
    };
  }
