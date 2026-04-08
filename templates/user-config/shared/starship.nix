# Starship Prompt — User Configuration
#
# Set configFile to deploy your starship.toml from configs/starship/starship.toml.
# The Nix path is resolved relative to this file at evaluation time —
# no absolute paths, works in pure evaluation mode.
#
# Edit configs/starship/starship.toml to customise your prompt.
# Reference: https://starship.rs/config/

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {

  # Deploy starship.toml from configs/starship/starship.toml
  hydrix.programs.starship.configFile = lib.mkDefault ./configs/starship/starship.toml;

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
