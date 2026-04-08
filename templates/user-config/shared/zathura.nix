# Zathura PDF Viewer — User Configuration
#
# Colors are applied by Stylix. Scaled padding values (statusbar, page) are
# set by the framework using scaling.json values at build time.
# Override any setting here with lib.mkForce.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      programs.zathura = {

        options = {
          # -------------------------------------------------------------------
          # Document recoloring
          # Default: recolor = true (dark mode), keep-hue = false.
          # -------------------------------------------------------------------
          # recolor               = lib.mkDefault true;
          # recolor-reverse-video = lib.mkDefault true;
          # recolor-keephue       = lib.mkDefault false;

          # -------------------------------------------------------------------
          # Clipboard
          # Default: clipboard — middle-click pastes selection.
          # -------------------------------------------------------------------
          # selection-clipboard = lib.mkDefault "clipboard";

          # -------------------------------------------------------------------
          # Scroll behaviour
          # -------------------------------------------------------------------
          # scroll-page-aware  = lib.mkDefault true;
          # scroll-full-overlap = lib.mkDefault 0.01;
          # scroll-step        = lib.mkDefault 100;

          # -------------------------------------------------------------------
          # Zoom
          # -------------------------------------------------------------------
          # zoom-min  = lib.mkDefault 10;
          # zoom-max  = lib.mkDefault 400;
          # zoom-step = lib.mkDefault 10;

          # -------------------------------------------------------------------
          # Search
          # -------------------------------------------------------------------
          # incremental-search = lib.mkDefault true;

          # -------------------------------------------------------------------
          # Sandbox (none = best app compatibility)
          # -------------------------------------------------------------------
          # sandbox = lib.mkDefault "none";

          # -------------------------------------------------------------------
          # Initial view
          # -------------------------------------------------------------------
          # pages-per-row        = lib.mkDefault 1;
          # first-page-column    = lib.mkDefault "1:2";
          # adjust-open          = lib.mkDefault "best-fit";

          # -------------------------------------------------------------------
          # Render
          # -------------------------------------------------------------------
          # render-loading       = lib.mkDefault true;
          # font                 = lib.mkDefault "monospace normal 9";
        };

        # -------------------------------------------------------------------
        # Key mappings (merge with framework vim-like bindings)
        # Framework provides: D=toggle_page_mode, r=reload, R=rotate,
        # K=zoom in, J=zoom out, i=recolor, p=print.
        # -------------------------------------------------------------------
        # mappings = {
        #   "+" = "zoom in";
        #   "-" = "zoom out";
        #   f   = "toggle_fullscreen";
        # };

      };
    };
  };
}
