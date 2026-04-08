# Vim — User Configuration
#
# Set configFile to deploy your .vimrc from configs/vim/.vimrc.
# The Nix path is resolved relative to this file at evaluation time —
# no absolute paths, works in pure evaluation mode.
#
# Edit configs/vim/.vimrc directly to customise vim behaviour.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {

  # Deploy .vimrc from configs/vim/.vimrc
  hydrix.programs.vim.configFile = lib.mkDefault ./configs/vim/.vimrc;

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
