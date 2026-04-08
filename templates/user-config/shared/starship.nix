# Starship Prompt — User Configuration
#
# Edit configs/starship/starship.toml directly to customise your prompt.
# The framework symlinks that file to ~/.config/starship.toml at build time.
#
# Reference: https://starship.rs/config/
#
# This file exists only to document the approach. No NixOS options needed
# unless you want to add starship settings that cannot live in the TOML
# (e.g. environment variables that affect prompt behaviour).

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {

      # -------------------------------------------------------------------
      # Starship environment variables (optional)
      # -------------------------------------------------------------------
      # home.sessionVariables = {
      #   STARSHIP_LOG = "error";
      # };

    };
  };
}
