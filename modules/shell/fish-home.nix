# Fish shell configuration via home-manager
# Deploys config files only - fish shell itself is enabled in fish.nix
{ config, pkgs, lib, ... }:

let
  # Username is computed by hydrix-options.nix (single source of truth)
  username = config.hydrix.username;
in
{
  home-manager.users.${username} = {
    # Required by home-manager
    home.stateVersion = "25.05";

    # Deploy fish config and starship
    # Note: xinitrc.nix deploys fish_variables and functions
    home.file.".config/fish/config.fish".source = ../../configs/fish/config.fish;
    home.file.".config/starship.toml".source = ../../configs/starship/starship.toml;
  };
}
