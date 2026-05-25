# Host Networking - Bridges and routing for VM isolation
#
# Reads from hydrix.networking.*
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  netCfg = cfg.networking;
  routerCfg = cfg.router;

  # Generate bridge config from built-in list
  bridgeConfigs = lib.genAttrs netCfg.bridges (br: { interfaces = []; });

  # Extra bridges from user-defined profiles (those with a new subnet + routerTap)
  extraBridgeConfigs = lib.genAttrs
    (map (n: "br-${n.name}") netCfg.extraNetworks)
    (_: { interfaces = []; });

  # Bridges from infra VM tapBridges — auto-discovers usb-sandbox, files, and any
  # future user infra VM without requiring changes to the default bridges list.
  infraBridgeConfigs = lib.genAttrs
    (lib.unique (lib.attrValues netCfg.infraTapBridges))
    (_: { interfaces = []; });

  # WAN bridge for ethernet WAN mode (macvtap): physical NIC is a member so
  # the router VM's mv-router-wan TAP shares the same L2 segment and can DHCP.
  ethernetWanEnabled =
    routerCfg.wan.mode == "macvtap" ||
    (routerCfg.wan.mode == "auto" && cfg.hardware.vfio.wifiPciAddress == "");
  wanBridgeConfig = lib.optionalAttrs ethernetWanEnabled {
    br-wan = {
      interfaces = lib.optional (routerCfg.wan.device != null) routerCfg.wan.device;
    };
  };

in {
  config = lib.mkIf (cfg.vmType == "host" && cfg.router.type != "none") {
    # Disable NetworkManager - router VM handles networking
    networking.networkmanager.enable = lib.mkForce false;
    networking.useDHCP = lib.mkForce false;

    # Create bridges (built-in + user-defined extra networks + infra VMs + WAN if ethernet mode)
    networking.bridges = bridgeConfigs // extraBridgeConfigs // infraBridgeConfigs // wanBridgeConfig;

    # Host IP on br-mgmt is set in the administrative specialisation only.
    # Ensure bridges are up with no DHCP.
    networking.interfaces = {
      br-mgmt.useDHCP = false;
      br-pentest.useDHCP = false;
      br-comms.useDHCP = false;
      br-lurking.useDHCP = false;
      br-browse.useDHCP = false;
      br-dev.useDHCP = false;
      br-builder.useDHCP = false;
    } // lib.listToAttrs (map (n: {
      name  = "br-${n.name}";
      value = { useDHCP = false; };
    }) netCfg.extraNetworks);

    # NOTE: No default gateway in base config.
    # Base config = lockdown mode (host has no internet access).
    # The 'administrative' specialisation adds the default gateway.

    # Disable IPv6 link-local on all VM bridges — host has no IPv6 VM networking
    # and link-local addresses would otherwise make the host reachable at L3.
    boot.kernel.sysctl = lib.genAttrs
      (map (br: "net.ipv6.conf.${br}.disable_ipv6")
        (netCfg.bridges
         ++ lib.unique (lib.attrValues netCfg.infraTapBridges)
         ++ map (n: "br-${n.name}") netCfg.extraNetworks))
      (_: 1);

    # Trust all bridges (built-in + extra networks + infra VMs)
    networking.firewall = {
      enable = true;
      trustedInterfaces = netCfg.bridges
        ++ map (n: "br-${n.name}") netCfg.extraNetworks
        ++ lib.unique (lib.attrValues netCfg.infraTapBridges);
    };
  };
}
