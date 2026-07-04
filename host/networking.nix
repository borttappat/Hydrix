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
    # Ensure all VM bridges are up with no DHCP — derived from the same set
    # used to create the bridges so new profiles are covered automatically.
    networking.interfaces = lib.mapAttrs (_: _: { useDHCP = false; })
      (bridgeConfigs // extraBridgeConfigs // infraBridgeConfigs // wanBridgeConfig)
      # Explicitly declare the WAN physical device so network-setup brings it up
      # and NixOS's scripted networking properly enslaves it to br-wan.
      // lib.optionalAttrs (ethernetWanEnabled && routerCfg.wan.device != null) {
        "${routerCfg.wan.device}".useDHCP = false;
      };

    # NixOS's network-setup silently skips bridge member enslaving in some cases.
    # This service runs after network-setup and guarantees the WAN device is
    # enslaved to br-wan before any microVMs start.
    systemd.services.wan-bridge-member = lib.mkIf (ethernetWanEnabled && routerCfg.wan.device != null) {
      description = "Enslave ${routerCfg.wan.device} to br-wan";
      after = [ "network-setup.service" ];
      before = [ "microvm@.service" "network-online.target" ];
      wantedBy = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.iproute2 ];
      script = ''
        ip link set ${routerCfg.wan.device} master br-wan 2>/dev/null || true
        ip link set ${routerCfg.wan.device} up
      '';
    };

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

    # Explicit DROP for all VM bridge interfaces in the INPUT chain.
    # Belt-and-suspenders beyond the empty allowedTCPPorts — ensures no VM can
    # initiate a connection to the host regardless of other firewall settings.
    #
    # Note: ct state established,related accept fires BEFORE these rules, so
    # responses to host-initiated connections (e.g. gateway responses in admin
    # mode) are still accepted.
    networking.firewall.extraInputRules = let
      allBridges =
        netCfg.bridges
        ++ lib.unique (lib.attrValues netCfg.infraTapBridges)
        ++ map (n: "br-${n.name}") netCfg.extraNetworks
        ++ lib.optionals ethernetWanEnabled [ "br-wan" ];
    in lib.concatMapStringsSep "\n"
      (br: ''iifname "${br}" drop'')
      allBridges;

  };
}
