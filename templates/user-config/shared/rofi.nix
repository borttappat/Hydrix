# Rofi Application Launcher — User Configuration
#
# host-rofi builds a full theme at runtime from xrdb colors + scaling.json,
# so color and size settings below are overridden by the dynamic theme.
# These static settings still apply for direct `rofi` invocations and
# home-manager-managed options (terminal, keybindings, extra config).
#
# Framework sets: enable, package, terminal (alacritty), stylix disabled.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {

  # -------------------------------------------------------------------------
  # Rofi window dimensions (used by host-rofi at runtime)
  # -------------------------------------------------------------------------
  # hydrix.graphical.ui.rofiWidth  = lib.mkDefault 500;  # pixels
  # hydrix.graphical.ui.rofiHeight = lib.mkDefault 400;  # pixels

  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      programs.rofi = {

        # Terminal launched for terminal entries (default: alacritty)
        # terminal = lib.mkDefault "${pkgs.alacritty}/bin/alacritty";

        # Static rofi configuration. Colors and fonts come from the runtime
        # theme; set behaviour-only options here.
        extraConfig = {
          # Display modes shown in mode switcher (if enabled)
          # modi = "drun,run,window,ssh";
          # display-drun   = "Apps";
          # display-run    = "Run";
          # display-window = "Windows";

          # Icons
          show-icons   = false;
          # icon-theme = "Papirus";

          # History / matching
          disable-history = false;
          sort = false;
          matching = "fuzzy";
          tokenize = true;

          # Behaviour
          click-to-exit = true;
          hover-select = true;
          me-select-entry = "";
          me-accept-entry = "MousePrimary";

          # Keyboard
          kb-cancel       = "Escape,q";
          kb-accept-entry = "Return,KP_Enter";
          kb-row-up       = "Up,Control+k";
          kb-row-down     = "Down,Control+j";
          kb-page-prev    = "Page_Up";
          kb-page-next    = "Page_Down";

          # Sidebar mode (false = no mode switcher strip)
          sidebar-mode = false;
        };

      };
    };
  };
}
