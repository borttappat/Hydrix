# MicroVM Router Module - Declarative router VM using microvm.nix
#
# This is a microvm.nix-based replacement for the libvirt router VM.
# Key differences from other microVMs:
#   - Multiple TAP interfaces (one per bridge) + WiFi PCI passthrough
#   - No graphical modules (headless)
#   - Network services (dnsmasq, nftables, NetworkManager)
#
# Usage:
#   1. Enable in user's machine config:
#      hydrix.microvmHost.vms.microvm-router.enable = true;
#   2. Rebuild host: rebuild
#   3. Start microvm router: microvm start microvm-router
#
# Non-destructive testing:
#   - The libvirt "router" VM and microvm "microvm-router" can coexist
#   - Only ONE should run at a time (both need the WiFi card)
#   - To revert: stop microvm-router, start libvirt router
#
{ config, lib, pkgs, modulesPath, ... }:

let
  # Access central options
  cfg = config.hydrix;
  locale = cfg.locale;
  routerCfg = cfg.router;
  vpnCfg = routerCfg.vpn;

  # QEMU without seccomp support - disables sandbox mode for VFIO passthrough
  qemuNoSeccomp = pkgs.qemu_kvm.overrideAttrs (old: {
    configureFlags = lib.filter (f: f != "--enable-seccomp") (old.configureFlags or []);
    buildInputs = lib.filter (p: p.pname or "" != "libseccomp") (old.buildInputs or []);
  });

  # Router user from options
  routerUser = routerCfg.username;
  routerHashedPassword = routerCfg.hashedPassword;

  # WiFi networks for automatic connection (supports multiple networks)
  # New format: wifiNetworks = [ { ssid = "..."; password = "..."; priority = 100; } ]
  # Legacy format: wifiSSID + wifiPassword (converted to single-network list)
  wifiNetworks =
    let
      newFormat = routerCfg.wifi.networks;
      legacySSID = routerCfg.wifi.ssid;
      legacyPassword = routerCfg.wifi.password;
      legacyNetwork = if legacySSID != "" && legacyPassword != ""
        then [{ ssid = legacySSID; password = legacyPassword; priority = 100; }]
        else [];
    in
      if newFormat != [] then newFormat else legacyNetwork;
  hasWifiCredentials = wifiNetworks != [];

  # WiFi PCI address from hardware options
  wifiPciAddress = cfg.hardware.vfio.wifiPciAddress;

  # Mullvad VPN configuration from options
  hasMullvad = vpnCfg.mullvad.enable && vpnCfg.mullvad.privateKey != "";

  # Generate WireGuard config content for a Mullvad exit node
  mkMullvadConfig = name: node: ''
    [Interface]
    PrivateKey = ${vpnCfg.mullvad.privateKey}
    Address = ${vpnCfg.mullvad.address}
    DNS = 10.64.0.1

    [Peer]
    PublicKey = ${node.publicKey}
    Endpoint = ${node.server}:51820
    AllowedIPs = 0.0.0.0/0
    PersistentKeepalive = 25
  '';

  vmName = config.networking.hostName;

