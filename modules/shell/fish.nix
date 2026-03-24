# Fish shell configuration
#
# Note: Fish user config is handled by modules/graphical/programs/fish.nix
# This module only enables fish as the default shell system-wide
{ config, pkgs, ... }:

{
  # Enable fish as default shell
  programs.fish.enable = true;
  users.defaultUserShell = pkgs.fish;

  # Use babelfish instead of foreign-env for sourcing bash env vars
  # foreign-env spawns bash twice per call (~57ms each, runs 3x = ~170ms).
  # babelfish is a compiled Go binary that does the same translation near-instantly.
  programs.fish.useBabelfish = true;

  # Install fish and related tools
  environment.systemPackages = with pkgs; [
    fish
    starship  # Prompt
    zoxide    # Smart cd (init in config.fish)
  ];
}
