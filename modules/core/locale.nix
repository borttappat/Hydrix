# Locale Configuration - Applied from hydrix.locale.* options
#
# Note: options.nix already applies these via config section.
# This module adds extra locale settings.
{ config, lib, ... }:

let
  cfg = config.hydrix;
in {
  # Extra locale settings (Swedish formats with English language)
  i18n.extraLocaleSettings = lib.mkDefault {
    LC_ADDRESS = "sv_SE.UTF-8";
    LC_IDENTIFICATION = "sv_SE.UTF-8";
    LC_MEASUREMENT = "sv_SE.UTF-8";
    LC_MONETARY = "sv_SE.UTF-8";
    LC_NAME = "sv_SE.UTF-8";
    LC_NUMERIC = "sv_SE.UTF-8";
    LC_PAPER = "sv_SE.UTF-8";
    LC_TELEPHONE = "sv_SE.UTF-8";
    LC_TIME = "sv_SE.UTF-8";
  };
}
