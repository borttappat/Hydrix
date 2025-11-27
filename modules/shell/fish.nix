# Fish shell configuration
{ config, pkgs, ... }:

{
  # Enable fish as default shell
  programs.fish.enable = true;
  users.defaultUserShell = pkgs.fish;

  # Install fish and related tools
  environment.systemPackages = with pkgs; [
    fish
    starship  # Prompt
    zoxide    # Smart cd (init in config.fish)
  ];
}
