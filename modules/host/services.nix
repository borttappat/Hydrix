# Host Services - System services for the host
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  config = lib.mkIf (cfg.vmType == "host") {
    # Enable X server
    services.xserver.enable = true;
    services.xserver.displayManager.startx.enable = true;

    # Basic services
    services.printing.enable = false;
  };
}
