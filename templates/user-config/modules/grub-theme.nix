# Hydrix GRUB bootloader theme — dark background, Iosevka font, "HYDRIX" label.
# Option declarations + implementation live in the framework
# (theming/boot/grub-theme.nix) — this file just sets values.
{ config, lib, pkgs, hydrix, ... }:
{
  hydrix.grub.theme = {
    enable = lib.mkDefault true;
    # fontSize = lib.mkDefault 18;  # DEFAULT: 18 (title = 1.6x, hint = 0.75x)

    # Wallpaper for the GRUB background. Comment out for a solid color instead.
    background = lib.mkDefault "${hydrix}/theming/wallpapers/Hydrix.png";

    # colors = {
    #   bg           = "#000000";
    #   fg           = "#dfdfdf";
    #   accent       = "#05AF5A";
    #   accentBright = "#00FF80";
    #   muted        = "#A0A0A0";
    # };
  };
}
