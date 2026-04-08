# Vim — User Configuration
#
# Symlinks configs/vim/.vimrc to ~/.vimrc at build time.
# Edit configs/vim/.vimrc directly to customise vim behaviour.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { ... }: {
      home.file.".vimrc".source = ../configs/vim/.vimrc;

      # -------------------------------------------------------------------
      # Vim plugin management (optional)
      # The framework installs bare vim; uncomment to add plugins.
      # -------------------------------------------------------------------
      # programs.vim.plugins = with pkgs.vimPlugins; [
      #   vim-nix
      #   vim-commentary
      #   fzf-vim
      # ];
    };
  };
}
