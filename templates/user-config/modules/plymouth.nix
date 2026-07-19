# Hydrix Plymouth boot animation — mirrors the GRUB theme (same title, colors).
# Option declarations + implementation live in the framework
# (theming/boot/plymouth.nix) — this file just sets values.
{ config, lib, pkgs, ... }:
{
  hydrix.plymouth = {
    enable = lib.mkDefault true;
    showMessages = lib.mkDefault true;  # Show systemd boot messages scrolling during boot
    # fontSize = lib.mkDefault 18;  # DEFAULT: 18 — match hydrix.grub.theme.fontSize

    # title = "HYDRIX";
    # colors = {
    #   bg           = "#000000";
    #   accent       = "#05AF5A";
    #   accentBright = "#00FF80";
    #   fg           = "#dfdfdf";
    #   error        = "#FF4444";
    # };
  };
}
