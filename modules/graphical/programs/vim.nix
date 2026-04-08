# Vim Configuration
#
# Installs vim and symlinks .vimrc from hydrix.programs.vim.configFile.
# Set that option in shared/vim.nix:
#   hydrix.programs.vim.configFile = ./configs/vim/.vimrc;
# The Nix path is resolved relative to the module file at evaluation time.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  configFile = config.hydrix.programs.vim.configFile;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    # Install vim system-wide
    environment.systemPackages = [ pkgs.vim ];

    # Set vim as default editor
    environment.variables.EDITOR = "vim";

    # Symlink .vimrc to user's home (only when configFile is set)
    home-manager.users.${username} = { pkgs, ... }: {
      home.file.".vimrc" = lib.mkIf (configFile != null) {
        source = configFile;
      };
    };
  };
}
