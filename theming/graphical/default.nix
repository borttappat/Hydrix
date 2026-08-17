# Graphical Environment Module
#
# Complete graphical environment for Hydrix:
# - Hyprland window manager with gaps
# - Native wal/pywal-driven theming (fonts, console colors, GTK/zathura/alacritty/
#   firefox/dunst/waybar colors); Stylix is available as an opt-in (see stylix.nix)
#   for users who supply the `stylix` flake input and want broader auto-theming
# - Dynamic DPI scaling and hardware normalization
# - Waybar, Wofi, Dunst, Alacritty
#
# All configuration through hydrix.graphical.* options (see options.nix)
#
# Usage:
#   hydrix.graphical.enable = true;
#   hydrix.graphical.font.family = "Iosevka";
#   hydrix.graphical.font.size = 10;
#   hydrix.graphical.ui.gaps = 8;

{ config, lib, pkgs, hasStylix ? false, ... }:

let
  cfg = config.hydrix.graphical;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType or null;
  isHost = vmType == "host";
in {
  imports = [
    # Options are in theming/options.nix
    ./packages.nix         # WM, X11, theming packages
    ./scaling.nix          # Compatibility layer for scaling.computed.*
    ./native-theme.nix     # Fonts, console colors (always on, no Stylix needed)
    ./home.nix             # Home Manager programs
    ./scripts.nix          # Colorscheme management scripts
    ../fonts                     # Per-font profiles (sizes, overrides, UI adjustments)
    ../wm/focus-mode.nix   # Focus mode (lock keybindings to single VM type)
    # NixOS-level WM modules: system packages, portals, PAM, session scripts.
    # Gated on hydrix.hyprland.enable inside each file.
    ../wm/hyprland
  ] ++ lib.optional hasStylix ./stylix.nix;  # Opt-in: only if the consuming flake supplies the `stylix` input

  config = lib.mkMerge [
    # Host defaults. graphical.enable is NOT force-defaulted true here (it's a plain
    # `mkEnableOption`, false by default) so a plumbing-only host stays desktop-free
    # with zero opt-out needed -- setup-hydrix/install-hydrix's generated machine
    # configs explicitly set hydrix.graphical.enable = true alongside hyprland.enable.
    (lib.mkIf isHost {
      hydrix.graphical = {
        scaling.auto = lib.mkDefault true;
      };
    })

    # When graphical is enabled
    (lib.mkIf cfg.enable {
      home-manager.backupFileExtension = "hm-backup";

      # Required when any home-manager module enables xdg.portal (e.g. Hyprland)
      environment.pathsToLink = [ "/share/applications" "/share/xdg-desktop-portal" ];

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
