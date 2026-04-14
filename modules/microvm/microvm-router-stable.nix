# MicroVM Router Stable Module - Immutable fallback router
#
# Emergency router that auto-starts when the main router fails.
# Serves all the same bridges and subnets as the main router using
# separate TAP interfaces (mv-rts-*) so both can coexist in config.
#
# This module is intentionally minimal — no VPN, no wifi-sync. It is
# the "golden image" that should always work. Add features deliberately.
#
# TAP prefix:    mv-rts-* (router-stable)
# Framework MACs 02:00:00:03:XX:01
# Dynamic MACs   02:00:00:04:XX:01  (imap0 index across allNetworks)
# CID:           201
# Hostname:      microvm-router-stable
#
# Host-side wiring (microvm-host.nix):
#   microvm@microvm-router    → OnFailure=microvm@microvm-router-stable.service
#   microvm@microvm-router-stable → Conflicts=microvm@microvm-router.service
#   autostart = false  (starts only via OnFailure or manually)
#   added to infrastructureVMs (available in lockdown mode)
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  cfg = config.hydrix;
  locale = cfg.locale;
  routerCfg = cfg.router;

  # QEMU without seccomp — same as main router (needed for VFIO)
  qemuNoSeccomp = pkgs.qemu_kvm.overrideAttrs (old: {
    configureFlags = lib.filter (f: f != "--enable-seccomp") (old.configureFlags or []);
    buildInputs = lib.filter (p: p.pname or "" != "libseccomp") (old.buildInputs or []);
  });

  routerUser = routerCfg.username;
  routerHashedPassword = routerCfg.hashedPassword;

  wifiNetworks = let
    newFormat = routerCfg.wifi.networks;
    legacySSID = routerCfg.wifi.ssid;
    legacyPassword = routerCfg.wifi.password;
    legacyNetwork =
      if legacySSID != "" && legacyPassword != ""
      then [{ssid = legacySSID; password = legacyPassword; priority = 100;}]
      else [];
  in if newFormat != [] then newFormat else legacyNetwork;
  hasWifiCredentials = wifiNetworks != [];

  wifiPciAddress = cfg.hardware.vfio.wifiPciAddress;

  vmName = config.networking.hostName;
  extraNetworks = cfg.networking.extraNetworks;
  profileNetworks = cfg.networking.profileNetworks;
  allNetworks = profileNetworks ++ extraNetworks;

  # Derive stable TAP name from the profile's routerTap.
  # Convention: all routerTaps follow mv-router-<abbrev>; we substitute the prefix.
  # For any other format, fallback: prepend mv-rts- to the name.
  stableRouterTap = n:
    if lib.hasPrefix "mv-router-" n.routerTap
    then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
    else "mv-rts-${n.name}";
