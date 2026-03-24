# Host Networking - Bridges and routing for VM isolation
#
# Reads from hydrix.networking.*
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  netCfg = cfg.networking;

  # Generate bridge config from list
  bridgeConfigs = lib.genAttrs netCfg.bridges (br: { interfaces = []; });

  # Management and shared bridges get host IPs
  mgmtSubnet = netCfg.subnets.mgmt or "192.168.100";
  sharedSubnet = netCfg.subnets.shared or "192.168.105";
in {
  config = lib.mkIf (cfg.vmType == "host" && cfg.router.type != "none") {
    # Disable NetworkManager - router VM handles networking
    networking.networkmanager.enable = lib.mkForce false;
    networking.useDHCP = lib.mkForce false;

    # Create bridges
    networking.bridges = bridgeConfigs;

    # Host IPs on management and shared bridges
    networking.interfaces = {
      br-mgmt.ipv4.addresses = [{
        address = "${mgmtSubnet}.1";
        prefixLength = 24;
      }];
      br-shared.ipv4.addresses = [{
        address = "${sharedSubnet}.1";
        prefixLength = 24;
      }];
      # Ensure other bridges are up
      br-pentest.useDHCP = false;
      br-comms.useDHCP = false;
      br-lurking.useDHCP = false;
      br-browse.useDHCP = false;
      br-dev.useDHCP = false;
      br-builder.useDHCP = false;
    };

    # NOTE: No default gateway in base config.
    # Base config = lockdown mode (host has no internet access).
    # The 'administrative' specialisation adds the default gateway.

    # Trust all bridges
    networking.firewall = {
      enable = true;
      trustedInterfaces = netCfg.bridges;
    };
  };
}
