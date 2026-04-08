# Alacritty Terminal — User Customizations
#
# The framework (alacritty.nix) handles:
#   - Font size (DPI-scaled, don't override)
#   - Window opacity (from hydrix.graphical.ui.opacity.* — change there, not here)
#   - Color import via colors-runtime.toml (wal/pywal, don't override)
#   - VM color inheritance (host bg + VM text colors)
#   - Keyboard bindings (copy/paste/font size keys)
#   - Cursor style (underline, blinking)
#   - Selection copy-to-clipboard
#
# To override framework settings use lib.mkForce.
# Opacity is best changed via hydrix.graphical.ui.opacity.overlay in graphical.nix.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      programs.alacritty.settings = {

        # -------------------------------------------------------------------
        # Cursor (framework default: Underline, Always blinking)
        # -------------------------------------------------------------------
        # cursor = {
        #   style = {
        #     shape    = lib.mkForce "Block";   # Block | Underline | Beam
        #     blinking = lib.mkForce "Always";  # Never | Off | On | Always
        #   };
        #   blink_interval = lib.mkForce 500;
        #   blink_timeout  = lib.mkForce 0;     # 0 = never stop
        #   thickness      = lib.mkForce 0.15;
        # };

        # -------------------------------------------------------------------
        # Window (framework default: dynamic_padding = true)
        # -------------------------------------------------------------------
        # window = {
        #   padding = lib.mkForce { x = 4; y = 4; };
        #   dynamic_padding = lib.mkForce false;
        # };

        # -------------------------------------------------------------------
        # Additional keyboard bindings
        # Framework provides: Copy, Paste, PasteSelection, font-size keys.
        # Add new entries here — they merge with the framework list.
        # -------------------------------------------------------------------
        # keyboard.bindings = [
        #   { action = "ScrollPageUp";   key = "PageUp";   mods = "Shift"; }
        #   { action = "ScrollPageDown"; key = "PageDown"; mods = "Shift"; }
        # ];

      };
    };
  };
}