in {
  imports = [
    ../options.nix
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  config = {
    networking.hostName = lib.mkDefault "microvm-router-stable";
    system.stateVersion = "25.05";
    nixpkgs.config.allowUnfree = true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== MicroVM Configuration =====
    microvm = {
      hypervisor = "qemu";
      qemu.machine = "q35";
      qemu.package = qemuNoSeccomp;

      vcpu = 2;
      mem = 1024;

      storeDiskType = "squashfs";
      writableStoreOverlay = "/nix/.rw-store";
      graphics.enable = false;

      interfaces = [
        {
          type = "tap";
          id = "mv-rts-mgmt";
          mac = "02:00:00:03:00:01";
        }
      ];

      qemu.extraArgs =
        [
          "-vga" "none"
          "-display" "none"

          "-chardev"
          "socket,id=console,path=/var/lib/microvms/${vmName}/console.sock,server=on,wait=off"
          "-serial"
          "chardev:console"

          "-device" "pcie-root-port,id=pcie.1,slot=1,chassis=1"
          "-device"
          "vfio-pci,host=0000:${lib.removePrefix "0000:" wifiPciAddress},bus=pcie.1"

          # Framework TAPs — stable prefix mv-rts-* / MAC 02:00:00:03:XX:01
          "-netdev" "tap,id=net-pentest,ifname=mv-rts-pent,script=no,downscript=no"
          "-device" "virtio-net-pci,netdev=net-pentest,mac=02:00:00:03:01:01"

          "-netdev" "tap,id=net-comms,ifname=mv-rts-comm,script=no,downscript=no"
          "-device" "virtio-net-pci,netdev=net-comms,mac=02:00:00:03:02:01"

          "-netdev" "tap,id=net-browse,ifname=mv-rts-brow,script=no,downscript=no"
          "-device" "virtio-net-pci,netdev=net-browse,mac=02:00:00:03:03:01"

          "-netdev" "tap,id=net-dev,ifname=mv-rts-dev,script=no,downscript=no"
          "-device" "virtio-net-pci,netdev=net-dev,mac=02:00:00:03:04:01"

          "-netdev" "tap,id=net-shared,ifname=mv-rts-shar,script=no,downscript=no"
          "-device" "virtio-net-pci,netdev=net-shared,mac=02:00:00:03:05:01"

          "-netdev" "tap,id=net-builder,ifname=mv-rts-bldr,script=no,downscript=no"
          "-device" "virtio-net-pci,netdev=net-builder,mac=02:00:00:03:06:01"

          "-netdev" "tap,id=net-lurking,ifname=mv-rts-lurk,script=no,downscript=no"
          "-device" "virtio-net-pci,netdev=net-lurking,mac=02:00:00:03:07:01"

          "-netdev" "tap,id=net-files,ifname=mv-rts-file,script=no,downscript=no"
          "-device" "virtio-net-pci,netdev=net-files,mac=02:00:00:03:08:01"
        ]
        ++ lib.concatLists (lib.imap0 (i: n: [
            "-netdev"
            "tap,id=net-${n.name},ifname=${stableRouterTap n},script=no,downscript=no"
            "-device"
            "virtio-net-pci,netdev=net-${n.name},mac=02:00:00:04:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01"
          ])
          allNetworks);

      shares = [
        {
          tag = "nix-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          proto = "virtiofs";
        }
        {
          tag = "router-config";
          source = "/var/lib/microvms/${vmName}/config";
          mountPoint = "/mnt/router-config";
          proto = "9p";
        }
      ];

      volumes = [
        {
          image = "/var/lib/microvms/${vmName}/var-lib.qcow2";
          mountPoint = "/var/lib";
          size = 512;
          autoCreate = true;
        }
      ];

      vsock.cid = 201;
    };

    nix.settings.auto-optimise-store = lib.mkForce false;

    # ===== Kernel =====
    boot.initrd.availableKernelModules = [
      "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
      "virtio_net" "virtio_scsi" "virtio_mmio" "squashfs"
    ];

    boot.kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "random.trust_cpu=on"
    ];

    boot.kernelPackages = pkgs.linuxPackages_latest;

    boot.kernelModules = [
      "virtio_blk" "virtio_pci" "virtio_rng"
      "iwlwifi" "iwlmvm" "cfg80211" "mac80211"
    ];

    hardware.enableAllFirmware = true;
    hardware.enableRedistributableFirmware = true;

    # ===== Predictable Interface Naming =====
    # Rename virtio-net devices inside QEMU by MAC → stable TAP name.
    systemd.network.links = {
      "10-mv-rts-mgmt" = { matchConfig.MACAddress = "02:00:00:03:00:01"; linkConfig.Name = "mv-rts-mgmt"; };
      "10-mv-rts-pent" = { matchConfig.MACAddress = "02:00:00:03:01:01"; linkConfig.Name = "mv-rts-pent"; };
      "10-mv-rts-comm" = { matchConfig.MACAddress = "02:00:00:03:02:01"; linkConfig.Name = "mv-rts-comm"; };
      "10-mv-rts-brow" = { matchConfig.MACAddress = "02:00:00:03:03:01"; linkConfig.Name = "mv-rts-brow"; };
      "10-mv-rts-dev"  = { matchConfig.MACAddress = "02:00:00:03:04:01"; linkConfig.Name = "mv-rts-dev";  };
      "10-mv-rts-shar" = { matchConfig.MACAddress = "02:00:00:03:05:01"; linkConfig.Name = "mv-rts-shar"; };
      "10-mv-rts-bldr" = { matchConfig.MACAddress = "02:00:00:03:06:01"; linkConfig.Name = "mv-rts-bldr"; };
      "10-mv-rts-lurk" = { matchConfig.MACAddress = "02:00:00:03:07:01"; linkConfig.Name = "mv-rts-lurk"; };
      "10-mv-rts-file" = { matchConfig.MACAddress = "02:00:00:03:08:01"; linkConfig.Name = "mv-rts-file"; };
    } // lib.listToAttrs (lib.imap0 (i: n: {
      name  = "20-${stableRouterTap n}";
      value = {
        matchConfig.MACAddress = "02:00:00:04:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01";
        linkConfig.Name = stableRouterTap n;
      };
    }) allNetworks);

    # ===== Networking =====
    networking = {
      useDHCP = false;
      enableIPv6 = false;
      networkmanager = {
        enable = true;
        wifi.powersave = false;
        settings.keyfile.path = "/var/lib/NetworkManager/system-connections";
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
              wifi = {mode = "infrastructure"; ssid = network.ssid;};
              wifi-security = {key-mgmt = "wpa-psk"; psk = network.password;};
              ipv4.method = "auto";
              ipv6.method = "disabled";
            };
          }) wifiNetworks);
        };
      };
      wireless.enable = false;
      firewall.enable = false;
    };

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward"                     = 1;
      "net.ipv4.conf.all.forwarding"             = 1;
      "net.ipv4.conf.default.rp_filter"          = 0;
      "net.ipv4.conf.all.rp_filter"              = 0;
      "net.ipv4.icmp_echo_ignore_broadcasts"     = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
      "net.ipv4.tcp_syncookies"                  = 1;
      "net.ipv4.tcp_rfc1337"                     = 1;
      "net.ipv4.conf.all.accept_source_route"    = 0;
      "net.ipv4.conf.all.accept_redirects"       = 0;
      "net.ipv4.conf.all.send_redirects"         = 0;
      "net.ipv4.conf.all.log_martians"           = 1;
    };

    # ===== Network Setup =====
    systemd.services.router-network-setup = {
      description = "Configure stable router networking";
      after = ["network.target" "local-fs.target" "systemd-tmpfiles-setup.service"];
      before = ["dnsmasq.service" "network-online.target"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.coreutils pkgs.gnugrep pkgs.iproute2 pkgs.networkmanager];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        STATE_DIR="/var/lib/hydrix-router-stable"
        mkdir -p "$STATE_DIR"

        echo "=== Stable Router Network Setup ==="

        # Detect WAN (WiFi passthrough)
        detect_wan() {
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            [[ "$iface" == wl* ]] && { echo "$iface"; return; }
          done
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            [[ -d "/sys/class/net/$iface/wireless" ]] && { echo "$iface"; return; }
          done
          echo ""
        }

        echo "Waiting for WiFi interface..."
        for i in $(seq 1 30); do
          WAN_IFACE=$(detect_wan)
          [[ -n "$WAN_IFACE" ]] && break
          echo "  ... waiting ($i/30)"
          sleep 1
        done

        if [[ -z "$WAN_IFACE" ]]; then
          echo "WARNING: No WiFi interface detected"
          WAN_IFACE="none"
        else
          echo "Detected WAN: $WAN_IFACE"
        fi
        echo "$WAN_IFACE" > "$STATE_DIR/wan_interface"

        find_iface_by_name() {
          local name="$1"
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            [[ "$iface" == "$name" ]] && { echo "$iface"; return 0; }
          done
          return 1
        }

        # Framework infra interfaces (stable TAP names)
        IFACE_MGMT=$(find_iface_by_name "mv-rts-mgmt")
        IFACE_SHAR=$(find_iface_by_name "mv-rts-shar")
        IFACE_BLDR=$(find_iface_by_name "mv-rts-bldr")
        IFACE_FILE=$(find_iface_by_name "mv-rts-file")

        # Profile + extra network interfaces (derived from meta.nix routerTap)
        ${lib.concatStringsSep "\n        " (map (n: let
          varName = lib.toUpper (builtins.replaceStrings ["-"] ["_"] n.name);
          sTap = stableRouterTap n;
        in "IFACE_${varName}=$(find_iface_by_name \"${sTap}\")") allNetworks)}

        # Save for dnsmasq and firewall
        {
          echo "IFACE_MGMT=$IFACE_MGMT"
          ${lib.concatStringsSep "\n          " (map (n: let
            varName = lib.toUpper (builtins.replaceStrings ["-"] ["_"] n.name);
          in "echo \"IFACE_${varName}=$IFACE_${varName}\"") allNetworks)}
          echo "IFACE_SHAR=$IFACE_SHAR"
          echo "IFACE_BLDR=$IFACE_BLDR"
          echo "IFACE_FILE=$IFACE_FILE"
        } > "$STATE_DIR/interfaces"

        configure_lan() {
          local iface="$1" ip="$2" name="$3"
          if [[ -n "$iface" ]]; then
            echo "Configuring $name ($iface) → $ip"
            ${pkgs.networkmanager}/bin/nmcli device set "$iface" managed no 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip link set "$iface" up 2>/dev/null || true
            ${pkgs.iproute2}/bin/ip addr add "$ip/24" dev "$iface" 2>/dev/null || true
          else
            echo "WARNING: $name interface not found"
          fi
        }

        configure_lan "$IFACE_MGMT" "192.168.100.253" "mgmt"
        ${lib.concatStringsSep "\n        " (map (n: let
          varName = lib.toUpper (builtins.replaceStrings ["-"] ["_"] n.name);
        in "configure_lan \"$IFACE_${varName}\" \"${n.subnet}.253\" \"${n.name}\"") allNetworks)}
        configure_lan "$IFACE_SHAR" "192.168.105.253" "shared"
        configure_lan "$IFACE_BLDR" "192.168.106.253" "builder"
        configure_lan "$IFACE_FILE" "192.168.108.253" "files"

        echo "=== Stable Router Network Setup Complete ==="
      '';
    };

    # ===== dnsmasq =====
    systemd.services.dnsmasq-config = {
      description = "Generate dnsmasq config for stable router";
      after = ["router-network-setup.service"];
      before = ["dnsmasq.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {Type = "oneshot"; RemainAfterExit = true;};
      script = ''
        mkdir -p /etc/dnsmasq.d
        source /var/lib/hydrix-router-stable/interfaces 2>/dev/null || true

        {
          echo "bind-interfaces"
          echo "log-dhcp"
          echo "server=1.1.1.1"
          echo "server=8.8.8.8"
        } > /etc/dnsmasq.d/hydrix.conf

        add_iface() {
          local iface="$1" subnet="$2" router_ip="$3"
          if [[ -n "$iface" && -e "/sys/class/net/$iface" ]]; then
            echo "interface=$iface"
            echo "dhcp-range=$iface,$subnet.10,$subnet.200,24h"
            echo "dhcp-option=$iface,option:router,$router_ip"
            echo "dhcp-option=$iface,option:dns-server,$router_ip"
          fi
        } >> /etc/dnsmasq.d/hydrix.conf

        add_iface "$IFACE_MGMT" "192.168.100" "192.168.100.253"
        ${lib.concatStringsSep "\n        " (map (n: let
          varName = lib.toUpper (builtins.replaceStrings ["-"] ["_"] n.name);
        in "add_iface \"$IFACE_${varName}\" \"${n.subnet}\" \"${n.subnet}.253\"") allNetworks)}
        add_iface "$IFACE_SHAR" "192.168.105" "192.168.105.253"
        add_iface "$IFACE_BLDR" "192.168.106" "192.168.106.253"
        add_iface "$IFACE_FILE" "192.168.108" "192.168.108.253"
      '';
    };

    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = true;
      settings.conf-dir = "/etc/dnsmasq.d/,*.conf";
    };

    # ===== Firewall =====
    systemd.services.router-firewall = {
      description = "Configure stable router firewall";
      after = ["router-network-setup.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {Type = "oneshot"; RemainAfterExit = true;};
      script = ''
        WAN=$(cat /var/lib/hydrix-router-stable/wan_interface 2>/dev/null || echo "eth0")
        echo "Configuring firewall (WAN: $WAN)"

        ${pkgs.nftables}/bin/nft flush ruleset 2>/dev/null || true

        VM_NETWORKS="{ 192.168.100.0/24${lib.concatMapStrings (n: ", ${n.subnet}.0/24") allNetworks}, 192.168.105.0/24, 192.168.106.0/24, 192.168.108.0/24 }"

        ${pkgs.nftables}/bin/nft -f - << EOF
        table inet router {
          chain input {
            type filter hook input priority filter; policy drop;
            iif lo accept
            ct state established,related accept
            ct state invalid drop
            udp dport 67 accept
            ip saddr $VM_NETWORKS udp dport 53 accept
            ip saddr $VM_NETWORKS tcp dport 53 accept
            ip saddr $VM_NETWORKS ip protocol icmp limit rate 10/second accept
            ip saddr $VM_NETWORKS counter log prefix "STABLE-ROUTER-BLOCKED: " drop
            iifname "$WAN" accept
          }
          chain forward {
            type filter hook forward priority filter; policy drop;
            ct state established,related accept
            ct state invalid drop
            ip saddr 192.168.105.0/24 accept
            ip daddr 192.168.105.0/24 accept
            ip saddr 192.168.108.0/24 tcp dport 8888 accept
            ip saddr 192.168.108.0/24 ip daddr 192.168.108.0/24 accept
            ip saddr 192.168.108.0/24 ip protocol icmp accept
            oifname "$WAN" accept
          }
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "$WAN" masquerade
          }
        }
        EOF
        echo "Stable router firewall configured"
      '';
    };

    # ===== Services =====
    services.openssh.enable = false;
    services.qemuGuest.enable = true;
    services.getty.autologinUser = routerUser;
    services.haveged.enable = true;

    users.users.${routerUser} =
      {
        isNormalUser = true;
        extraGroups = ["wheel" "networkmanager"];
      }
      // (
        if routerHashedPassword != null
        then {hashedPassword = routerHashedPassword;}
        else {password = "router";}
      );

    security.sudo.wheelNeedsPassword = false;

    environment.systemPackages = with pkgs; [
      iproute2 iptables nftables dnsmasq tcpdump
      nettools bind.dnsutils bridge-utils pciutils
      htop vim nano iw wirelesstools networkmanager
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/hydrix-router-stable 0755 root root -"
      "d /etc/dnsmasq.d 0755 root root -"
    ];

    time.timeZone = locale.timezone;
    i18n.defaultLocale = locale.language;
    console.keyMap = locale.consoleKeymap;

    users.motd = ''

      ┌─────────────────────────────────────────────────────┐
      │  Hydrix MicroVM Router — STABLE (Fallback)          │
      └─────────────────────────────────────────────────────┘

    '';
  };
}
