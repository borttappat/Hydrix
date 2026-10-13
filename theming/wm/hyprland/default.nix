# Hyprland Window Manager Module
#
# NixOS-level Hyprland setup: enables compositor, portals, packages.
# Gated on hydrix.hyprland.enable.
#
# Hyprland config (keybindings, rules, aesthetics) lives in:
#   modules/wm/hyprland/hyprland.nix
# Wofi launcher lives in:
#   modules/wm/hyprland/wofi.nix
#
# Use `hyprland-launch` to start Hyprland: it supervises Hyprland (restart after a
# crash, fallback config, see hyprlandSupervise) with stdout/stderr piped to the
# journal instead of the controlling TTY. Login managers (greetd, SDDM) exec a raw
# binary via argv with no shell, so there's no way to redirect output at the Exec=
# level; without this, Hyprland's startup log briefly flashes on the VT before the
# compositor takes over the display.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;

  kb = cfg.keyboard;
  term = config.hydrix.terminal;

  # Minimal session used when the real config is missing or keeps crashing Hyprland: a
  # terminal, a launcher and window management, nothing that could be the crash cause (no
  # plugins, no VM integration). waypipe-connect refuses VMs here, as hypr-clip-guard is absent.
  fallbackConf = pkgs.writeText "hyprland-fallback.conf" ''
    ${lib.optionalString ((cfg.scaling.hyprInternalScale or null) != null)
      "monitor = ${cfg.scaling.hyprInternalOutput or "eDP-1"}, preferred, 0x0, ${toString cfg.scaling.hyprInternalScale}"}
    monitor = , preferred, auto, 1

    input {
      kb_layout  = ${kb.layout}
      kb_variant = ${kb.variant}
      kb_options = ${kb.xkbOptions}
    }

    misc {
      disable_hyprland_logo    = true
      disable_splash_rendering = true
      background_color         = 0xff000000
      disable_watchdog_warning = true
    }

    exec-once = hyprctl seterror "rgba(ff5555ff)" "Hydrix fallback session: the regular Hyprland config is missing or crashed Hyprland. No VM windows here. SUPER+Return terminal, SUPER+D launcher, SUPER+CTRL+SHIFT+E exit (log in again for the regular session). Log: journalctl -t hyprland"

    bind = SUPER, Return, exec, ${term}
    bind = SUPER, D, exec, wofi --show drun
    bind = SUPER, Q, killactive,
    bind = SUPER, F, fullscreen, 0
    bind = SUPER SHIFT, space, togglefloating,
    bind = SUPER CTRL SHIFT, E, exit,
    ${lib.concatMapStrings (d: ''
        bind = SUPER, ${d.k}, movefocus, ${d.d}
        bind = SUPER, ${d.a}, movefocus, ${d.d}
        bind = SUPER SHIFT, ${d.k}, movewindow, ${d.d}
        bind = SUPER SHIFT, ${d.a}, movewindow, ${d.d}
      '') [
        {k = "h"; a = "left"; d = "l";}
        {k = "j"; a = "down"; d = "d";}
        {k = "k"; a = "up"; d = "u";}
        {k = "l"; a = "right"; d = "r";}
      ]}
    ${lib.concatMapStrings (n: ''
      bind = SUPER, ${toString n}, workspace, ${toString n}
      bind = SUPER SHIFT, ${toString n}, movetoworkspace, ${toString n}
    '') (lib.range 1 9)}
    bindm = SUPER, mouse:272, movewindow
    bindm = SUPER, mouse:273, resizewindow
  '';

  # Supervises Hyprland in place of start-hyprland, whose watchdog restarts a crashed
  # Hyprland in safe mode: upstream's example config (kitty on SUPER+Q) until "Load config"
  # is clicked. Here a crash restarts the regular config; two crashes within a minute of
  # starting switch to fallbackConf; two quick crashes of that end the session. A missing
  # config starts fallbackConf too, where Hyprland would generate its example config.
  # Exit status 0 (exit dispatcher) and SIGTERM/SIGHUP (logout) end the session as usual.
  hyprlandSupervise = pkgs.writeShellScript "hyprland-supervise" ''
    cfgdir="''${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
    mode=regular
    [ -e "$cfgdir/hyprland.conf" ] || [ -e "$cfgdir/hyprland.lua" ] || mode=fallback
    stopping=0
    trap 'stopping=1' TERM HUP INT
    quick=0
    while :; do
      started=$(${pkgs.coreutils}/bin/date +%s)
      echo "hyprland-launch: starting Hyprland ($mode config)"
      if [ "$mode" = fallback ]; then
        Hyprland --config ${fallbackConf} "$@"
      else
        Hyprland "$@"
      fi
      rc=$?
      case "$rc" in 0|129|130|143) exit "$rc" ;; esac
      [ "$stopping" = 1 ] && exit "$rc"
      echo "hyprland-launch: Hyprland exited with status $rc ($mode config)"
      [ $(( $(${pkgs.coreutils}/bin/date +%s) - started )) -ge 60 ] && quick=0
      quick=$((quick + 1))
      if [ "$quick" -ge 2 ]; then
        if [ "$mode" = fallback ]; then
          echo "hyprland-launch: the fallback config crashed twice, giving up"
          exit "$rc"
        fi
        mode=fallback
        quick=0
      fi
    done
  '';

  hyprlandLaunch = pkgs.writeShellScriptBin "hyprland-launch" ''
    exec ${pkgs.systemd}/bin/systemd-cat -t hyprland ${hyprlandSupervise} "$@"
  '';

