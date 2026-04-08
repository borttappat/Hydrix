# Starship Prompt Configuration
#
# Installs starship and symlinks starship.toml from
# hydrix.programs.starship.configFile. Set that option in shared/starship.nix:
#   hydrix.programs.starship.configFile = ./configs/starship/starship.toml;
# The Nix path is resolved relative to the module file at evaluation time.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  configFile = config.hydrix.programs.starship.configFile;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    # Install starship system-wide
    environment.systemPackages = [ pkgs.starship ];

    home-manager.users.${username} = { pkgs, ... }: {
      # Symlink starship.toml to ~/.config/starship.toml (only when configFile is set)
      xdg.configFile."starship.toml" = lib.mkIf (configFile != null) {
        source = configFile;
      };

      # Initialize starship in fish
      programs.fish.interactiveShellInit = lib.mkAfter ''
        ${pkgs.starship}/bin/starship init fish | source
      '';
    };
  };
}
