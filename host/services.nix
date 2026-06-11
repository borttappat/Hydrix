# Host Services - System services for the host
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  config = lib.mkIf (cfg.vmType == "host") {
    # Enable X server only when i3/X11 stack is active
    services.xserver.enable = lib.mkIf config.hydrix.i3.enable true;
    services.xserver.displayManager.startx.enable = lib.mkIf config.hydrix.i3.enable true;

    # Basic services
    services.printing.enable = false;
  };
}
