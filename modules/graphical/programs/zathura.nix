# Zathura PDF Viewer Configuration
#
# Home Manager module for Zathura.
# Colors are automatically applied by Stylix.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;

  # Scaling values
  sc = config.hydrix.graphical.scaling.computed;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      programs.zathura = {
        enable = true;

        options = {
          # Colors handled by Stylix

          # Document recoloring behavior
          recolor = true;
          recolor-reverse-video = true;
          recolor-keephue = false;

          # UI Settings (scaled)
          statusbar-h-padding = sc.padding;
          statusbar-v-padding = sc.padding;
          page-padding = sc.border;
          selection-clipboard = "clipboard";

          # Behavior
          scroll-page-aware = true;
          scroll-full-overlap = 0.01;
          scroll-step = 100;
          zoom-min = 10;
          zoom-max = 400;
          zoom-step = 10;

          # Search
          incremental-search = true;

          # Sandbox (disable for better compatibility)
          sandbox = "none";
        };

        mappings = {
          # Vim-like navigation
          D = "toggle_page_mode";
          r = "reload";
          R = "rotate";
          K = "zoom in";
          J = "zoom out";
          i = "recolor";
          p = "print";
        };
      };
    };
  };
}
