# Hyprland Window Manager Module
#
# NixOS-level Hyprland setup: enables compositor, portals, packages.
# Gated on hydrix.hyprland.enable.
#
# Hyprland config (keybindings, rules, aesthetics) lives in:
#   modules/graphical/programs/hyprland.nix
#
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix.graphical;
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

    environment.systemPackages = with pkgs; [
      hyprland
      hyprpicker         # Color picker (Wayland-native)
      wl-clipboard       # wl-copy / wl-paste
      wlr-randr          # xrandr equivalent for wlroots
      grim               # Screenshot
      slurp              # Region select (for grim)
      dunst              # Notifications (Wayland-native since v1.7)
      libnotify

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
