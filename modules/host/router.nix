# Router Module - MicroVM or Libvirt router VM
#
# Reads from hydrix.router.*
# Router type selection: microvm (default) or libvirt
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  routerCfg = cfg.router;
  netCfg = cfg.networking;
  vfioCfg = cfg.hardware.vfio;
in {
  config = lib.mkMerge [
    # =========================================================================
    # MICROVM ROUTER (default)
    # =========================================================================
    (lib.mkIf (cfg.vmType == "host" && routerCfg.type == "microvm") {
      # MicroVM router is handled by microvmHost module
      # Just ensure it's enabled when router.type == "microvm"
      hydrix.microvmHost.vms."microvm-router" = {
        enable = lib.mkDefault true;
        autostart = lib.mkDefault routerCfg.autostart;
      };
    })

    # =========================================================================
    # LIBVIRT ROUTER
    # =========================================================================
    # When router.type == "libvirt", auto-enable the libvirt gate so that
    # virt.nix pulls in QEMU/virt-manager/libvirtd.
    (lib.mkIf (cfg.vmType == "host" && routerCfg.type == "libvirt") {
      hydrix.libvirt.enable = true;
    })
  ];
}
