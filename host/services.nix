# Host Services - System services for the host
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  config = lib.mkIf (cfg.vmType == "host") {
    # Basic services
    services.printing.enable = false;
  };
}
