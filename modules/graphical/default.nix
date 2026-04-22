# Graphical Environment Module
#
# Complete graphical environment for Hydrix:
# - i3 window manager with gaps
# - Stylix for automatic theming
# - Dynamic DPI scaling and hardware normalization
# - Polybar, Rofi, Dunst, Picom, Alacritty
#
# All configuration through hydrix.graphical.* options (see options.nix)
#
# Usage:
#   hydrix.graphical.enable = true;
#   hydrix.graphical.font.family = "Iosevka";
#   hydrix.graphical.font.size = 10;
#   hydrix.graphical.ui.gaps = 8;
#
# To disable (e.g., for Wayland):
#   hydrix.graphical.enable = false;

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.graphical;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType or null;
  isHost = vmType == "host";
in {
  imports = [
    # Options are in modules/options.nix (single source of truth)
    ./packages.nix         # WM, X11, theming packages
    ./scaling.nix          # Compatibility layer for scaling.computed.*
    ./dynamic-scaling.nix  # Hardware DPI detection + scaling
    ./stylix.nix           # Stylix theming
    ./display-setup.nix    # Polybar runtime config
    ./xsession.nix         # X session startup
    ./home.nix             # Home Manager programs
    ./scripts.nix          # Colorscheme management scripts
    ./programs/blugon.nix       # Blue light filter
    ./programs/file-finder.nix  # Fuzzy file search (file-finder command)
    ./fonts                     # Per-font profiles (sizes, overrides, UI adjustments)
    ../wm/focus-mode.nix   # Focus mode (lock keybindings to single VM type)
  ];

  config = lib.mkMerge [
    # Host defaults
    (lib.mkIf isHost {
      hydrix.graphical = {
        enable = lib.mkDefault true;
        scaling.auto = lib.mkDefault true;
      };
    })

    # When graphical is enabled
    (lib.mkIf cfg.enable {
      stylix.enable = true;
      home-manager.backupFileExtension = "hm-backup";

      # Required when any home-manager module enables xdg.portal (e.g. Hyprland)
      environment.pathsToLink = [ "/share/applications" "/share/xdg-desktop-portal" ];

      # PAM service for i3lock-color authentication
      security.pam.services.i3lock.enable = true;

      # Clean up old Home Manager backups before HM activation runs
      systemd.services.hm-backup-cleanup = {
        description = "Clean up old Home Manager backup files";
        before = [ "home-manager-${username}.service" ];
        wantedBy = [ "home-manager-${username}.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = username;
          ExecStart = "${pkgs.findutils}/bin/find /home/${username} -name '*.hm-backup' -type f -delete";
        };
      };
    })
  ];
}
