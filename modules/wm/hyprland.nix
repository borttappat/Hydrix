# Hyprland Window Manager Module
#
# NixOS-level Hyprland setup: enables compositor, portals, packages.
# Gated on hydrix.hyprland.enable.
#
# Hyprland config (keybindings, rules, aesthetics) lives in:
#   modules/graphical/programs/hyprland.nix
#
# Use `hyprland-session` instead of `Hyprland` to start Hyprland — it cleans
# up WAYLAND_DISPLAY from the systemd user environment on exit, allowing
# picom to restart correctly when returning to i3/X11.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;

  hyprlandSession = pkgs.writeShellScriptBin "hyprland-session" ''
    # Mask sway-polybar-hotplug.path for this session so polybar never auto-starts
    # under Hyprland (including during nixos-rebuild switch daemon-reloads).
    # --runtime means the mask lives only in /run — removed automatically on session end.
    systemctl --user mask --runtime display-hotplug.path 2>/dev/null || true

    Hyprland "$@"
    EXIT=$?

    # Remove Wayland env vars from the persistent systemd user environment.
    # Without this, picom refuses to start (ConditionEnvironment=!WAYLAND_DISPLAY).
    systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY 2>/dev/null || true
    # Restart picom so i3 gets compositing back immediately.
    systemctl --user restart picom 2>/dev/null || true

    # Unmask polybar hotplug so it works again if user switches back to Sway.
    systemctl --user unmask --runtime display-hotplug.path 2>/dev/null || true

    exit $EXIT
  '';

in {
  config = lib.mkIf (cfg.enable && config.hydrix.hyprland.enable) {
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;   # needed for XWayland apps (electron, etc.)
    };

    # XDG portal for screen sharing, file pickers, etc.
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
      config.hyprland.default = [ "hyprland" "gtk" ];
    };

    # Required by home-manager's xdg.portal with useUserPackages enabled
    environment.pathsToLink = [ "/share/applications" "/share/xdg-desktop-portal" ];

    environment.systemPackages = with pkgs; [
      hyprlandSession    # Use this instead of bare `Hyprland` — cleans up on exit
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
    security.pam.services.hyprlock.enable = true;

  };
}
