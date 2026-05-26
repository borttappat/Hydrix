# Vim Configuration
#
# Installs vim and sets it as the default editor.
# .vimrc is deployed from shared/vim.nix (configs/vim/.vimrc in user config).

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    environment.systemPackages = [ pkgs.vim ];
    environment.variables.EDITOR = "vim";
  };
}
