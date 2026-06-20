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
    };
  };
}
