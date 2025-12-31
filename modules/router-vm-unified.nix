# Unified Router VM Configuration
# Supports both standard mode (simple NAT) and lockdown mode (VPN policy routing)
#
# Build: nix build '.#router-vm'
# Deploy: Automatic via host specialisation autostart services
#
# Architecture:
#   - Host creates bridges: br-mgmt, br-pentest, br-office, br-browse, br-dev
#   - Router VM gets WiFi NIC via PCI passthrough (wlp* = WAN, auto-detected)
#   - Virtio interfaces (in virt-install order): enp1s0=mgmt, enp2s0=pentest, enp3s0=office, enp4s0=browse, enp5s0=dev
#
# Mode detection (automatic):
#   - Standard mode: Host has 192.168.100.1 on br-mgmt → router uses 192.168.x.x
#   - Lockdown mode: Host has 10.100.0.1 on br-mgmt → router uses 10.100.x.x with VPN routing
#
# WAN interface detection: Automatically finds wireless (wlp*) or first non-virtio interface
{ config, lib, pkgs, modulesPath, ... }:

with lib;

let
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
        - auto: Detect based on host's IP on management bridge
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
    # WireGuard is built into the kernel since 5.6, no external module needed
    boot.extraModulePackages = [ ];

    system.stateVersion = "25.05";

    # Enable all firmware for WiFi card support (especially iwlwifi for Intel WiFi)
    hardware.enableAllFirmware = true;
    hardware.enableRedistributableFirmware = true;

    networking = {
      hostName = "router-vm";
      useDHCP = false;
      enableIPv6 = false;
      # Use NetworkManager for WiFi - it automatically handles WiFi connections
      # This is much simpler than wpa_supplicant which requires manual config files
      networkmanager.enable = true;
      wireless.enable = false;  # Disable wpa_supplicant (NetworkManager handles WiFi)

      # WAN interface is detected dynamically at runtime by router-network-setup
      # It will be either wlp* (WiFi passthrough) or a physical ethernet device
      # NetworkManager will automatically connect to known WiFi networks

      firewall.enable = false;  # We use nftables directly
    };

    # IP forwarding - router handles all traffic
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv4.conf.default.rp_filter" = 0;
      "net.ipv4.conf.all.rp_filter" = 0;
    };

    # Routing tables for VPN policy routing (lockdown mode)
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
    # Router VM interfaces (virtio NICs added by virt-install in order):
    #   WAN = wlp* (WiFi passthrough) or other non-virtio interface, auto-detected
    #   enp1s0 = br-mgmt (first virtio)
    #   enp2s0 = br-pentest (second virtio) - isolated
    #   enp3s0 = br-office (third virtio) - isolated
    #   enp4s0 = br-browse (fourth virtio) - isolated
    #   enp5s0 = br-dev (fifth virtio) - isolated
    #   enp6s0 = br-shared (sixth virtio) - allows crosstalk between VMs
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

        # Detect WAN interface (WiFi passthrough or first non-virtio interface)
        detect_wan() {
          # First, look for wireless interfaces (wlp*, wlan*)
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            if [[ "$iface" == wl* ]]; then
              echo "$iface"
              return
            fi
          done

          # Fallback: find first interface that's not virtio (enp*) and not lo
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            if [[ "$iface" != "lo" && "$iface" != enp* ]]; then
              echo "$iface"
              return
            fi
          done

          # Last resort: check for any interface with carrier on physical device
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            if [[ -d "/sys/class/net/$iface/device" && "$iface" != enp* ]]; then
              echo "$iface"
              return
            fi
          done

          # Default fallback (shouldn't happen with proper passthrough)
          echo "eth0"
        }

        WAN_IFACE=$(detect_wan)
        echo "Detected WAN interface: $WAN_IFACE"
        echo "$WAN_IFACE" > "$STATE_DIR/wan_interface"

        # Mode detection: determine if we're in standard or lockdown mode
        # The systemd service that starts the VM uses different names:
        #   - router-vm = standard mode (192.168.x.x)
        #   - lockdown-router = lockdown mode (10.100.x.x)
        detect_mode() {
          # Method 1: Check hostname - set by libvirt from VM name
          if hostname | grep -qi "lockdown"; then
            echo "lockdown"
            return
          fi

          # Method 2: Check if we can detect host's IP on management bridge
          # Give network time to come up
          sleep 2

          # Bring up enp1s0 temporarily to check for host (this is mgmt bridge)
          ${pkgs.iproute2}/bin/ip link set enp1s0 up 2>/dev/null || true

          # Check for lockdown host IP (10.100.0.1)
          if ${pkgs.iproute2}/bin/ip neigh show dev enp1s0 2>/dev/null | grep -q "10.100.0.1"; then
            echo "lockdown"
            return
          fi

          # Try ARP ping to detect host IP
          if ${pkgs.iputils}/bin/arping -c 1 -I enp1s0 10.100.0.1 >/dev/null 2>&1; then
            echo "lockdown"
            return
          fi

          # Method 3: Check /etc/router-mode file (can be set by cloud-init or metadata)
          if [ -f /etc/router-mode ]; then
            cat /etc/router-mode
            return
          fi

          # Default to standard mode
          echo "standard"
        }

        MODE="${cfg.mode}"
        if [ "$MODE" = "auto" ]; then
          MODE=$(detect_mode)
        fi

        echo "Router mode: $MODE"
        echo "$MODE" > "$STATE_DIR/mode"

        # NetworkManager handles WiFi and DHCP automatically
        # Just mark the WAN interface as unmanaged for non-WiFi or let it manage WiFi
        if [[ "$WAN_IFACE" == wl* ]]; then
          echo "WAN is WiFi - NetworkManager will handle connection"
          # NetworkManager automatically connects to known networks
          # Wait for connection to establish
          for i in $(seq 1 60); do
            if ${pkgs.networkmanager}/bin/nmcli device show "$WAN_IFACE" 2>/dev/null | grep -q "connected"; then
              echo "WiFi connected via NetworkManager"
              break
            fi
            sleep 1
          done
        else
          echo "WAN is ethernet - bringing up manually"
          ${pkgs.iproute2}/bin/ip link set "$WAN_IFACE" up 2>/dev/null || true
          ${pkgs.dhcpcd}/bin/dhcpcd -b "$WAN_IFACE" 2>/dev/null || true
        fi

        # Bring up all LAN interfaces (virtio NICs in order)
        # Mark them as unmanaged by NetworkManager so we can configure them statically
        for iface in enp1s0 enp2s0 enp3s0 enp4s0 enp5s0 enp6s0; do
          ${pkgs.networkmanager}/bin/nmcli device set "$iface" managed no 2>/dev/null || true
          ${pkgs.iproute2}/bin/ip link set "$iface" up 2>/dev/null || true
        done

        case "$MODE" in
          standard)
            # Standard mode: 192.168.x.x networks
            ${pkgs.iproute2}/bin/ip addr add 192.168.100.253/24 dev enp1s0 2>/dev/null || true  # mgmt
            ${pkgs.iproute2}/bin/ip addr add 192.168.101.253/24 dev enp2s0 2>/dev/null || true  # pentest (isolated)
            ${pkgs.iproute2}/bin/ip addr add 192.168.102.253/24 dev enp3s0 2>/dev/null || true  # office (isolated)
            ${pkgs.iproute2}/bin/ip addr add 192.168.103.253/24 dev enp4s0 2>/dev/null || true  # browse (isolated)
            ${pkgs.iproute2}/bin/ip addr add 192.168.104.253/24 dev enp5s0 2>/dev/null || true  # dev (isolated)
            ${pkgs.iproute2}/bin/ip addr add 192.168.105.253/24 dev enp6s0 2>/dev/null || true  # shared (crosstalk)
            ;;

          lockdown)
            # Lockdown mode: 10.100.x.x isolated networks with VPN policy routing
            ${pkgs.iproute2}/bin/ip addr add 10.100.0.253/24 dev enp1s0 2>/dev/null || true  # mgmt
            ${pkgs.iproute2}/bin/ip addr add 10.100.1.253/24 dev enp2s0 2>/dev/null || true  # pentest (isolated)
            ${pkgs.iproute2}/bin/ip addr add 10.100.2.253/24 dev enp3s0 2>/dev/null || true  # office (isolated)
            ${pkgs.iproute2}/bin/ip addr add 10.100.3.253/24 dev enp4s0 2>/dev/null || true  # browse (isolated)
            ${pkgs.iproute2}/bin/ip addr add 10.100.4.253/24 dev enp5s0 2>/dev/null || true  # dev (isolated)
            ${pkgs.iproute2}/bin/ip addr add 10.100.5.253/24 dev enp6s0 2>/dev/null || true  # shared (crosstalk)

            # Set up policy routing rules for VPN routing
            ${pkgs.iproute2}/bin/ip rule del fwmark 100 table pentest 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip rule del fwmark 101 table office 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip rule del fwmark 102 table browse 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip rule del fwmark 103 table dev 2>/dev/null || true

            ${pkgs.iproute2}/bin/ip rule add fwmark 100 table pentest priority 100
            ${pkgs.iproute2}/bin/ip rule add fwmark 101 table office priority 101
            ${pkgs.iproute2}/bin/ip rule add fwmark 102 table browse priority 102
            ${pkgs.iproute2}/bin/ip rule add fwmark 103 table dev priority 103

            # Default dev network to direct WAN access
            WAN_GW=$(${pkgs.iproute2}/bin/ip route | grep "default.*$WAN_IFACE" | awk '{print $3}')
            if [ -n "$WAN_GW" ]; then
              ${pkgs.iproute2}/bin/ip route add default via "$WAN_GW" table dev 2>/dev/null || true
            fi

            # Initialize VPN assignment state (blocked by default for security)
            mkdir -p /var/lib/hydrix-vpn
            [ -f /var/lib/hydrix-vpn/pentest.assignment ] || echo "blocked" > /var/lib/hydrix-vpn/pentest.assignment
            [ -f /var/lib/hydrix-vpn/office.assignment ] || echo "blocked" > /var/lib/hydrix-vpn/office.assignment
            [ -f /var/lib/hydrix-vpn/browse.assignment ] || echo "blocked" > /var/lib/hydrix-vpn/browse.assignment
            [ -f /var/lib/hydrix-vpn/dev.assignment ] || echo "direct" > /var/lib/hydrix-vpn/dev.assignment
            ;;
        esac

        echo "Network setup complete for $MODE mode (WAN: $WAN_IFACE)"
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

        # Interface mapping (virtio NICs in virt-install order):
        #   enp1s0 = br-mgmt
        #   enp2s0 = br-pentest (isolated)
        #   enp3s0 = br-office (isolated)
        #   enp4s0 = br-browse (isolated)
        #   enp5s0 = br-dev (isolated)
        #   enp6s0 = br-shared (crosstalk allowed)

        case "$MODE" in
          standard)
            cat >> /etc/dnsmasq.d/hydrix.conf << EOF
        interface=enp1s0
        interface=enp2s0
        interface=enp3s0
        interface=enp4s0
        interface=enp5s0
        interface=enp6s0
        dhcp-range=enp1s0,192.168.100.10,192.168.100.200,24h
        dhcp-range=enp2s0,192.168.101.10,192.168.101.200,24h
        dhcp-range=enp3s0,192.168.102.10,192.168.102.200,24h
        dhcp-range=enp4s0,192.168.103.10,192.168.103.200,24h
        dhcp-range=enp5s0,192.168.104.10,192.168.104.200,24h
        dhcp-range=enp6s0,192.168.105.10,192.168.105.200,24h
        dhcp-option=enp1s0,option:router,192.168.100.253
        dhcp-option=enp1s0,option:dns-server,192.168.100.253
        dhcp-option=enp2s0,option:router,192.168.101.253
        dhcp-option=enp2s0,option:dns-server,192.168.101.253
        dhcp-option=enp3s0,option:router,192.168.102.253
        dhcp-option=enp3s0,option:dns-server,192.168.102.253
        dhcp-option=enp4s0,option:router,192.168.103.253
        dhcp-option=enp4s0,option:dns-server,192.168.103.253
        dhcp-option=enp5s0,option:router,192.168.104.253
        dhcp-option=enp5s0,option:dns-server,192.168.104.253
        dhcp-option=enp6s0,option:router,192.168.105.253
        dhcp-option=enp6s0,option:dns-server,192.168.105.253
        EOF
            ;;

          lockdown)
            cat >> /etc/dnsmasq.d/hydrix.conf << EOF
        interface=enp1s0
        interface=enp2s0
        interface=enp3s0
        interface=enp4s0
        interface=enp5s0
        interface=enp6s0
        dhcp-range=enp1s0,10.100.0.10,10.100.0.200,24h
        dhcp-range=enp2s0,10.100.1.10,10.100.1.200,24h
        dhcp-range=enp3s0,10.100.2.10,10.100.2.200,24h
        dhcp-range=enp4s0,10.100.3.10,10.100.3.200,24h
        dhcp-range=enp5s0,10.100.4.10,10.100.4.200,24h
        dhcp-range=enp6s0,10.100.5.10,10.100.5.200,24h
        dhcp-option=enp1s0,option:router,10.100.0.253
        dhcp-option=enp1s0,option:dns-server,10.100.0.253
        dhcp-option=enp2s0,option:router,10.100.1.253
        dhcp-option=enp2s0,option:dns-server,10.100.1.253
        dhcp-option=enp3s0,option:router,10.100.2.253
        dhcp-option=enp3s0,option:dns-server,10.100.2.253
        dhcp-option=enp4s0,option:router,10.100.3.253
        dhcp-option=enp4s0,option:dns-server,10.100.3.253
        dhcp-option=enp5s0,option:router,10.100.4.253
        dhcp-option=enp5s0,option:dns-server,10.100.4.253
        dhcp-option=enp6s0,option:router,10.100.5.253
        dhcp-option=enp6s0,option:dns-server,10.100.5.253
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
        WAN=$(cat /var/lib/hydrix-router/wan_interface 2>/dev/null || echo "eth0")

        echo "Configuring firewall for $MODE mode (WAN: $WAN)"

        # Flush existing rules
        ${pkgs.nftables}/bin/nft flush ruleset 2>/dev/null || true

        case "$MODE" in
          standard)
            ${pkgs.nftables}/bin/nft -f - << EOF
        table inet router {
          chain input {
            type filter hook input priority filter; policy drop;
            iif lo accept
            ct state established,related accept

            # Allow DHCP requests (from 0.0.0.0 and broadcast)
            udp dport 67 accept

            # Allow traffic from LAN networks (including br-shared)
            ip saddr { 192.168.100.0/24, 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24, 192.168.105.0/24 } accept
            ip protocol icmp accept
          }

          chain forward {
            type filter hook forward priority filter; policy drop;
            ct state established,related accept

            # br-shared (192.168.105.x) can talk to any network - allows crosstalk
            ip saddr 192.168.105.0/24 accept
            ip daddr 192.168.105.0/24 accept

            # Block host (br-mgmt 100) from reaching isolated bridges
            # Host can only reach br-shared (105) and router, not isolated VMs
            ip saddr 192.168.100.0/24 ip daddr { 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24 } drop

            # Block direct traffic between isolated bridges (pentest, office, browse, dev)
            # pentest (101) cannot reach office (102), browse (103), dev (104)
            ip saddr 192.168.101.0/24 ip daddr { 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24 } drop
            # office (102) cannot reach pentest (101), browse (103), dev (104)
            ip saddr 192.168.102.0/24 ip daddr { 192.168.101.0/24, 192.168.103.0/24, 192.168.104.0/24 } drop
            # browse (103) cannot reach pentest (101), office (102), dev (104)
            ip saddr 192.168.103.0/24 ip daddr { 192.168.101.0/24, 192.168.102.0/24, 192.168.104.0/24 } drop
            # dev (104) cannot reach pentest (101), office (102), browse (103)
            ip saddr 192.168.104.0/24 ip daddr { 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24 } drop

            # Allow all traffic to WAN (internet access)
            oifname "$WAN" accept
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "$WAN" masquerade
          }
        }
        EOF
            ;;

          lockdown)
            ${pkgs.nftables}/bin/nft -f - << EOF
        table inet router {
          chain prerouting {
            type filter hook prerouting priority mangle; policy accept;
            # Mark packets by source network (for VPN policy routing)
            ip saddr 10.100.1.0/24 meta mark set 100
            ip saddr 10.100.2.0/24 meta mark set 101
            ip saddr 10.100.3.0/24 meta mark set 102
            ip saddr 10.100.4.0/24 meta mark set 103
            # br-shared (10.100.5.x) gets same routing as dev (direct by default)
            ip saddr 10.100.5.0/24 meta mark set 103
          }

          chain input {
            type filter hook input priority filter; policy drop;
            iif lo accept
            ct state established,related accept

            # Allow DHCP requests (from 0.0.0.0 and broadcast)
            udp dport 67 accept

            # Allow traffic from LAN networks (including br-shared)
            ip saddr { 10.100.0.0/24, 10.100.1.0/24, 10.100.2.0/24, 10.100.3.0/24, 10.100.4.0/24, 10.100.5.0/24 } accept
            ip protocol icmp accept
          }

          chain forward {
            type filter hook forward priority filter; policy drop;
            ct state established,related accept

            # Management network: no forwarding to WAN
            ip saddr 10.100.0.0/24 drop

            # br-shared (10.100.5.x) can talk to any network - allows crosstalk
            ip saddr 10.100.5.0/24 accept
            ip daddr 10.100.5.0/24 accept

            # Block direct traffic between isolated bridges (pentest, office, browse, dev)
            ip saddr 10.100.1.0/24 ip daddr { 10.100.2.0/24, 10.100.3.0/24, 10.100.4.0/24 } drop
            ip saddr 10.100.2.0/24 ip daddr { 10.100.1.0/24, 10.100.3.0/24, 10.100.4.0/24 } drop
            ip saddr 10.100.3.0/24 ip daddr { 10.100.1.0/24, 10.100.2.0/24, 10.100.4.0/24 } drop
            ip saddr 10.100.4.0/24 ip daddr { 10.100.1.0/24, 10.100.2.0/24, 10.100.3.0/24 } drop

            # Allow traffic to VPN interfaces
            oifname "wg-*" accept
            oifname "tun*" accept

            # Allow marked traffic to WAN (for "direct" assignments)
            meta mark 103 oifname "$WAN" accept
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "wg-*" masquerade
            oifname "tun*" masquerade
            oifname "$WAN" masquerade
          }
        }
        EOF
            ;;
        esac

        echo "Firewall configured for $MODE mode (WAN: $WAN)"
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
      dhcpcd  # For dynamic WAN IP (though NetworkManager usually handles this)
      iw  # WiFi diagnostics
      wirelesstools  # Additional WiFi tools
      networkmanager  # Ensure nmcli is available

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
