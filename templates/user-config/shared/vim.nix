# Vim — User Configuration
#
# Set configFile to deploy your .vimrc from configs/vim/.vimrc.
# The Nix path is resolved relative to this file at evaluation time —
# no absolute paths, works in pure evaluation mode.
#
# Edit configs/vim/.vimrc directly to customise vim behaviour.

{ lib, ... }:

{
  # Deploy .vimrc from configs/vim/.vimrc
  hydrix.programs.vim.configFile = lib.mkDefault ../configs/vim/.vimrc;

  # -------------------------------------------------------------------
  # Vim plugin management (optional)
  # The framework installs bare vim; uncomment to add plugins.
  # -------------------------------------------------------------------
  # home-manager.users.<name>.programs.vim.plugins = with pkgs.vimPlugins; [
  #   vim-nix
  #   vim-commentary
  #   fzf-vim
  # ];
}
