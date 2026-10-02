# Hydrix Plymouth boot animation — mirrors the GRUB theme (same title, colors).
# Option declarations + implementation live in the framework
# (theming/boot/plymouth.nix) — this file just sets values.
{ config, lib, pkgs, ... }:
{
  hydrix.plymouth = {
    enable = lib.mkDefault true;
    showMessages = lib.mkDefault true;  # Show systemd boot messages scrolling during boot
    # followWal = lib.mkDefault true;  # DEFAULT: false - follow runtime wal colors, restore-colorscheme reverts
    # showShutdownMessages = lib.mkDefault true;  # DEFAULT: follows showMessages
    # preview = lib.mkDefault false;  # DEFAULT: false - adds hydrix-plymouth-preview (splash in an XWayland window, no root/TTY)
    # fontSize = lib.mkDefault 18;  # DEFAULT: 18 — match hydrix.grub.theme.fontSize
    # messageMargin = lib.mkDefault 0.01;  # DEFAULT: 0.01 - message gap from left/right/top edges (fraction of screen height)

    # title = "HYDRIX";
    # colors = {
    #   bg           = "#000000";
    #   accent       = "#05AF5A";
    #   accentBright = "#00FF80";
    #   fg           = "#dfdfdf";
    #   error        = "#FF4444";  # fixed red, not colorscheme-derived
    #   # Boot message colors, DEFAULT: from the colorscheme
    #   ok           = "#08B860";  # [  OK  ] tag (color2)
    #   warn         = "#02D66C";  # [DEPEND] tag, [ *** ] ticker (color3)
    #   highlight    = "#00FA7D";  # unit descriptions (color4)
    #   dim          = "#9c9c9c";  # Starting lines, durations (color8)
    # };
  };
}
