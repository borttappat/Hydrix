# Starship Prompt — User Configuration
#
# Set configFile to deploy your starship.toml from configs/starship/starship.toml.
# The Nix path is resolved relative to this file at evaluation time —
# no absolute paths, works in pure evaluation mode.
#
# Edit configs/starship/starship.toml to customise your prompt.
# Reference: https://starship.rs/config/

{ lib, ... }:

{
  # Deploy starship.toml from configs/starship/starship.toml
  hydrix.programs.starship.configFile = lib.mkDefault ./configs/starship/starship.toml;

  # -------------------------------------------------------------------
  # Starship environment variables (optional)
  # Uncomment and add to home-manager session vars if needed.
  # -------------------------------------------------------------------
  # home-manager.users.<name>.home.sessionVariables = {
  #   STARSHIP_LOG = "error";
  # };
}
