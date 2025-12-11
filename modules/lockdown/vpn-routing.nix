# VPN routing module for Router VM in lockdown mode
# Implements policy-based routing with kill switches for each bridge network
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.hydrix.vpnRouting;

  # Routing table IDs for each network
  routingTables = {
    pentest = 100;
    office = 101;
    browse = 102;
    dev = 103;
  };

  # Network to interface mapping (router-side interfaces)
  networkInterfaces = {
    pentest = "enp2s0";
    office = "enp3s0";
    browse = "enp4s0";
    dev = "enp5s0";
  };

  # Network subnets
  networkSubnets = {
    pentest = "10.100.1.0/24";
    office = "10.100.2.0/24";
    browse = "10.100.3.0/24";
    dev = "10.100.4.0/24";
    mgmt = "10.100.0.0/24";
  };

  # Generate WireGuard interface config
  mkWireguardInterface = name: vpnCfg: {
    "${name}" = {
      ips = [ "${vpnCfg.localAddress}/32" ];
      privateKeyFile = vpnCfg.privateKeyFile;
      listenPort = vpnCfg.listenPort or null;

      peers = [{
        publicKey = vpnCfg.peerPublicKey;
        endpoint = mkIf (vpnCfg.endpoint != null) vpnCfg.endpoint;
        allowedIPs = vpnCfg.allowedIPs or [ "0.0.0.0/0" ];
        persistentKeepalive = vpnCfg.keepalive or 25;
      }];
    };
  };

