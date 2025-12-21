# Fish shell configuration via home-manager
# Deploys config files only - fish shell itself is enabled in fish.nix
{ config, pkgs, lib, ... }:

{
  home-manager.users.traum = {
    # Required by home-manager
    home.stateVersion = "25.05";

    # Deploy fish config and starship
    # Note: xinitrc.nix deploys fish_variables and functions
    home.file.".config/fish/config.fish".source = ../../configs/fish/config.fish;
    home.file.".config/starship.toml".source = ../../configs/starship/starship.toml;
  };
}
