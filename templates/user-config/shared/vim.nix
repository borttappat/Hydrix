# Vim — User Configuration
#
# Edit configs/vim/.vimrc directly to customise vim.
# The framework symlinks that file to ~/.vimrc at build time.
#
# This file exists only to document the approach. Use it if you need
# NixOS-level vim settings (plugins via home-manager programs.vim, etc.).

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { pkgs, ... }: {

      # -------------------------------------------------------------------
      # vim-plug or vim plugin management (optional)
      # The framework installs bare vim; add plugins here if needed.
      # -------------------------------------------------------------------
      # programs.vim = {
      #   plugins = with pkgs.vimPlugins; [
      #     vim-nix
      #     vim-commentary
      #     fzf-vim
      #   ];
      # };

    };
  };
}
