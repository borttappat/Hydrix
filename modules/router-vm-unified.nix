# Unified Router VM Configuration
# Supports both standard mode (simple NAT) and lockdown mode (VPN policy routing)
#
# Build: nix build '.#router-vm'
# Deploy: ./scripts/deploy-router.sh
#
# Mode detection:
#   - Standard mode: Uses original 192.168.x.x networks, simple NAT
#   - Lockdown mode: Uses 10.100.x.x isolated networks, VPN policy routing
#
# The router auto-detects which mode based on connected interfaces/networks
{ config, lib, pkgs, modulesPath, ... }:

with lib;

let
  # Check if we're in lockdown mode by looking at network configuration
  # Lockdown mode uses 10.100.x.x networks, standard uses 192.168.x.x
  cfg = config.hydrix.router;
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  options.hydrix.router = {
    mode = mkOption {
      type = types.enum [ "auto" "standard" "lockdown" ];
      default = "auto";
      description = ''
        Router operating mode:
        - auto: Detect based on connected networks
        - standard: Simple NAT routing (192.168.x.x)
        - lockdown: VPN policy routing with kill switches (10.100.x.x)
      '';
    };

    vpnRouting = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable VPN-based policy routing (for lockdown mode)";
      };

      killSwitch = mkOption {
        type = types.bool;
        default = true;
        description = "Drop traffic if assigned VPN is down";
      };

      allowInterVmTraffic = mkOption {
        type = types.bool;
        default = false;
        description = "Allow traffic between different VM networks";
      };
    };
  };

  config = {
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
    boot.extraModulePackages = with config.boot.kernelPackages; [ wireguard ];

    system.stateVersion = "25.05";

    networking = {
      hostName = "router-vm";
      useDHCP = false;
      enableIPv6 = false;
      networkmanager.enable = false;

      # WAN interface - DHCP from upstream (works in both modes)
      interfaces.enp1s0.useDHCP = true;

      firewall.enable = false;  # We use nftables directly
    };

    # IP forwarding
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv4.conf.default.rp_filter" = 0;
      "net.ipv4.conf.all.rp_filter" = 0;
    };

    # Routing tables for policy routing
    environment.etc."iproute2/rt_tables".text = ''
      255     local
      254     main
      253     default
      0       unspec
      # Hydrix VPN routing tables
      100     pentest
      101     office
      102     browse
      103     dev
    '';

    # Dynamic network configuration based on detected mode
    systemd.services.router-network-setup = {
      description = "Configure router networking based on mode";
      after = [ "network.target" ];
      before = [ "dnsmasq.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        #!/bin/bash
        set -e

        STATE_DIR="/var/lib/hydrix-router"
        mkdir -p "$STATE_DIR"

        # Detect mode based on interface naming and network topology
        # In lockdown: bridges are br-pentest etc. In standard: virbr2 etc
        detect_mode() {
          # Check if any interface has 10.100.x.x configured upstream
          # or if we're attached to br-* bridges
          if ip addr show | grep -q "10.100"; then
            echo "lockdown"
          elif ip link show | grep -qE "enp[2-6]s0.*master br-"; then
            echo "lockdown"
          else
            echo "standard"
          fi
        }

        MODE="${cfg.mode}"
        if [ "$MODE" = "auto" ]; then
          MODE=$(detect_mode)
        fi

        echo "Router mode: $MODE"
        echo "$MODE" > "$STATE_DIR/mode"

        case "$MODE" in
          standard)
            # Standard mode: 192.168.x.x networks
            ${pkgs.iproute2}/bin/ip addr add 192.168.100.253/24 dev enp2s0 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip addr add 192.168.101.253/24 dev enp3s0 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip addr add 192.168.102.253/24 dev enp4s0 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip addr add 192.168.103.253/24 dev enp5s0 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip addr add 192.168.104.253/24 dev enp6s0 2>/dev/null || true

            ${pkgs.iproute2}/bin/ip link set enp2s0 up
            ${pkgs.iproute2}/bin/ip link set enp3s0 up
            ${pkgs.iproute2}/bin/ip link set enp4s0 up
            ${pkgs.iproute2}/bin/ip link set enp5s0 up
            ${pkgs.iproute2}/bin/ip link set enp6s0 up 2>/dev/null || true
            ;;

          lockdown)
            # Lockdown mode: 10.100.x.x isolated networks
            ${pkgs.iproute2}/bin/ip addr add 10.100.0.253/24 dev enp2s0 2>/dev/null || true  # mgmt
            ${pkgs.iproute2}/bin/ip addr add 10.100.1.253/24 dev enp3s0 2>/dev/null || true  # pentest
            ${pkgs.iproute2}/bin/ip addr add 10.100.2.253/24 dev enp4s0 2>/dev/null || true  # office
            ${pkgs.iproute2}/bin/ip addr add 10.100.3.253/24 dev enp5s0 2>/dev/null || true  # browse
            ${pkgs.iproute2}/bin/ip addr add 10.100.4.253/24 dev enp6s0 2>/dev/null || true  # dev

            ${pkgs.iproute2}/bin/ip link set enp2s0 up
            ${pkgs.iproute2}/bin/ip link set enp3s0 up
            ${pkgs.iproute2}/bin/ip link set enp4s0 up
            ${pkgs.iproute2}/bin/ip link set enp5s0 up
            ${pkgs.iproute2}/bin/ip link set enp6s0 up 2>/dev/null || true

            # Set up policy routing rules for lockdown mode
            ${pkgs.iproute2}/bin/ip rule del fwmark 100 table pentest 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip rule del fwmark 101 table office 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip rule del fwmark 102 table browse 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip rule del fwmark 103 table dev 2>/dev/null || true

            ${pkgs.iproute2}/bin/ip rule add fwmark 100 table pentest priority 100
            ${pkgs.iproute2}/bin/ip rule add fwmark 101 table office priority 101
            ${pkgs.iproute2}/bin/ip rule add fwmark 102 table browse priority 102
            ${pkgs.iproute2}/bin/ip rule add fwmark 103 table dev priority 103

            # Default dev network to direct WAN access
            WAN_GW=$(${pkgs.iproute2}/bin/ip route | grep "default.*enp1s0" | awk '{print $3}')
            if [ -n "$WAN_GW" ]; then
              ${pkgs.iproute2}/bin/ip route add default via "$WAN_GW" table dev 2>/dev/null || true
            fi

            # Initialize VPN assignment state
            mkdir -p /var/lib/hydrix-vpn
            [ -f /var/lib/hydrix-vpn/pentest.assignment ] || echo "blocked" > /var/lib/hydrix-vpn/pentest.assignment
            [ -f /var/lib/hydrix-vpn/office.assignment ] || echo "blocked" > /var/lib/hydrix-vpn/office.assignment
            [ -f /var/lib/hydrix-vpn/browse.assignment ] || echo "blocked" > /var/lib/hydrix-vpn/browse.assignment
            [ -f /var/lib/hydrix-vpn/dev.assignment ] || echo "direct" > /var/lib/hydrix-vpn/dev.assignment
            ;;
        esac

        echo "Network setup complete for $MODE mode"
      '';
    };

    # Dynamic dnsmasq configuration
    systemd.services.dnsmasq-config = {
      description = "Generate dnsmasq config based on router mode";
      after = [ "router-network-setup.service" ];
      before = [ "dnsmasq.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        MODE=$(cat /var/lib/hydrix-router/mode 2>/dev/null || echo "standard")

        cat > /etc/dnsmasq.d/hydrix.conf << EOF
        bind-interfaces
        log-dhcp
        log-queries
        server=1.1.1.1
        server=8.8.8.8
        EOF

        case "$MODE" in
          standard)
            cat >> /etc/dnsmasq.d/hydrix.conf << EOF
        interface=enp2s0
        interface=enp3s0
        interface=enp4s0
        interface=enp5s0
        dhcp-range=enp2s0,192.168.100.10,192.168.100.200,24h
        dhcp-range=enp3s0,192.168.101.10,192.168.101.200,24h
        dhcp-range=enp4s0,192.168.102.10,192.168.102.200,24h
        dhcp-range=enp5s0,192.168.103.10,192.168.103.200,24h
        dhcp-option=enp2s0,option:router,192.168.100.253
        dhcp-option=enp2s0,option:dns-server,192.168.100.253
        dhcp-option=enp3s0,option:router,192.168.101.253
        dhcp-option=enp3s0,option:dns-server,192.168.101.253
        dhcp-option=enp4s0,option:router,192.168.102.253
        dhcp-option=enp4s0,option:dns-server,192.168.102.253
        dhcp-option=enp5s0,option:router,192.168.103.253
        dhcp-option=enp5s0,option:dns-server,192.168.103.253
        EOF
            ;;

          lockdown)
            cat >> /etc/dnsmasq.d/hydrix.conf << EOF
        interface=enp2s0
        interface=enp3s0
        interface=enp4s0
        interface=enp5s0
        interface=enp6s0
        dhcp-range=enp2s0,10.100.0.10,10.100.0.200,24h
        dhcp-range=enp3s0,10.100.1.10,10.100.1.200,24h
        dhcp-range=enp4s0,10.100.2.10,10.100.2.200,24h
        dhcp-range=enp5s0,10.100.3.10,10.100.3.200,24h
        dhcp-range=enp6s0,10.100.4.10,10.100.4.200,24h
        dhcp-option=enp2s0,option:router,10.100.0.253
        dhcp-option=enp2s0,option:dns-server,10.100.0.253
        dhcp-option=enp3s0,option:router,10.100.1.253
        dhcp-option=enp3s0,option:dns-server,10.100.1.253
        dhcp-option=enp4s0,option:router,10.100.2.253
        dhcp-option=enp4s0,option:dns-server,10.100.2.253
        dhcp-option=enp5s0,option:router,10.100.3.253
        dhcp-option=enp5s0,option:dns-server,10.100.3.253
        dhcp-option=enp6s0,option:router,10.100.4.253
        dhcp-option=enp6s0,option:dns-server,10.100.4.253
        EOF
            ;;
        esac
      '';
    };

    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = true;
      settings = {
        conf-dir = "/etc/dnsmasq.d/,*.conf";
      };
    };

    # nftables rules - dynamic based on mode
    systemd.services.router-firewall = {
      description = "Configure router firewall based on mode";
      after = [ "router-network-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        MODE=$(cat /var/lib/hydrix-router/mode 2>/dev/null || echo "standard")
        WAN="enp1s0"

        # Flush existing rules
        ${pkgs.nftables}/bin/nft flush ruleset 2>/dev/null || true

        case "$MODE" in
          standard)
            ${pkgs.nftables}/bin/nft -f - << 'EOF'
        table inet router {
          chain input {
            type filter hook input priority filter; policy drop;
            iif lo accept
            ct state established,related accept
            ip saddr { 192.168.100.0/24, 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24 } accept
            ip protocol icmp accept
          }

          chain forward {
            type filter hook forward priority filter; policy accept;
            ct state established,related accept
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "enp1s0" masquerade
          }
        }
        EOF
            ;;

          lockdown)
            # Get VPN interface names
            VPN_IFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(wg-|tun)' | tr '\n' ',' | sed 's/,$//')

            ${pkgs.nftables}/bin/nft -f - << EOF
        table inet router {
          chain prerouting {
            type filter hook prerouting priority mangle; policy accept;
            # Mark packets by source network
            ip saddr 10.100.1.0/24 meta mark set 100
            ip saddr 10.100.2.0/24 meta mark set 101
            ip saddr 10.100.3.0/24 meta mark set 102
            ip saddr 10.100.4.0/24 meta mark set 103
          }

          chain input {
            type filter hook input priority filter; policy drop;
            iif lo accept
            ct state established,related accept
            ip saddr { 10.100.0.0/24, 10.100.1.0/24, 10.100.2.0/24, 10.100.3.0/24, 10.100.4.0/24 } accept
            ip protocol icmp accept
          }

          chain forward {
            type filter hook forward priority filter; policy drop;
            ct state established,related accept

            # Management network: no forwarding to WAN
            ip saddr 10.100.0.0/24 drop

            # Block inter-VM traffic (isolation)
            ip saddr 10.100.1.0/24 ip daddr { 10.100.2.0/24, 10.100.3.0/24, 10.100.4.0/24 } drop
            ip saddr 10.100.2.0/24 ip daddr { 10.100.1.0/24, 10.100.3.0/24, 10.100.4.0/24 } drop
            ip saddr 10.100.3.0/24 ip daddr { 10.100.1.0/24, 10.100.2.0/24, 10.100.4.0/24 } drop
            ip saddr 10.100.4.0/24 ip daddr { 10.100.1.0/24, 10.100.2.0/24, 10.100.3.0/24 } drop

            # Allow traffic to VPN interfaces
            oifname "wg-*" accept
            oifname "tun*" accept

            # Allow marked traffic to WAN (for "direct" assignments)
            meta mark 103 oifname "enp1s0" accept
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "wg-*" masquerade
            oifname "tun*" masquerade
            oifname "enp1s0" masquerade
          }
        }
        EOF
            ;;
        esac

        echo "Firewall configured for $MODE mode"
      '';
    };

    # SSH
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = true;
        PermitRootLogin = "no";
      };
    };

    services.qemuGuest.enable = true;
    services.getty.autologinUser = "traum";

    users.users.traum = {
      isNormalUser = true;
      password = "ifEHbuuhSez9";
      extraGroups = [ "wheel" "networkmanager" ];
    };

    security.sudo.wheelNeedsPassword = false;

    # Packages
    environment.systemPackages = with pkgs; [
      wireguard-tools
      openvpn
      iproute2
      iptables
      nftables
      tcpdump
      nettools
      bind.dnsutils
      bridge-utils
      pciutils
      usbutils
      htop
      vim
      nano
      tmux
      git

      # VPN management scripts
      (writeShellScriptBin "vpn-assign" (builtins.readFile ../scripts/vpn-assign.sh))
      (writeShellScriptBin "vpn-status" (builtins.readFile ../scripts/vpn-status.sh))
    ];

    # Config directories
    systemd.tmpfiles.rules = [
      "d /etc/wireguard 0700 root root -"
      "d /etc/openvpn/client 0700 root root -"
      "d /var/lib/hydrix-vpn 0755 root root -"
      "d /var/lib/hydrix-router 0755 root root -"
      "d /etc/dnsmasq.d 0755 root root -"
    ];

    # Banner service
    systemd.services.router-banner = {
      description = "Display router status";
      wantedBy = [ "multi-user.target" ];
      after = [ "router-network-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        MODE=$(cat /var/lib/hydrix-router/mode 2>/dev/null || echo "unknown")
        echo ""
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║           HYDRIX ROUTER VM - $MODE MODE"
        echo "╠══════════════════════════════════════════════════════════╣"

        case "$MODE" in
          standard)
            echo "║  Networks: 192.168.100-104.x (simple NAT)               ║"
            ;;
          lockdown)
            echo "║  Networks: 10.100.0-4.x (VPN policy routing)            ║"
            echo "║  Commands: vpn-assign, vpn-status                       ║"
            ;;
        esac

        echo "╚══════════════════════════════════════════════════════════╝"
        echo ""
      '';
    };

    users.motd = ''

    ┌─────────────────────────────────────────────────┐
    │  Hydrix Router VM                               │
    │  Run 'vpn-status' for network status            │
    │  Run 'vpn-assign --help' for VPN routing        │
    └─────────────────────────────────────────────────┘

    '';
  };
}
