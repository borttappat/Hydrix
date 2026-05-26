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

  # Use babelfish instead of foreign-env for sourcing bash env vars.
  # foreign-env spawns bash twice per call (~57ms each, runs 3x = ~170ms).
  # babelfish is a compiled Go binary that does the same translation near-instantly.
  programs.fish.useBabelfish = lib.mkIf (cfg.shell == "fish") true;

  # Set default shell for user
  users.defaultUserShell = shellPkg;
}
