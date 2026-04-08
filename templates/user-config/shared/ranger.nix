# Ranger File Manager — User Customizations
#
# The framework (ranger.nix) provides: settings, navigation mappings (gh/gd/etc.),
# and rifle rules for common file types. Add your own overrides below.
# New keys in mappings/rifle merge with framework defaults.
# To override a framework setting use lib.mkForce.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {
      programs.ranger = {

        # -------------------------------------------------------------------
        # Settings overrides
        # Framework defaults: preview_images=true, draw_borders="both",
        # column_ratios="1,3,4", vcs_aware=true.
        # -------------------------------------------------------------------
        # settings = {
        #   show_hidden = lib.mkForce true;
        #   preview_images_method = lib.mkForce "ueberzug";
        #   column_ratios = lib.mkForce "1,3,4";
        # };

        # -------------------------------------------------------------------
        # Additional key mappings (merge with framework nav keys)
        # -------------------------------------------------------------------
        # mappings = {
        #   gP = "cd ~/projects";
        #   "'" = "mark_load default";
        # };

        # -------------------------------------------------------------------
        # Additional rifle rules (prepended — matched before framework rules)
        # -------------------------------------------------------------------
        # rifle = [
        #   { condition = "ext epub, has zathura, X, flag f"; command = "zathura -- \"$@\""; }
        # ];

      };
    };
  };
}
