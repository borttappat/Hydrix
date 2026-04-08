# Starship Prompt Configuration
#
# Installs starship and symlinks the config from configs/starship/starship.toml
# in the user's hydrix-config directory. Fish sources starship on shell init.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  starshipConfig = "${config.hydrix.paths.configDir}/configs/starship/starship.toml";
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
