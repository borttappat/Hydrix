# Shell Configuration - Configurable default shell
{ config, pkgs, lib, ... }:

let
  cfg = config.hydrix;

  # Map shell name to package
  shellPkg = {
    fish = pkgs.fish;
    bash = pkgs.bash;
    zsh = pkgs.zsh;
  }.${cfg.shell};
in {
  # Enable the configured shell
  programs.fish.enable = cfg.shell == "fish";
  programs.zsh.enable = cfg.shell == "zsh";

  # Set default shell for user
  users.defaultUserShell = shellPkg;
}
