# CLI tools and utilities
{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Editors
    vim

    # Compilers and interpreters
    gcc
    python3
    jython

    # Modern CLI replacements
    eza           # better ls
    bat           # better cat
    ugrep         # better grep
    du-dust       # better du
    bottom        # better top
    htop

    # Terminal utilities
    unstable.nix-output-monitor
    tmux
    fzf
    asciinema
    cava
    fastfetch
    cbonsai
    cmatrix
    ranger
    joshuto
    figlet
    ttyper
    pipes-rs
    clock-rs

    # File management
    rsync
    unzip
    rar

    # Network tools
    curl
    wget
    iw
    wirelesstools
    openvpn
    bandwhich
    gping
    whois

    # System tools
    killall
    pciutils
    lshw
    toybox
    findutils
    busybox
    inetutils
    udisks
    brightnessctl

    # Nix tools
    nix-prefetch
    nix-prefetch-github

    # Development
    git
    gh

    # Utilities
    tealdeer      # tldr man pages
    jq            # JSON processor
    envsubst

    # X11 tools (if needed for scripts)
    xorg.xinit
    xorg.xrdb
    xorg.xorgserver
    xorg.xmodmap

    # Audio
    pulseaudioFull
    alsa-utils
  ];
}