in {
  imports = [ ./hyprland.nix ./wofi.nix ./waypipe.nix ];

  config = lib.mkIf (cfg.enable && config.hydrix.hyprland.enable) {
    # hydrix.hyprland.fromUnstable: compositor, plugins and portal from one nixpkgs, so
    # plugin headers always match the running Hyprland.
    nixpkgs.overlays = lib.mkIf config.hydrix.hyprland.fromUnstable [
      (final: prev: {
        inherit (final.unstable) hyprland hyprlandPlugins xdg-desktop-portal-hyprland;
      })
    ];

    programs.hyprland = {
      enable = true;
      # Always the XWayland-capable build: it is the one in the binary cache,
      # and turning this off makes NixOS rebuild Hyprland from source. With
      # hydrix.hyprland.xwayland.enable off, XWayland is disabled at runtime
      # instead (`xwayland { enabled = false }` in hydrix-generated.conf).
      xwayland.enable = lib.mkDefault true;
    };

    # XDG portal for screen sharing, file pickers, etc.
    # xdg-desktop-portal-hyprland is intentionally NOT listed here —
    # home-manager's wayland.windowManager.hyprland (systemd.enable = true)
    # activates it via systemd.user.packages. Listing it in extraPortals too
    # causes a duplicate xdg-desktop-portal-hyprland.service symlink → build failure.
    xdg.portal = {
      enable = lib.mkDefault true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.hyprland.default = [ "hyprland" "gtk" ];
    };

    # Required by home-manager's xdg.portal with useUserPackages enabled
    environment.pathsToLink = [ "/share/applications" "/share/xdg-desktop-portal" ];

    environment.systemPackages = with pkgs; [
      hyprlandLaunch     # Session entry point: supervised Hyprland, log to the journal
      hyprlock           # Screen locker
      hyprpicker         # Color picker (Wayland-native)
      wl-clipboard       # wl-copy / wl-paste
      wlr-randr          # xrandr equivalent for wlroots
      grim               # Screenshot
      slurp              # Region select (for grim)
      libnotify          # notify-send (daemon: swaync, theming/programs/swaync.nix)
      waybar             # Status bar
      wofi               # Launcher (replaces rofi)

      # Waypipe + socat for VM app forwarding
      waypipe
      socat
    ];

    # Polkit agent (needed by Hyprland for auth dialogs)
    security.polkit.enable = true;

    # PAM for hyprlock authentication
    security.pam.services.hyprlock.enable = lib.mkDefault true;

  };
}
