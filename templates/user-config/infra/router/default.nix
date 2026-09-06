# Router VM user settings
# DNS servers, firewall, extra packages, VPN config goes in vpn/mullvad.nix
{ pkgs, ... }: {
  imports = [ ./wg-status.nix ./net-stats.nix ];
  hydrix.router.microvm = {
    # Extra packages available inside the router VM
    # extraPackages = [ pkgs.tcpdump pkgs.mtr ];

    dnsmasq = {
      servers = [ "1.1.1.1" "8.8.8.8" ];
      enableDhcpLogging = false;
    };

    firewall = {
      # Subnets that can reach each other (cross-VM access)
      sharedSubnets = [];

      # Scoped cross-VM access exceptions (IP/CIDR based): allow a source
      # subnet to reach a specific destination IP on specific ports, without
      # opening full inter-VM access like sharedSubnets does. Can also be set
      # from machine config instead -- see perMachineRouterConfigs in
      # flake.nix, which re-threads hydrix.router.microvm.firewall.
      # allowedAccessTo from the host machine config automatically.
      # allowedAccessTo = [
      #   { from = "192.168.103.0/24"; to = "192.168.107.10"; ports = [ 8080 ]; }
      # ];
    };
  };
}
