# Isolated bridge network module for lockdown host
# Creates isolated bridges for each VM type with no host internet access
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.hydrix.lockdown;

  # Bridge definitions with their network segments
  bridgeDefinitions = {
    br-mgmt = {
      subnet = "10.100.0";
      description = "Management network (no internet, router management only)";
      routerInterface = "enp1s0";
    };
    br-pentest = {
      subnet = "10.100.1";
      description = "Pentest network (client VPN routing)";
      routerInterface = "enp2s0";
    };
    br-office = {
      subnet = "10.100.2";
      description = "Office network (corporate VPN routing)";
      routerInterface = "enp3s0";
    };
    br-browse = {
      subnet = "10.100.3";
      description = "Browsing network (privacy VPN routing)";
      routerInterface = "enp4s0";
    };
    br-dev = {
      subnet = "10.100.4";
      description = "Development network (configurable routing)";
      routerInterface = "enp5s0";
    };
  };

in {
  options.hydrix.lockdown = {
    enable = mkEnableOption "Hydrix lockdown mode with isolated bridges";

    bridges = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to enable this bridge";
          };
          subnet = mkOption {
            type = types.str;
            description = "Subnet prefix (e.g., 10.100.1 for 10.100.1.0/24)";
          };
        };
      });
      default = {
        br-wan = { enable = true; subnet = ""; };  # WAN bridge - no subnet, gets DHCP
        br-mgmt = { enable = true; subnet = "10.100.0"; };
        br-pentest = { enable = true; subnet = "10.100.1"; };
        br-office = { enable = true; subnet = "10.100.2"; };
        br-browse = { enable = true; subnet = "10.100.3"; };
        br-dev = { enable = true; subnet = "10.100.4"; };
      };
      description = "Bridge definitions for isolated networks";
    };

    wanBridgeInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "enp0s31f6";
      description = "Physical interface to add to br-wan (host's ethernet/wifi for router WAN)";
    };

    hostHasInternet = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the host should have internet access (false for full lockdown)";
    };

    wanInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "WAN interface name (if not using passthrough to router)";
    };

    passthroughPciAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0000:03:00.0";
      description = "PCI address of network card to pass through to router VM";
    };
  };

  config = mkIf cfg.enable {
    # Disable NetworkManager on host - we manage bridges manually
    networking.networkmanager.enable = mkForce false;

    # Enable systemd-networkd for bridge management
    systemd.network.enable = true;

    # Create bridge devices
    systemd.network.netdevs = mapAttrs' (name: bridgeCfg:
      nameValuePair "10-${name}" {
        netdevConfig = {
          Name = name;
          Kind = "bridge";
        };
        bridgeConfig = {
          STP = false;  # No spanning tree for isolated networks
          ForwardDelay = 0;
        };
      }
    ) (filterAttrs (_: b: b.enable) cfg.bridges);

    # Configure bridge networks - NO IP on host side (true isolation)
    systemd.network.networks = mapAttrs' (name: bridgeCfg:
      nameValuePair "20-${name}" {
        matchConfig.Name = name;
        networkConfig = {
          # Host gets NO IP on these bridges - only VMs and router have IPs
          # This prevents host from communicating on VM networks
          ConfigureWithoutCarrier = true;
          LinkLocalAddressing = "no";
        };
        linkConfig = {
          RequiredForOnline = "no";
        };
      }
    ) (filterAttrs (_: b: b.enable) cfg.bridges);

    # If we have a WAN interface, add it to br-wan bridge for router VM
    systemd.network.networks = mkMerge [
      (mkIf (cfg.wanBridgeInterface != null) {
        "10-wan-to-bridge" = {
          matchConfig.Name = cfg.wanBridgeInterface;
          networkConfig = {
            Bridge = "br-wan";
            LinkLocalAddressing = "no";
          };
        };
        # br-wan gets no IP on host - router VM will DHCP on it
        "20-br-wan" = {
          matchConfig.Name = "br-wan";
          networkConfig = {
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no";
            DHCP = "no";
          };
          linkConfig.RequiredForOnline = "no";
        };
      })
    ];

    # Firewall: Only allow libvirt and local services
    networking.firewall = {
      enable = true;
      # Trust all our isolated bridges for VM communication
      trustedInterfaces = (attrNames (filterAttrs (_: b: b.enable) cfg.bridges)) ++ [ "virbr0" ];

      # Host services only
      allowedTCPPorts = [
        22      # SSH (for emergency access)
        5900 5901 5902 5903 5904  # VNC/SPICE for VM displays
        16509   # libvirt
      ];
      allowedUDPPorts = [];

      # Block all forwarding from host - only router VM forwards
      extraCommands = ''
        # Drop any forwarding attempts from host
        iptables -P FORWARD DROP

        # Only allow established connections back to host
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
      '';
    };

    # Kernel parameters for bridge filtering
    boot.kernel.sysctl = {
      # Disable IP forwarding on host - router VM handles this
      "net.ipv4.ip_forward" = mkIf (!cfg.hostHasInternet) (mkForce 0);

      # Bridge netfilter settings
      "net.bridge.bridge-nf-call-iptables" = 0;
      "net.bridge.bridge-nf-call-ip6tables" = 0;
      "net.bridge.bridge-nf-call-arptables" = 0;
    };

    # Load bridge kernel module
    boot.kernelModules = [ "bridge" "br_netfilter" ];

    # Libvirt network definitions for each bridge
    environment.etc = mapAttrs' (name: bridgeCfg:
      nameValuePair "libvirt/qemu/networks/${name}.xml" {
        text = ''
          <network>
            <name>${name}</name>
            <forward mode="bridge"/>
            <bridge name="${name}"/>
          </network>
        '';
      }
    ) (filterAttrs (_: b: b.enable) cfg.bridges);

    # Script to activate libvirt networks on boot
    systemd.services.libvirt-lockdown-networks = {
      description = "Activate lockdown libvirt networks";
      after = [ "libvirtd.service" "systemd-networkd.service" ];
      wants = [ "libvirtd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        enabledBridges = attrNames (filterAttrs (_: b: b.enable) cfg.bridges);
      in ''
        # Wait for libvirtd to be ready
        sleep 2

        ${concatMapStrings (name: ''
          # Define and start ${name} network if not already
          if ! ${pkgs.libvirt}/bin/virsh net-info ${name} >/dev/null 2>&1; then
            ${pkgs.libvirt}/bin/virsh net-define /etc/libvirt/qemu/networks/${name}.xml || true
          fi
          ${pkgs.libvirt}/bin/virsh net-start ${name} 2>/dev/null || true
          ${pkgs.libvirt}/bin/virsh net-autostart ${name} 2>/dev/null || true
        '') enabledBridges}

        echo "Lockdown networks activated: ${concatStringsSep " " enabledBridges}"
      '';
    };

    # Packages for bridge management
    environment.systemPackages = with pkgs; [
      bridge-utils
      iproute2
      tcpdump  # For debugging
    ];
  };
}
