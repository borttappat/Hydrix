# Fish shell configuration
{ config, pkgs, ... }:

{
  imports = [
    ./fish-home.nix  # Home-manager fish configuration
  ];

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
