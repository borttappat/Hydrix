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
#   microvm@microvm-router-stable → Conflicts=microvm@microvm-router.service
#   autostart = false  — manual-only "break glass" fallback
#   added to infrastructureVMs (available in lockdown mode)
#
# To launch: microvm start router-stable
# (stops the main router if running, then starts stable)
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  cfg = config.hydrix;
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
  # Deduplicated: custom profiles appear in both profileNetworks and extraNetworks.
  allNetworks = lib.foldl' (acc: n:
    if builtins.any (m: m.subnet == n.subnet) acc then acc else acc ++ [n]
  ) [] (profileNetworks ++ extraNetworks);

  # Files VM subnet — derived from allNetworks by routerTap name (set in infra/files/meta.nix).
  # Falls back to the canonical default if the files VM is not present.
  filesNetwork = lib.findFirst (n: n.routerTap or "" == "mv-router-file") null allNetworks;
  filesSubnet  = if filesNetwork != null then filesNetwork.subnet else "192.168.108";

  # Derive the stable TAP name for a network entry.
  # All framework routerTaps follow mv-router-<abbrev>; substitute the prefix.
  stableRouterTap = n:
    if lib.hasPrefix "mv-router-" n.routerTap
    then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
    else "mv-rts-${n.name}";

  # Infrastructure LAN interfaces — from infra/*/meta.nix builtinVm entries.
  # Stable router uses mv-rts-* prefix instead of mv-router-*.
  stableInfraLan = l: {
    tap      = builtins.replaceStrings ["mv-router-"] ["mv-rts-"] l.tap;
    subnet   = l.subnet;
    routerIp = "${l.subnet}.253";
  };
  # frameworkLans: ALL infra LANs including management (used for dnsmasq, systemd-networkd,
  # nftables — the host connects to the router via the management LAN).
  frameworkLans = map stableInfraLan cfg.router.microvm.infraLans;

  # frameworkQemuTaps: infra TAPs that need their own QEMU -netdev arg.
  # The management TAP (mv-rts-mgmt) is already declared in microvm.interfaces and must
  # not be added again — QEMU would error "Device or resource busy".
  _declaredTaps = map (iface: iface.id) (lib.filter (iface: iface.type == "tap") config.microvm.interfaces);
  frameworkQemuTaps = lib.filter (l: !builtins.elem l.tap _declaredTaps) frameworkLans;

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
    ../../options.nix
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

        ]
        # Profile network TAPs — derived from profileNetworks (profiles/*/meta.nix).
        # MACs: 02:00:00:03:XX:01, index+1 (avoids collision with mgmt=00).
        ++ lib.concatLists (lib.imap0 (i: pn: [
            "-netdev"
            "tap,id=net-${pn.name},ifname=${stableRouterTap pn},script=no,downscript=no"
            "-device"
            "virtio-net-pci,netdev=net-${pn.name},mac=02:00:00:03:${lib.fixedWidthString 2 "0" (builtins.toString (i + 1))}:01"
          ])
          profileNetworks)
        # Builtin infra VM TAPs (builtinVm = true: builder, etc.) — mgmt excluded (see frameworkQemuTaps).
        # MACs: 02:00:00:05:XX:01 — separate namespace from profiles (03) and extras (04).
        ++ lib.concatLists (lib.imap0 (i: l: [
            "-netdev"
            "tap,id=net-infra-${builtins.toString i},ifname=${l.tap},script=no,downscript=no"
            "-device"
            "virtio-net-pci,netdev=net-infra-${builtins.toString i},mac=02:00:00:05:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01"
          ])
          frameworkQemuTaps)
        # Extra user-defined network TAPs (custom profiles + non-builtin infra VMs).
        # MACs: 02:00:00:04:XX:01
        ++ lib.concatLists (lib.imap0 (i: n: [
            "-netdev"
            "tap,id=net-extra-${n.name},ifname=${stableRouterTap n},script=no,downscript=no"
            "-device"
            "virtio-net-pci,netdev=net-extra-${n.name},mac=02:00:00:04:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01"
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

      vsock.cid = lib.mkDefault 201;
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

    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

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
    # Interface renaming: MAC → stable TAP name inside the VM.
    # Matches the MAC assignments in qemu.extraArgs above.
    systemd.network.links = {
      "10-mv-rts-mgmt" = { matchConfig.MACAddress = "02:00:00:03:00:01"; linkConfig.Name = "mv-rts-mgmt"; };
    } // lib.listToAttrs (lib.imap0 (i: pn: {
      name  = "10-${stableRouterTap pn}";
      value = {
        matchConfig.MACAddress = "02:00:00:03:${lib.fixedWidthString 2 "0" (builtins.toString (i + 1))}:01";
        linkConfig.Name = stableRouterTap pn;
      };
    }) profileNetworks)
    // lib.listToAttrs (lib.imap0 (i: l: {
      name  = "10-${l.tap}";
      value = {
        matchConfig.MACAddress = "02:00:00:05:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01";
        linkConfig.Name = l.tap;
      };
    }) frameworkQemuTaps)
    // lib.listToAttrs (lib.imap0 (i: n: {
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

      wireless.enable = lib.mkForce false;
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
            # Files VM — allow HTTP file transfers between VMs
            ip saddr ${filesSubnet}.0/24 tcp dport 8888 accept
            ip saddr ${filesSubnet}.0/24 ip daddr ${filesSubnet}.0/24 accept
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

    # Locale inherited from shared/common.nix via mkMicrovmRouterStable modules argument

    users.motd = ''

      ┌─────────────────────────────────────────────────────┐
      │  Hydrix MicroVM Router — STABLE (Fallback)          │
      └─────────────────────────────────────────────────────┘

    '';
  };
}
