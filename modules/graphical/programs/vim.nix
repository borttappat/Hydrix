# Vim Configuration
#
# Installs vim and symlinks the config from configs/vim/.vimrc
# Does NOT use Home Manager's programs.vim to keep it simple.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  vimrcSource = ../../../configs/vim/.vimrc;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    # Install vim system-wide
    environment.systemPackages = [ pkgs.vim ];

    # Set vim as default editor
    environment.variables.EDITOR = "vim";

    # Symlink .vimrc to user's home
    home-manager.users.${username} = { pkgs, ... }: {
      home.file.".vimrc".source = vimrcSource;
    };
  };
}
