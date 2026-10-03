# Router VM user settings
# DNS servers, firewall, extra packages, VPN config goes in vpn/mullvad.nix
#
# WiFi/WireGuard sampling is Hydrix's router-netlink-poller; throughput is
# measured per request by router-stats-server. See
# hydrix.router.polling.{interval,enableNetStats,enableWgStatus} to tune
# the sample rate or disable a piece of it.
{ pkgs, ... }: {
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
      # VMs use the static address <subnet>.<CID>, e.g. 192.168.107.107.
      # allowedAccessTo = [
      #   { from = "192.168.103.0/24"; to = "192.168.107.107"; ports = [ 8096 ]; }
      # ];
    };
  };

  # Standing port forwards from the router uplink's LAN (the home/hotel
  # network) to a VM, e.g. a media server for a TV. Same mechanism as the
  # host's `pentest-lan forward add`: DNAT on the uplink, replies routed back
  # past the VM's VPN table, so the target may exit through Mullvad. VM
  # networks otherwise cannot reach that LAN, and it cannot reach them.
  # hydrix.router.lanControl.forwards = [
  #   { cid = 107; port = 8096; }   # -> 192.168.107.107:8096
  # ];
}