in {
  imports = [
    # Central options for config access
    ../options.nix
    # QEMU Guest profile for virtio modules
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # ===== MicroVM Router Options =====
  options.hydrix.microvm.router = {
    wifiPciId = lib.mkOption {
      type = lib.types.str;
      default = "8086:a840";
      description = "PCI vendor:device ID of WiFi card";
    };
  };

  config = {
    assertions = [{
      assertion = wifiPciAddress != "";
      message = ''
        hydrix.hardware.vfio.wifiPciAddress is empty — the router VM needs a WiFi PCI
        address for VFIO passthrough. Pass wifiPciAddress to mkMicrovmRouter in your flake:

          "microvm-router" = hydrix.lib.mkMicrovmRouter {
            wifiPciAddress = "00:14.3";  # from: lspci -D | grep -i wireless
          };

        The address should be in XX:XX.X format (without the 0000: domain prefix).
      '';
    }];

    # ===== Basic Identity =====
    networking.hostName = lib.mkDefault "microvm-router";
    system.stateVersion = "25.05";
    nixpkgs.config.allowUnfree = true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== MicroVM Configuration =====
    microvm = {
      hypervisor = "qemu";
      qemu.machine = "q35";  # Q35 chipset - better PCIe/VFIO support (matches libvirt router)
      qemu.package = qemuNoSeccomp;  # QEMU without seccomp - disables sandbox for VFIO

      # Resources - router is lightweight
      vcpu = 2;
      mem = 1024;  # 1GB should be plenty

      # No store disk - we'll use virtiofs like other microvms
      storeDiskType = "squashfs";
      writableStoreOverlay = "/nix/.rw-store";

      # Headless - no graphics
      graphics.enable = false;

      # ===== Network Interfaces =====
      # Primary TAP interface (br-mgmt) - defined in microvm.interfaces
      # (additional TAPs added via qemu.extraArgs below)
      interfaces = [{
        type = "tap";
        id = "mv-router-mgmt";
        mac = "02:00:00:01:00:01";  # Static MAC for router management
      }];

      # ===== Additional Network Interfaces + PCI Passthrough =====
      # Added via qemu.extraArgs for proper control over device ordering
      qemu.extraArgs = [
        # Headless flags
        "-vga" "none"
        "-display" "none"

        # Additional serial console via unix socket for interactive access
        # Connect with: socat -,rawer unix-connect:/var/lib/microvms/${config.networking.hostName}/console.sock
        "-chardev" "socket,id=console,path=/var/lib/microvms/${config.networking.hostName}/console.sock,server=on,wait=off"
        "-serial" "chardev:console"

        # PCIe root port for VFIO passthrough (required for Q35)
        "-device" "pcie-root-port,id=pcie.1,slot=1,chassis=1"
        # WiFi PCI passthrough via VFIO - attached to PCIe root port
        # Strip "0000:" prefix if user provided full format (handles both "00:14.3" and "0000:00:14.3")
        "-device" "vfio-pci,host=0000:${lib.removePrefix "0000:" wifiPciAddress},bus=pcie.1"

        # Additional TAP interfaces for each bridge
        # TAP interfaces created by host-side systemd service
        "-netdev" "tap,id=net-pentest,ifname=mv-router-pent,script=no,downscript=no"
        "-device" "virtio-net-pci,netdev=net-pentest,mac=02:00:00:01:01:01"

        "-netdev" "tap,id=net-comms,ifname=mv-router-comm,script=no,downscript=no"
        "-device" "virtio-net-pci,netdev=net-comms,mac=02:00:00:01:02:01"

        "-netdev" "tap,id=net-browse,ifname=mv-router-brow,script=no,downscript=no"
        "-device" "virtio-net-pci,netdev=net-browse,mac=02:00:00:01:03:01"

        "-netdev" "tap,id=net-dev,ifname=mv-router-dev,script=no,downscript=no"
        "-device" "virtio-net-pci,netdev=net-dev,mac=02:00:00:01:04:01"

        "-netdev" "tap,id=net-shared,ifname=mv-router-shar,script=no,downscript=no"
        "-device" "virtio-net-pci,netdev=net-shared,mac=02:00:00:01:05:01"

        "-netdev" "tap,id=net-builder,ifname=mv-router-bldr,script=no,downscript=no"
        "-device" "virtio-net-pci,netdev=net-builder,mac=02:00:00:01:06:01"

        "-netdev" "tap,id=net-lurking,ifname=mv-router-lurk,script=no,downscript=no"
        "-device" "virtio-net-pci,netdev=net-lurking,mac=02:00:00:01:07:01"

        "-netdev" "tap,id=net-files,ifname=mv-router-file,script=no,downscript=no"
        "-device" "virtio-net-pci,netdev=net-files,mac=02:00:00:01:08:01"
      ];

      # ===== Shared Filesystems =====
      shares = [
        # Share host /nix/store via virtiofs
        {
          tag = "nix-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          proto = "virtiofs";
        }
        # Router config directory (for persistent VPN state, etc.)
        {
          tag = "router-config";
          source = "/var/lib/microvms/${vmName}/config";
          mountPoint = "/mnt/router-config";
          proto = "9p";
        }
      ];

      # ===== Persistent Volume for /var/lib =====
      # Stores VPN assignments, dnsmasq leases, etc.
      volumes = [{
        image = "/var/lib/microvms/${vmName}/var-lib.qcow2";
        mountPoint = "/var/lib";
        size = 512;  # 512MB for router state
        autoCreate = true;
      }];

      # ===== Vsock (not used but required by schema) =====
      vsock.cid = 200;  # High CID to avoid conflicts with other microvms
    };

    # ===== Disable auto-optimise-store =====
    nix.settings.auto-optimise-store = lib.mkForce false;

    # ===== Kernel Configuration =====
    boot.initrd.availableKernelModules = [
      "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
      "virtio_net" "virtio_scsi" "virtio_mmio"
      "squashfs"
    ];

    boot.kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "random.trust_cpu=on"
      # Debug: verbose module and firmware loading
      "dyndbg=\"module iwlwifi +p\""
      "dyndbg=\"module cfg80211 +p\""
    ];

    # Use latest kernel for best iwlwifi/WiFi support (matches libvirt router)
    boot.kernelPackages = pkgs.linuxPackages_latest;

    boot.kernelModules = [
      "virtio_blk"
      "virtio_pci"
      "virtio_rng"
      # WiFi modules for Intel AX211
      "iwlwifi"
      "iwlmvm"
      "cfg80211"
      "mac80211"
    ];

    # ===== Firmware for WiFi =====
    hardware.enableAllFirmware = true;
    hardware.enableRedistributableFirmware = true;

    # ===== Networking Configuration =====
    networking = {
      useDHCP = false;
      enableIPv6 = false;

      # NetworkManager for WiFi management
      networkmanager = {
        enable = true;
        wifi.powersave = false;  # Prevent missed broadcast ARP replies
        # Store connections in /var/lib (persistent qcow2) instead of /etc (read-only squashfs)
        settings = {
          keyfile.path = "/var/lib/NetworkManager/system-connections";
        };
        ensureProfiles = lib.mkIf hasWifiCredentials {
          profiles = builtins.listToAttrs (map (network: {
            name = network.ssid;
            value = {
              connection = {
                id = network.ssid;
                type = "wifi";
                autoconnect = "true";
                autoconnect-priority = toString (network.priority or 50);
              };
              wifi = {
                mode = "infrastructure";
                ssid = network.ssid;
              };
              wifi-security = {
                key-mgmt = "wpa-psk";
                psk = network.password;
              };
              ipv4.method = "auto";
              ipv6.method = "disabled";
            };
          }) wifiNetworks);
        };
      };
      wireless.enable = false;  # NetworkManager handles WiFi
      firewall.enable = false;  # We use nftables directly
    };

    # ===== IP Forwarding and Kernel Hardening =====
    boot.kernel.sysctl = {
      # Routing (required)
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv4.conf.default.rp_filter" = 0;  # Required for policy routing
      "net.ipv4.conf.all.rp_filter" = 0;

      # ICMP Hardening
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

      # TCP Hardening
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.tcp_rfc1337" = 1;

      # Routing Security
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv4.conf.all.secure_redirects" = 0;

      # Logging
      "net.ipv4.conf.all.log_martians" = 1;
    };

    # ===== Routing Tables for VPN Policy Routing =====
    # Merged with Mullvad configs below using lib.mkMerge
    environment.etc = lib.mkMerge [
      {
        "iproute2/rt_tables".text = ''
          255     local
          254     main
          253     default
          0       unspec
          # Hydrix VPN routing tables
          100     pentest
          101     comms
          102     browse
          103     dev
          104     lurking
        '';
      }
      # Mullvad WireGuard configs (if available)
      (lib.mkIf hasMullvad (
        lib.mapAttrs' (name: node: {
          name = "wireguard/mullvad-${name}.conf";
          value = {
            text = mkMullvadConfig name node;
            mode = "0600";
          };
        }) vpnCfg.mullvad.exitNodes
      ))
    ];

    # ===== Network Setup Service =====
    # Configures IPs on all interfaces and detects WAN
    systemd.services.router-network-setup = {
      description = "Configure router networking";
      after = [ "network.target" "local-fs.target" "systemd-tmpfiles-setup.service" ];
      before = [ "dnsmasq.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.coreutils pkgs.gnugrep pkgs.iproute2 pkgs.networkmanager ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        #!/bin/bash
        # Don't use set -e - we want to continue even if some commands fail

        STATE_DIR="/var/lib/hydrix-router"
        mkdir -p "$STATE_DIR"

        echo "=== Network Setup Starting ==="
        echo "Available interfaces:"
        ls -la /sys/class/net/ || true

        # Find interface by MAC address
        find_iface_by_mac() {
          local target_mac="$1"
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            if [[ -f "/sys/class/net/$iface/address" ]]; then
              local mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
              if [[ "$mac" == "$target_mac" ]]; then
                echo "$iface"
                return
              fi
            fi
          done
          echo ""
        }

        # Detect WAN interface (WiFi passthrough)
        detect_wan() {
          # First, look for wireless interfaces (wlp*, wlan*)
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            if [[ "$iface" == wl* ]]; then
              echo "$iface"
              return
            fi
          done
          # Check if /sys/class/net/*/wireless exists
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            if [[ -d "/sys/class/net/$iface/wireless" ]]; then
              echo "$iface"
              return
            fi
          done
          echo ""
        }

        # Wait for WiFi interface to appear (VFIO passthrough takes time)
        echo "Waiting for WiFi interface..."
        for i in $(seq 1 30); do
          WAN_IFACE=$(detect_wan)
          if [[ -n "$WAN_IFACE" ]]; then
            break
          fi
          echo "  ... waiting ($i/30)"
          sleep 1
        done

        if [[ -z "$WAN_IFACE" ]]; then
          echo "WARNING: No WiFi interface detected! Check VFIO passthrough."
          echo "Available interfaces:"
          ${pkgs.iproute2}/bin/ip link show
          WAN_IFACE="none"
        else
          echo "Detected WAN interface: $WAN_IFACE"
        fi

        echo "$WAN_IFACE" > "$STATE_DIR/wan_interface"
        echo "standard" > "$STATE_DIR/mode"

        # NetworkManager handles WiFi connection
        if [[ "$WAN_IFACE" != "none" && "$WAN_IFACE" == wl* ]]; then
          echo "WAN is WiFi - NetworkManager will handle connection"
          for i in $(seq 1 60); do
            if ${pkgs.networkmanager}/bin/nmcli device show "$WAN_IFACE" 2>/dev/null | grep -q "connected"; then
              echo "WiFi connected via NetworkManager"
              break
            fi
            echo "  Waiting for WiFi connection ($i/60)..."
            sleep 1
          done
        fi

        # Map interfaces by MAC address
        # MAC addresses from microvm-router.nix qemu.extraArgs:
        IFACE_MGMT=$(find_iface_by_mac "02:00:00:01:00:01")    # mv-router-mgmt
        IFACE_PENT=$(find_iface_by_mac "02:00:00:01:01:01")    # mv-router-pent
        IFACE_COMM=$(find_iface_by_mac "02:00:00:01:02:01")    # mv-router-comm
        IFACE_BROW=$(find_iface_by_mac "02:00:00:01:03:01")    # mv-router-brow
        IFACE_DEV=$(find_iface_by_mac "02:00:00:01:04:01")     # mv-router-dev
        IFACE_SHAR=$(find_iface_by_mac "02:00:00:01:05:01")    # mv-router-shar
        IFACE_BLDR=$(find_iface_by_mac "02:00:00:01:06:01")    # mv-router-bldr
        IFACE_LURK=$(find_iface_by_mac "02:00:00:01:07:01")    # mv-router-lurk
        IFACE_FILE=$(find_iface_by_mac "02:00:00:01:08:01")    # mv-router-file

        echo "Detected LAN interfaces:"
        echo "  MGMT: $IFACE_MGMT"
        echo "  PENT: $IFACE_PENT"
        echo "  COMM: $IFACE_COMM"
        echo "  BROW: $IFACE_BROW"
        echo "  DEV:  $IFACE_DEV"
        echo "  SHAR: $IFACE_SHAR"
        echo "  BLDR: $IFACE_BLDR"
        echo "  LURK: $IFACE_LURK"
        echo "  FILE: $IFACE_FILE"

        # Save interface mapping for dnsmasq and firewall
        echo "IFACE_MGMT=$IFACE_MGMT" > "$STATE_DIR/interfaces"
        echo "IFACE_PENT=$IFACE_PENT" >> "$STATE_DIR/interfaces"
        echo "IFACE_COMM=$IFACE_COMM" >> "$STATE_DIR/interfaces"
        echo "IFACE_BROW=$IFACE_BROW" >> "$STATE_DIR/interfaces"
        echo "IFACE_DEV=$IFACE_DEV" >> "$STATE_DIR/interfaces"
        echo "IFACE_SHAR=$IFACE_SHAR" >> "$STATE_DIR/interfaces"
        echo "IFACE_BLDR=$IFACE_BLDR" >> "$STATE_DIR/interfaces"
        echo "IFACE_LURK=$IFACE_LURK" >> "$STATE_DIR/interfaces"
        echo "IFACE_FILE=$IFACE_FILE" >> "$STATE_DIR/interfaces"

        # Configure each LAN interface
        configure_lan() {
          local iface="$1"
          local ip="$2"
          local name="$3"
          if [[ -n "$iface" ]]; then
            echo "Configuring $name ($iface) with IP $ip"
            ${pkgs.networkmanager}/bin/nmcli device set "$iface" managed no 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip link set "$iface" up 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip addr add "$ip/24" dev "$iface" 2>/dev/null || true
          else
            echo "WARNING: $name interface not found!"
          fi
        }

        configure_lan "$IFACE_MGMT" "192.168.100.253" "mgmt"
        configure_lan "$IFACE_PENT" "192.168.101.253" "pentest"
        configure_lan "$IFACE_COMM" "192.168.102.253" "comms"
        configure_lan "$IFACE_BROW" "192.168.103.253" "browse"
        configure_lan "$IFACE_DEV"  "192.168.104.253" "dev"
        configure_lan "$IFACE_SHAR" "192.168.105.253" "shared"
        configure_lan "$IFACE_BLDR" "192.168.106.253" "builder"
        configure_lan "$IFACE_LURK" "192.168.107.253" "lurking"
        configure_lan "$IFACE_FILE" "192.168.108.253" "files"

        echo "=== Network Setup Complete ==="
        echo "WAN: $WAN_IFACE"
        ${pkgs.iproute2}/bin/ip addr show
      '';
    };

    # ===== Dynamic dnsmasq Configuration =====
    systemd.services.dnsmasq-config = {
      description = "Generate dnsmasq config based on detected interfaces";
      after = [ "router-network-setup.service" ];
      before = [ "dnsmasq.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /etc/dnsmasq.d

        # Load detected interface names
        source /var/lib/hydrix-router/interfaces 2>/dev/null || true

        echo "Generating dnsmasq config with interfaces:"
        echo "  MGMT=$IFACE_MGMT PENT=$IFACE_PENT COMM=$IFACE_COMM"
        echo "  BROW=$IFACE_BROW DEV=$IFACE_DEV SHAR=$IFACE_SHAR LURK=$IFACE_LURK FILE=$IFACE_FILE"

        # Generate config only for interfaces that exist
        echo "bind-interfaces" > /etc/dnsmasq.d/hydrix.conf
        echo "log-dhcp" >> /etc/dnsmasq.d/hydrix.conf
        echo "server=1.1.1.1" >> /etc/dnsmasq.d/hydrix.conf
        echo "server=8.8.8.8" >> /etc/dnsmasq.d/hydrix.conf

        # Add each interface if it exists
        add_iface() {
          local iface="$1"
          local subnet="$2"
          local router_ip="$3"
          if [[ -n "$iface" && -e "/sys/class/net/$iface" ]]; then
            echo "interface=$iface" >> /etc/dnsmasq.d/hydrix.conf
            echo "dhcp-range=$iface,$subnet.10,$subnet.200,24h" >> /etc/dnsmasq.d/hydrix.conf
            echo "dhcp-option=$iface,option:router,$router_ip" >> /etc/dnsmasq.d/hydrix.conf
            echo "dhcp-option=$iface,option:dns-server,$router_ip" >> /etc/dnsmasq.d/hydrix.conf
            echo "Added interface $iface for subnet $subnet.0/24"
          else
            echo "Skipping interface $iface (not found)"
          fi
        }

        add_iface "$IFACE_MGMT" "192.168.100" "192.168.100.253"
        add_iface "$IFACE_PENT" "192.168.101" "192.168.101.253"
        add_iface "$IFACE_COMM" "192.168.102" "192.168.102.253"
        add_iface "$IFACE_BROW" "192.168.103" "192.168.103.253"
        add_iface "$IFACE_DEV"  "192.168.104" "192.168.104.253"
        add_iface "$IFACE_SHAR" "192.168.105" "192.168.105.253"
        add_iface "$IFACE_BLDR" "192.168.106" "192.168.106.253"
        add_iface "$IFACE_LURK" "192.168.107" "192.168.107.253"
        add_iface "$IFACE_FILE" "192.168.108" "192.168.108.253"

        echo "Generated dnsmasq config:"
        cat /etc/dnsmasq.d/hydrix.conf
      '';
    };

    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = true;
      settings = {
        conf-dir = "/etc/dnsmasq.d/,*.conf";
      };
    };

    # ===== Firewall Configuration =====
    # SECURITY: Router is hardened to only provide routing services
    # - VMs can only use DHCP (67-68) and DNS (53) on the router
    # - SSH is disabled entirely (services.openssh.enable = false)
    # - No other services are accessible from VM networks
    # - Host manages router via console only (vsock/serial)
    systemd.services.router-firewall = {
      description = "Configure router firewall";
      after = [ "router-network-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        WAN=$(cat /var/lib/hydrix-router/wan_interface 2>/dev/null || echo "eth0")
        echo "Configuring hardened firewall (WAN: $WAN)"

        ${pkgs.nftables}/bin/nft flush ruleset 2>/dev/null || true

        # Define VM network ranges for clarity
        VM_NETWORKS="{ 192.168.100.0/24, 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24, 192.168.105.0/24, 192.168.106.0/24, 192.168.107.0/24, 192.168.108.0/24 }"

        ${pkgs.nftables}/bin/nft -f - << EOF
        table inet router {
          chain input {
            type filter hook input priority filter; policy drop;

            # Loopback always allowed
            iif lo accept

            # Allow established/related connections
            ct state established,related accept
            ct state invalid drop

            # ===== DHCP - Required for VM IP assignment =====
            # DHCP DISCOVER/REQUEST come from 0.0.0.0 (client has no IP yet)
            # so we can't filter by source IP - just allow DHCP on port 67
            udp dport 67 accept

            # ===== DNS - Required for name resolution =====
            # DNS queries from VMs (UDP and TCP)
            ip saddr $VM_NETWORKS udp dport 53 accept
            ip saddr $VM_NETWORKS tcp dport 53 accept

            # ===== ICMP - Rate limited for debugging =====
            ip saddr $VM_NETWORKS ip protocol icmp limit rate 10/second accept

            # ===== EVERYTHING ELSE FROM VMs IS DROPPED =====
            # This includes: SSH (22), HTTP (80/443), or any other service
            # VMs should only use router for routing, not as a server
            # Log and count dropped packets for debugging
            ip saddr $VM_NETWORKS counter log prefix "ROUTER-BLOCKED: " drop

            # Allow WAN interface traffic (replies, etc.)
            iifname "$WAN" accept
          }

          chain forward {
            type filter hook forward priority filter; policy drop;

            # Allow established/related
            ct state established,related accept
            ct state invalid drop

            # br-shared (192.168.105.0/24) allows inter-VM communication
            ip saddr 192.168.105.0/24 accept
            ip daddr 192.168.105.0/24 accept

            # Isolated bridges: block inter-bridge traffic
            # mgmt -> other isolated bridges
            ip saddr 192.168.100.0/24 ip daddr { 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24, 192.168.106.0/24, 192.168.107.0/24, 192.168.108.0/24 } drop
            # pentest -> other isolated bridges
            ip saddr 192.168.101.0/24 ip daddr { 192.168.100.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24, 192.168.106.0/24, 192.168.107.0/24, 192.168.108.0/24 } drop
            # comms -> other isolated bridges
            ip saddr 192.168.102.0/24 ip daddr { 192.168.100.0/24, 192.168.101.0/24, 192.168.103.0/24, 192.168.104.0/24, 192.168.106.0/24, 192.168.107.0/24, 192.168.108.0/24 } drop
            # browse -> other isolated bridges
            ip saddr 192.168.103.0/24 ip daddr { 192.168.100.0/24, 192.168.101.0/24, 192.168.102.0/24, 192.168.104.0/24, 192.168.106.0/24, 192.168.107.0/24, 192.168.108.0/24 } drop
            # dev -> other isolated bridges
            ip saddr 192.168.104.0/24 ip daddr { 192.168.100.0/24, 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.106.0/24, 192.168.107.0/24, 192.168.108.0/24 } drop
            # Builder is FULLY isolated - cannot reach any other VM network
            ip saddr 192.168.106.0/24 ip daddr { 192.168.100.0/24, 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24, 192.168.105.0/24, 192.168.107.0/24, 192.168.108.0/24 } drop
            # Lurking is FULLY isolated - maximum privacy, cannot reach any other VM network
            ip saddr 192.168.107.0/24 ip daddr { 192.168.100.0/24, 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24, 192.168.105.0/24, 192.168.106.0/24, 192.168.108.0/24 } drop
            # Files VM is FULLY isolated via router - it communicates directly via TAP interfaces
            ip saddr 192.168.108.0/24 ip daddr { 192.168.100.0/24, 192.168.101.0/24, 192.168.102.0/24, 192.168.103.0/24, 192.168.104.0/24, 192.168.105.0/24, 192.168.106.0/24, 192.168.107.0/24 } drop

            # Allow forwarding to WAN (external internet)
            oifname "$WAN" accept
            # Allow forwarding to VPN interfaces
            oifname "mullvad-*" accept
            oifname "wg-*" accept
            oifname "tun*" accept
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "$WAN" masquerade
            oifname "mullvad-*" masquerade
            oifname "wg-*" masquerade
            oifname "tun*" masquerade
          }
        }
        EOF

        echo "Hardened firewall configured:"
        echo "  - VMs can use: DHCP, DNS only"
        echo "  - VMs cannot: SSH, HTTP, or access any router services"
        echo "  - Inter-VM traffic: blocked (except br-shared)"
      '';
    };

    # ===== Services =====
    services.openssh.enable = false;  # No SSH - console only
    services.qemuGuest.enable = true;
    services.getty.autologinUser = routerUser;
    services.haveged.enable = true;

    # ===== User Configuration =====
    users.users.${routerUser} = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" ];
    } // (if routerHashedPassword != null
          then { hashedPassword = routerHashedPassword; }
          else { password = "router"; });

    security.sudo.wheelNeedsPassword = false;

    # ===== Packages =====
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
      dhcpcd
      iw
      wirelesstools
      networkmanager
      termshark
      bandwhich

      # VPN management scripts
      (writeShellScriptBin "vpn-assign" (builtins.readFile ../../scripts/vpn-assign.sh))
      (writeShellScriptBin "vpn-status" (builtins.readFile ../../scripts/vpn-status.sh))
    ];

    # ===== Tmpfiles =====
    systemd.tmpfiles.rules = [
      "d /etc/wireguard 0700 root root -"
      "d /etc/openvpn/client 0700 root root -"
      "d /var/lib/hydrix-vpn 0755 root root -"
      "d /var/lib/hydrix-router 0755 root root -"
      "d /etc/dnsmasq.d 0755 root root -"
    ];

    # ===== Locale =====
    time.timeZone = locale.timezone;
    i18n.defaultLocale = locale.language;
    console.keyMap = locale.consoleKeymap;

    # ===== MOTD =====
    users.motd = ''

    ┌─────────────────────────────────────────────────────┐
    │  Hydrix MicroVM Router (Serial Console Only)        │
    ├─────────────────────────────────────────────────────┤
    │  vpn-status           Network & VPN status          │
    │  vpn-assign --help    VPN routing commands          │
    └─────────────────────────────────────────────────────┘

    '';

    # ===== Banner =====
    systemd.services.router-banner = {
      description = "Display router status";
      wantedBy = [ "multi-user.target" ];
      after = [ "router-network-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo ""
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║           HYDRIX MICROVM ROUTER                          ║"
        echo "╠══════════════════════════════════════════════════════════╣"
        echo "║  Networks: 192.168.100-108.x                             ║"
        echo "╚══════════════════════════════════════════════════════════╝"
        echo ""
      '';
    };
  };
}
