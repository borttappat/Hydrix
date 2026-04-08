# Starship Prompt Configuration
#
# Installs starship system-wide and initialises it in fish.
# starship.toml is deployed from shared/starship.nix (configs/starship/ in user config).

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    environment.systemPackages = [ pkgs.starship ];

    home-manager.users.${username} = { pkgs, ... }: {

      # Initialize starship in fish
      programs.fish.interactiveShellInit = lib.mkAfter ''
        ${pkgs.starship}/bin/starship init fish | source
      '';
    };
  };
}