in {
  options.hydrix.vpnRouting = {
    enable = mkEnableOption "VPN-based policy routing for lockdown mode";

    wanInterface = mkOption {
      type = types.str;
      default = "enp1s0";
      description = "WAN interface (physical NIC or bridge to host's WAN)";
    };

    # VPN tunnel definitions
    vpnTunnels = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
          };
          type = mkOption {
            type = types.enum [ "wireguard" "openvpn" ];
            default = "wireguard";
          };
          # WireGuard options
          localAddress = mkOption {
            type = types.str;
            example = "10.0.0.2";
            description = "Local VPN IP address";
          };
          privateKeyFile = mkOption {
            type = types.path;
            example = "/etc/wireguard/private.key";
          };
          peerPublicKey = mkOption {
            type = types.str;
            description = "VPN server's public key";
          };
          endpoint = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "vpn.example.com:51820";
          };
          allowedIPs = mkOption {
            type = types.listOf types.str;
            default = [ "0.0.0.0/0" ];
          };
          keepalive = mkOption {
            type = types.int;
            default = 25;
          };
          listenPort = mkOption {
            type = types.nullOr types.int;
            default = null;
          };
          # OpenVPN options
          configFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "OpenVPN config file path";
          };
          # Common
          dnsServers = mkOption {
            type = types.listOf types.str;
            default = [ "1.1.1.1" "8.8.8.8" ];
          };
        };
      });
      default = {};
      description = "VPN tunnel definitions";
    };

    # Network to VPN assignments
    networkAssignments = mkOption {
      type = types.attrsOf (types.nullOr types.str);
      default = {
        pentest = null;   # No VPN by default (blocked)
        office = null;
        browse = null;
        dev = "direct";   # Direct WAN access
      };
      example = {
        pentest = "client-vpn";
        office = "corp-vpn";
        browse = "mullvad";
        dev = "direct";
      };
      description = ''
        Assign each network to a VPN tunnel.
        null = blocked (kill switch only)
        "direct" = direct WAN access
        "<vpn-name>" = route through that VPN
      '';
    };

    killSwitch = mkOption {
      type = types.bool;
      default = true;
      description = "Drop traffic if assigned VPN is down";
    };

    allowInterVmTraffic = mkOption {
      type = types.bool;
      default = false;
      description = "Allow traffic between different VM networks (breaks isolation)";
    };
  };

  config = mkIf cfg.enable {
    # Enable IP forwarding
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv4.conf.default.rp_filter" = 0;
      "net.ipv4.conf.all.rp_filter" = 0;
    };

    # Routing tables in /etc/iproute2/rt_tables
    environment.etc."iproute2/rt_tables".text = ''
      #
      # reserved values
      #
      255     local
      254     main
      253     default
      0       unspec
      #
      # Hydrix VPN routing tables
      #
      ${toString routingTables.pentest}     pentest
      ${toString routingTables.office}      office
      ${toString routingTables.browse}      browse
      ${toString routingTables.dev}         dev
    '';

    # WireGuard interfaces
    networking.wireguard.interfaces = mkMerge (
      mapAttrsToList (name: vpnCfg:
        mkIf (vpnCfg.enable && vpnCfg.type == "wireguard")
          (mkWireguardInterface name vpnCfg)
      ) cfg.vpnTunnels
    );

    # OpenVPN clients
    services.openvpn.servers = mkMerge (
      mapAttrsToList (name: vpnCfg:
        mkIf (vpnCfg.enable && vpnCfg.type == "openvpn" && vpnCfg.configFile != null) {
          "${name}" = {
            config = "config ${vpnCfg.configFile}";
            autoStart = false;  # Started on-demand by vpn-assign
          };
        }
      ) cfg.vpnTunnels
    );

    # NFTables for policy routing and kill switch
    networking.nftables = {
      enable = true;
      ruleset = ''
        table inet hydrix_router {
          # Chains for marking packets by source network
          chain prerouting {
            type filter hook prerouting priority mangle; policy accept;

            # Mark packets by source network for policy routing
            ip saddr ${networkSubnets.pentest} meta mark set ${toString routingTables.pentest}
            ip saddr ${networkSubnets.office} meta mark set ${toString routingTables.office}
            ip saddr ${networkSubnets.browse} meta mark set ${toString routingTables.browse}
            ip saddr ${networkSubnets.dev} meta mark set ${toString routingTables.dev}
          }

          chain forward {
            type filter hook forward priority filter; policy drop;

            # Allow established/related
            ct state established,related accept

            # Management network can reach router only, not forward
            ip saddr ${networkSubnets.mgmt} drop

            ${optionalString (!cfg.allowInterVmTraffic) ''
            # Block inter-VM traffic (isolation)
            ip saddr ${networkSubnets.pentest} ip daddr { ${networkSubnets.office}, ${networkSubnets.browse}, ${networkSubnets.dev} } drop
            ip saddr ${networkSubnets.office} ip daddr { ${networkSubnets.pentest}, ${networkSubnets.browse}, ${networkSubnets.dev} } drop
            ip saddr ${networkSubnets.browse} ip daddr { ${networkSubnets.pentest}, ${networkSubnets.office}, ${networkSubnets.dev} } drop
            ip saddr ${networkSubnets.dev} ip daddr { ${networkSubnets.pentest}, ${networkSubnets.office}, ${networkSubnets.browse} } drop
            ''}

            # Per-network forwarding rules (controlled by vpn-routing service)
            # These will be dynamically managed by systemd services
            # Default: accept if VPN interface exists for that mark

            # Pentest network
            meta mark ${toString routingTables.pentest} oifname "wg-*" accept
            meta mark ${toString routingTables.pentest} oifname "tun*" accept
            ${optionalString (cfg.networkAssignments.pentest == "direct") ''
            meta mark ${toString routingTables.pentest} oifname "${cfg.wanInterface}" accept
            ''}

            # Office network
            meta mark ${toString routingTables.office} oifname "wg-*" accept
            meta mark ${toString routingTables.office} oifname "tun*" accept
            ${optionalString (cfg.networkAssignments.office == "direct") ''
            meta mark ${toString routingTables.office} oifname "${cfg.wanInterface}" accept
            ''}

            # Browse network
            meta mark ${toString routingTables.browse} oifname "wg-*" accept
            meta mark ${toString routingTables.browse} oifname "tun*" accept
            ${optionalString (cfg.networkAssignments.browse == "direct") ''
            meta mark ${toString routingTables.browse} oifname "${cfg.wanInterface}" accept
            ''}

            # Dev network
            meta mark ${toString routingTables.dev} oifname "wg-*" accept
            meta mark ${toString routingTables.dev} oifname "tun*" accept
            ${optionalString (cfg.networkAssignments.dev == "direct") ''
            meta mark ${toString routingTables.dev} oifname "${cfg.wanInterface}" accept
            ''}
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;

            # NAT for each VPN interface
            ${concatMapStrings (vpnName: ''
            oifname "${vpnName}" masquerade
            '') (attrNames (filterAttrs (_: v: v.enable) cfg.vpnTunnels))}

            # NAT for direct WAN access
            oifname "${cfg.wanInterface}" masquerade
          }

          chain input {
            type filter hook input priority filter; policy drop;

            # Accept loopback
            iif lo accept

            # Accept established/related
            ct state established,related accept

            # Accept from all VM networks (for DNS, DHCP, management)
            ip saddr { ${networkSubnets.mgmt}, ${networkSubnets.pentest}, ${networkSubnets.office}, ${networkSubnets.browse}, ${networkSubnets.dev} } accept

            # Accept ICMP
            ip protocol icmp accept
          }
        }
      '';
    };

    # Firewall disabled (using nftables directly)
    networking.firewall.enable = false;

    # Policy routing rules (ip rules)
    systemd.services.vpn-policy-routing = {
      description = "Set up VPN policy routing rules";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Clean up existing rules
        ${pkgs.iproute2}/bin/ip rule del fwmark ${toString routingTables.pentest} table pentest 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip rule del fwmark ${toString routingTables.office} table office 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip rule del fwmark ${toString routingTables.browse} table browse 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip rule del fwmark ${toString routingTables.dev} table dev 2>/dev/null || true

        # Add policy routing rules (packets marked with fwmark use corresponding table)
        ${pkgs.iproute2}/bin/ip rule add fwmark ${toString routingTables.pentest} table pentest priority 100
        ${pkgs.iproute2}/bin/ip rule add fwmark ${toString routingTables.office} table office priority 101
        ${pkgs.iproute2}/bin/ip rule add fwmark ${toString routingTables.browse} table browse priority 102
        ${pkgs.iproute2}/bin/ip rule add fwmark ${toString routingTables.dev} table dev priority 103

        echo "Policy routing rules configured"
      '';
    };

    # VPN assignment state directory
    systemd.tmpfiles.rules = [
      "d /var/lib/hydrix-vpn 0755 root root -"
      "f /var/lib/hydrix-vpn/pentest.assignment 0644 root root - ${cfg.networkAssignments.pentest or "blocked"}"
      "f /var/lib/hydrix-vpn/office.assignment 0644 root root - ${cfg.networkAssignments.office or "blocked"}"
      "f /var/lib/hydrix-vpn/browse.assignment 0644 root root - ${cfg.networkAssignments.browse or "blocked"}"
      "f /var/lib/hydrix-vpn/dev.assignment 0644 root root - ${cfg.networkAssignments.dev or "direct"}"
    ];

    # Management packages
    environment.systemPackages = with pkgs; [
      wireguard-tools
      openvpn
      iproute2
      nftables
      tcpdump
      bind.dnsutils
    ];
  };
}
