# MicroVM Router Stable Module - Immutable fallback router
#
# Emergency router that auto-starts when the main router fails.
# Serves all the same bridges and subnets as the main router using
# separate TAP interfaces (mv-rts-*) so both can coexist in config.
#
# Fully declarative: no runtime bash services. Because systemd.network.links
# give predictable interface names at boot, all networking (static IPs,
# dnsmasq, nftables) is generated from Nix at build time.
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

  # Derive the stable TAP name for a network entry.
  # All framework routerTaps follow mv-router-<abbrev>; substitute the prefix.
  stableRouterTap = n:
    if lib.hasPrefix "mv-router-" n.routerTap
    then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
    else "mv-rts-${n.name}";

  # Framework LAN interfaces — fixed subnets defined by Hydrix.
  # Each entry: { tap, subnet, routerIp }
  frameworkLans = [
    { tap = "mv-rts-mgmt"; subnet = "192.168.100"; routerIp = "192.168.100.253"; }
    { tap = "mv-rts-shar"; subnet = "192.168.105"; routerIp = "192.168.105.253"; }
    { tap = "mv-rts-bldr"; subnet = "192.168.106"; routerIp = "192.168.106.253"; }
    { tap = "mv-rts-file"; subnet = "192.168.108"; routerIp = "192.168.108.253"; }
  ];

  # All profile/extra network LAN interfaces — derived from meta.nix at build time.
  profileLans = map (n: {
    tap      = stableRouterTap n;
    subnet   = n.subnet;
    routerIp = "${n.subnet}.253";
  }) allNetworks;

  allLans = frameworkLans ++ profileLans;

  # All LAN interface names (for nftables and NM unmanaged list)
  allLanTaps = map (l: l.tap) allLans;

  # Comma-separated list of LAN taps for nftables set literals
  lanTapSet = lib.concatMapStringsSep ", " (t: "\"${t}\"") (["lo"] ++ allLanTaps);

  # Comma-separated list of VM subnets for nftables
  vmNetSet = lib.concatMapStringsSep ", " (l: "${l.subnet}.0/24") allLans;

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
        { type = "tap"; id = "mv-rts-mgmt"; mac = "02:00:00:03:00:01"; }
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
        # Only extraNetworks here — framework profiles (pentest, browsing, comms, dev, lurking)
        # are already hardcoded above. Dynamic block handles user-defined extra profiles only.
        ++ lib.concatLists (lib.imap0 (i: n: [
            "-netdev"
            "tap,id=net-${n.name},ifname=${stableRouterTap n},script=no,downscript=no"
            "-device"
            "virtio-net-pci,netdev=net-${n.name},mac=02:00:00:04:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01"
          ])
          extraNetworks);

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
    # This makes all interface names known at build time, enabling fully
    # declarative networking below.
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
    }) extraNetworks);

    # ===== Networking =====
    networking = {
      useDHCP = false;
      enableIPv6 = false;
      firewall.enable = false;

      # NetworkManager handles only the WiFi (WAN) interface.
      # LAN interfaces (mv-rts-*) are managed by systemd-networkd below.
      networkmanager = {
        enable = true;
        wifi.powersave = false;
        settings.keyfile.path = "/var/lib/NetworkManager/system-connections";
        unmanaged = [ "interface-name:mv-rts-*" ];
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
    };

    # ===== LAN Interface Configuration (systemd-networkd) =====
    # All LAN TAPs get static IPs. Interface names are guaranteed by
    # systemd.network.links above, so this is fully build-time declarative.
    systemd.network = {
      enable = true;
      networks = lib.listToAttrs (map (l: {
        name = "10-${l.tap}";
        value = {
          matchConfig.Name = l.tap;
          networkConfig = {
            Address = "${l.routerIp}/24";
            DHCP = "no";
            LinkLocalAddressing = "no";
            ConfigureWithoutCarrier = "yes";
          };
        };
      }) allLans);
    };

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward"                       = 1;
      "net.ipv4.conf.all.forwarding"               = 1;
      "net.ipv4.conf.default.rp_filter"            = 0;
      "net.ipv4.conf.all.rp_filter"                = 0;
      "net.ipv4.icmp_echo_ignore_broadcasts"       = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
      "net.ipv4.tcp_syncookies"                    = 1;
      "net.ipv4.tcp_rfc1337"                       = 1;
      "net.ipv4.conf.all.accept_source_route"      = 0;
      "net.ipv4.conf.all.accept_redirects"         = 0;
      "net.ipv4.conf.all.send_redirects"           = 0;
      "net.ipv4.conf.all.log_martians"             = 1;
    };

    # ===== dnsmasq (fully declarative) =====
    # Interface names are known at build time, so no runtime config generation.
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = true;
      settings = {
        bind-interfaces = true;
        log-dhcp = true;
        server = [ "1.1.1.1" "8.8.8.8" ];
        interface = allLanTaps;
        dhcp-range = map (l:
          "${l.tap},${l.subnet}.10,${l.subnet}.200,24h"
        ) allLans;
        dhcp-option = lib.concatMap (l: [
          "${l.tap},option:router,${l.routerIp}"
          "${l.tap},option:dns-server,${l.routerIp}"
        ]) allLans;
      };
    };

    # ===== Firewall (nftables, fully declarative) =====
    # LAN interface names are known at build time.
    # WAN interface is NOT named — we identify it by negating all known LANs.
    # Any interface not in the LAN set is treated as WAN/VPN → masquerade.
    networking.nftables = {
      enable = true;
      tables."stable-router" = {
        family = "inet";
        content = ''
          # LAN interfaces (all known at build time)
          define LAN_IFACES = { ${lanTapSet} }
          # VM subnets (all known at build time)
          define VM_NETS = { ${vmNetSet} }

          chain input {
            type filter hook input priority filter; policy drop;
            iif lo accept
            ct state established,related accept
            ct state invalid drop
            # DHCP — source is 0.0.0.0, must allow before IP filtering
            udp dport 67 accept
            # DNS from VMs
            ip saddr $VM_NETS udp dport 53 accept
            ip saddr $VM_NETS tcp dport 53 accept
            # ICMP from VMs (rate-limited)
            ip saddr $VM_NETS ip protocol icmp limit rate 10/second accept
            # Block everything else from VM networks
            ip saddr $VM_NETS counter drop
            # Allow WAN replies (established handled above; this accepts new WAN input)
            accept
          }

          chain forward {
            type filter hook forward priority filter; policy drop;
            ct state established,related accept
            ct state invalid drop
            # Shared bridge — inter-VM communication allowed
            ip saddr 192.168.105.0/24 accept
            ip daddr 192.168.105.0/24 accept
            # Files VM — allow HTTP file transfers between VMs
            ip saddr 192.168.108.0/24 tcp dport 8888 accept
            ip saddr 192.168.108.0/24 ip daddr 192.168.108.0/24 accept
            # Allow forwarding out to WAN/VPN (any non-LAN egress)
            oifname != $LAN_IFACES accept
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            # Masquerade on any non-LAN egress (WiFi WAN + VPN interfaces)
            oifname != $LAN_IFACES masquerade
          }
        '';
      };
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
      iproute2 iptables nftables tcpdump
      nettools bind.dnsutils bridge-utils pciutils
      htop vim iw wirelesstools networkmanager
    ];

    systemd.tmpfiles.rules = [
      "d /etc/wireguard 0700 root root -"
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
