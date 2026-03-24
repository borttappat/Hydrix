# Shell Packages - packages required by the shared fish shell configuration
#
# Imported by both host-packages.nix and vm-packages.nix to ensure
# the shell experience is identical on host and VMs.
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Shell
    fish
    starship

    # Fish abbreviation dependencies
    eza        # ls, l, lt
    zoxide     # smart cd (z)
    ugrep      # grep, egrep, fgrep
    fastfetch  # cf

    # Modern CLI tools
    fzf        # fuzzy finder (Ctrl+R, etc.)
    ripgrep    # rg
    fd         # find replacement
    bat        # cat replacement
    dust       # du replacement
    procs      # ps replacement
    bottom     # system monitor (btm)
    jq         # JSON

    # Terminal
    unstable.alacritty
    tmux
  ];
}
