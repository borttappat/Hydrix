# Lockdown Router VM Configuration
# Extended router VM with VPN policy routing for isolated networks
#
# Build: nix build '.#lockdown-router-vm'
# Deploy: ./scripts/deploy-lockdown-router.sh
#
# Network Layout:
#   enp1s0 (br-wan)    - WAN uplink (to internet via host bridge or passthrough)
#   enp2s0 (br-mgmt)   - Management network (10.100.0.0/24)
#   enp3s0 (br-pentest)- Pentest network (10.100.1.0/24) → Client VPN
#   enp4s0 (br-office) - Office network (10.100.2.0/24) → Corp VPN
#   enp5s0 (br-browse) - Browse network (10.100.3.0/24) → Privacy VPN
#   enp6s0 (br-dev)    - Dev network (10.100.4.0/24) → Direct/Configurable
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./vpn-routing.nix
  ];

  nixpkgs.config.allowUnfree = true;

  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi"
  ];

  boot.kernelParams = [
    "console=tty1"
    "console=ttyS0,115200n8"
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # WireGuard kernel module
  boot.extraModulePackages = with config.boot.kernelPackages; [ wireguard ];

  system.stateVersion = "25.05";

  networking = {
    hostName = "lockdown-router";
    useDHCP = false;
    enableIPv6 = false;
    networkmanager.enable = false;  # We manage networking manually

    # WAN interface - gets IP via DHCP from upstream
    interfaces.enp1s0 = {
      useDHCP = true;
    };

    # Management network - no internet routing, just for router management
    interfaces.enp2s0 = {
      ipv4.addresses = [{
        address = "10.100.0.253";
        prefixLength = 24;
      }];
    };

    # Pentest network → routes through client VPN
    interfaces.enp3s0 = {
      ipv4.addresses = [{
        address = "10.100.1.253";
        prefixLength = 24;
      }];
    };

    # Office network → routes through corp VPN
    interfaces.enp4s0 = {
      ipv4.addresses = [{
        address = "10.100.2.253";
        prefixLength = 24;
      }];
    };

    # Browse network → routes through privacy VPN
    interfaces.enp5s0 = {
      ipv4.addresses = [{
        address = "10.100.3.253";
        prefixLength = 24;
      }];
    };

    # Dev network → configurable (direct or VPN)
    interfaces.enp6s0 = {
      ipv4.addresses = [{
        address = "10.100.4.253";
        prefixLength = 24;
      }];
    };
  };

  # Enable VPN policy routing
  hydrix.vpnRouting = {
    enable = true;
    wanInterface = "enp1s0";

    # Default assignments (can be changed at runtime with vpn-assign)
    networkAssignments = {
      pentest = null;     # Blocked by default (must configure VPN)
      office = null;      # Blocked by default
      browse = null;      # Blocked by default
      dev = "direct";     # Direct WAN access for development
    };

    killSwitch = true;
    allowInterVmTraffic = false;  # Full isolation between VM networks

    # VPN tunnels will be configured via /etc/wireguard/*.conf
    # or /etc/openvpn/*.conf files
    vpnTunnels = {};  # Empty - managed via config files
  };

  # DHCP server for all VM networks
  services.dnsmasq = {
    enable = true;
    settings = {
      # Listen on all internal interfaces
      interface = [ "enp2s0" "enp3s0" "enp4s0" "enp5s0" "enp6s0" ];
      bind-interfaces = true;

      # DHCP ranges for each network
      dhcp-range = [
        "enp2s0,10.100.0.10,10.100.0.200,24h"   # Management
        "enp3s0,10.100.1.10,10.100.1.200,24h"   # Pentest
        "enp4s0,10.100.2.10,10.100.2.200,24h"   # Office
        "enp5s0,10.100.3.10,10.100.3.200,24h"   # Browse
        "enp6s0,10.100.4.10,10.100.4.200,24h"   # Dev
      ];

      # Router (gateway) for each network
      dhcp-option = [
        "enp2s0,option:router,10.100.0.253"
        "enp2s0,option:dns-server,10.100.0.253"
        "enp3s0,option:router,10.100.1.253"
        "enp3s0,option:dns-server,10.100.1.253"
        "enp4s0,option:router,10.100.2.253"
        "enp4s0,option:dns-server,10.100.2.253"
        "enp5s0,option:router,10.100.3.253"
        "enp5s0,option:dns-server,10.100.3.253"
        "enp6s0,option:router,10.100.4.253"
        "enp6s0,option:dns-server,10.100.4.253"
      ];

      # DNS forwarding (will be overridden by VPN DNS when connected)
      server = [ "1.1.1.1" "8.8.8.8" ];

      # Logging
      log-dhcp = true;
      log-queries = true;
    };
  };

  # SSH for management
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;  # For initial setup
      PermitRootLogin = "no";
    };
  };

  # QEMU guest agent
  services.qemuGuest.enable = true;

  # Auto-login for console access
  services.getty.autologinUser = "traum";

  # User account
  users.users.traum = {
    isNormalUser = true;
    password = "ifEHbuuhSez9";  # Change this!
    extraGroups = [ "wheel" "networkmanager" ];
  };

  security.sudo.wheelNeedsPassword = false;

  # VPN management scripts
  environment.systemPackages = with pkgs; [
    # Network tools
    wireguard-tools
    openvpn
    iproute2
    iptables
    nftables
    tcpdump
    nettools
    bind.dnsutils
    bridge-utils

    # System tools
    pciutils
    usbutils
    htop
    vim
    nano
    tmux
    git

    # VPN management helpers
    (writeShellScriptBin "vpn-assign" (builtins.readFile ../../scripts/vpn-assign.sh))
    (writeShellScriptBin "vpn-status" (builtins.readFile ../../scripts/vpn-status.sh))
  ];

  # Create VPN config directories
  systemd.tmpfiles.rules = [
    "d /etc/wireguard 0700 root root -"
    "d /etc/openvpn/client 0700 root root -"
    "d /var/lib/hydrix-vpn 0755 root root -"
  ];

  # Service to display status on boot
  systemd.services.lockdown-router-banner = {
    description = "Display lockdown router status";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      echo ""
      echo "╔══════════════════════════════════════════════════════════╗"
      echo "║           LOCKDOWN ROUTER VM ACTIVE                      ║"
      echo "╠══════════════════════════════════════════════════════════╣"
      echo "║  Management: 10.100.0.253  (SSH: ssh traum@10.100.0.253)║"
      echo "║  Pentest:    10.100.1.253  (vpn-assign pentest <vpn>)   ║"
      echo "║  Office:     10.100.2.253  (vpn-assign office <vpn>)    ║"
      echo "║  Browse:     10.100.3.253  (vpn-assign browse <vpn>)    ║"
      echo "║  Dev:        10.100.4.253  (vpn-assign dev <vpn>)       ║"
      echo "╠══════════════════════════════════════════════════════════╣"
      echo "║  Commands:                                               ║"
      echo "║    vpn-status          - Show routing status             ║"
      echo "║    vpn-assign <net> <vpn> - Assign network to VPN       ║"
      echo "║    vpn-assign list     - List available VPNs             ║"
      echo "╚══════════════════════════════════════════════════════════╝"
      echo ""
    '';
  };

  # Motd
  users.motd = ''

    ┌─────────────────────────────────────────────────┐
    │  Lockdown Router VM                             │
    │  Run 'vpn-status' to see network assignments    │
    │  Run 'vpn-assign --help' for routing commands   │
    └─────────────────────────────────────────────────┘

  '';
}
