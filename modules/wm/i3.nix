# i3 window manager with all graphical packages
{ config, pkgs, lib, ... }:

{
  # Enable X11 and i3
  services.xserver.enable = true;
  services.xserver.displayManager.startx.enable = true;
  services.xserver.windowManager.i3.enable = true;
  services.xserver.windowManager.i3.package = pkgs.i3-gaps;

  # Install all WM-related packages
  environment.systemPackages = with pkgs; [
    # Window manager
    i3-gaps
    i3lock-color
    i3status

    # Compositor and visual
    picom
    feh

    # Status bar and launcher
    polybar
    rofi

    # Terminal
    unstable.alacritty

    # Notifications
    dunst
    libnotify

    # Screenshots
    flameshot
    scrot

    # Utilities
    arandr
    lxappearance
    pavucontrol
    xorg.xrandr
    xorg.xmodmap
    xorg.xinit
    xorg.xrdb
    xorg.xorgserver
    xorg.xmessage
    xorg.xcursorthemes
    xorg.xdpyinfo
    xclip
    xdotool

    # Theming (for static configs, not dynamic pywal)
    imagemagick
  ];

  # Fonts for i3/polybar
  fonts.packages = with pkgs; [
    scientifica
    gohufont
    cozette
    creep
    cherry
    envypn-font
    tamsyn
    tamzen
    monocraft
    miracode
    termsyn
    spleen
    anakron
  ];
}
