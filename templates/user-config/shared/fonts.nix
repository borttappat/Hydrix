{ config, lib, pkgs, ... }:
{
  imports = [ ../fonts ];

  hydrix.graphical.font = {
    packages = with pkgs; [ iosevka ];
    packageMap = with pkgs; { "Iosevka" = iosevka; };
    extraPackages = with pkgs; [ dejavu_fonts noto-fonts-color-emoji ];
    vmPackages = with pkgs; [ iosevka noto-fonts noto-fonts-emoji ];
  };
}
