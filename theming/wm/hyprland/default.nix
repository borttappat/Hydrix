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
# Use `hyprland-launch` to start Hyprland — it runs Hyprland's own
# `start-hyprland` watchdog (crash-detect + restart supervision) with stdout/
# stderr piped to the journal instead of the controlling TTY. Login managers
# (greetd, SDDM) exec a raw binary via argv with no shell, so there's no way
# to redirect output at the Exec= level — without this, Hyprland's startup
# log (incl. its "Welcome to Hyprland!" banner) briefly flashes on the VT
# before the compositor takes over the display.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;

  hyprlandLaunch = pkgs.writeShellScriptBin "hyprland-launch" ''
    exec ${pkgs.systemd}/bin/systemd-cat -t hyprland start-hyprland -- "$@"
  '';

in {
  imports = [ ./hyprland.nix ./wofi.nix ];

  config = lib.mkIf (cfg.enable && config.hydrix.hyprland.enable) {
    programs.hyprland = {
      enable = true;
      xwayland.enable = lib.mkDefault config.hydrix.hyprland.xwayland.enable;
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
      hyprlandLaunch     # Use this instead of bare start-hyprland — silences TTY log spam
      hyprlock           # Screen locker
      hyprpicker         # Color picker (Wayland-native)
      wl-clipboard       # wl-copy / wl-paste
      wlr-randr          # xrandr equivalent for wlroots
      grim               # Screenshot
      slurp              # Region select (for grim)
      dunst              # Notifications (Wayland-native since v1.7)
      libnotify
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

    # Dynamic focus border colors: use wal palette per VM type.
    # User can override in machines/<serial>.nix with a plain assignment.
    hydrix.vmThemeSync.focusDaemon.mode = lib.mkDefault "dynamic";

  };
}
