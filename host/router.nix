# Router Module - MicroVM router VM
#
# Reads from hydrix.router.*
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  routerCfg = cfg.router;
  netCfg = cfg.networking;
  vfioCfg = cfg.hardware.vfio;
in {
  config = lib.mkIf (cfg.vmType == "host" && routerCfg.type == "microvm") {
    # MicroVM router is handled by microvmHost module
    # Just ensure it's enabled when router.type == "microvm"
    hydrix.microvmHost.vms."${cfg.microvmHost.vmNames.router}" = {
      enable = lib.mkDefault true;
      autostart = lib.mkDefault routerCfg.autostart;
    };
  };
}
