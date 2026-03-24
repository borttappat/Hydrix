# Starship Prompt Configuration
#
# Installs starship and symlinks the config from configs/starship/starship.toml
# Fish sources starship on shell init.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  starshipConfig = ../../../configs/starship/starship.toml;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    # Install starship system-wide
    environment.systemPackages = [ pkgs.starship ];

    home-manager.users.${username} = { pkgs, ... }: {
      # Symlink starship.toml to ~/.config/starship.toml
      xdg.configFile."starship.toml".source = starshipConfig;

      # Initialize starship in fish
      programs.fish.interactiveShellInit = lib.mkAfter ''
        ${pkgs.starship}/bin/starship init fish | source
      '';
    };
  };
}
