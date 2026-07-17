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
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  # Access central options
  cfg = config.hydrix;
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
  wifiNetworks = let
    newFormat = routerCfg.wifi.networks;
    legacySSID = routerCfg.wifi.ssid;
    legacyPassword = routerCfg.wifi.password;
    legacyNetwork =
      if legacySSID != "" && legacyPassword != ""
      then [
        {
          ssid = legacySSID;
          password = legacyPassword;
          priority = 100;
        }
      ]
      else [];
  in
    if newFormat != []
    then newFormat
    else legacyNetwork;
  hasWifiCredentials = wifiNetworks != [];

  # WiFi PCI address from hardware options
  wifiPciAddress = cfg.hardware.vfio.wifiPciAddress;

  # WAN configuration
  wanCfg = routerCfg.wan;
  wanMode = wanCfg.mode;
  wanDevice = wanCfg.device;
  preferWireless = wanCfg.preferWireless;

  # Derived WAN mode booleans (resolved at eval time, embedded in generated scripts)
  usePciPassthrough = wanMode == "pci-passthrough" || (wanMode == "auto" && wifiPciAddress != "");
  useEthernetWan    = wanMode == "macvtap"         || (wanMode == "auto" && wifiPciAddress == "");

  # Mullvad VPN active when enabled and at least one bridge configured
  hasMullvad = vpnCfg.mullvad.enable && vpnCfg.mullvad.bridges != {};
  mullvadBridges = vpnCfg.mullvad.bridges; # attrset: bridge-name → conf-file path

  # WireGuard config processing hook — user-defined via hydrix.router.vpn.mullvad.processConfig
  # Default: identity (pass through raw conf files unmodified)
  processConfig = vpnCfg.mullvad.processConfig;

  # Named derivations so the boot-assign service can reference them in path
  vpnAssign = pkgs.writeShellScriptBin "vpn-assign" (builtins.readFile ../../../scripts/vpn-assign.sh);
  vpnStatus = pkgs.writeShellScriptBin "vpn-status" (builtins.readFile ../../../scripts/vpn-status.sh);

  vmName = config.networking.hostName;
  extraNetworks = cfg.networking.extraNetworks;
  profileNetworks = cfg.networking.profileNetworks;
  # extraNetworks may contain user-defined profiles that are already in
  # profileNetworks (profileNetworks = ALL discovered profiles; extraNetworks =
  # non-framework profiles + infra VMs).  Filter out duplicates to avoid double
  # QEMU TAP entries (EBUSY) and duplicate dnsmasq/nftables config.
  extraOnlyNetworks = lib.filter (n:
    !(builtins.any (pn: pn.routerTap == n.routerTap) profileNetworks)
  ) extraNetworks;
  # All networks the router serves: declared profiles + extra-only (infra VMs)
  allNetworks = profileNetworks ++ extraOnlyNetworks;

  # LAN interface names — all statically known at build time via MAC→name links.
  # Used in nftables to identify WAN/VPN egress by negation so the firewall
  # never depends on runtime WAN detection (which can fail on fresh installs).
  # Derived from infraLans + all profile/extra networks — no hardcoded names.
  lanTaps = map (l: l.tap) cfg.router.microvm.infraLans
    ++ map (n: n.routerTap) allNetworks;

  # nftables set literal: { "lo", "mv-router-mgmt", ... }
  lanTapSetNft = "{ " + lib.concatMapStringsSep ", " (t: "\"${t}\"") (["lo"] ++ lanTaps) + " }";

  # All LAN segments the router serves (networking config: dnsmasq, systemd-networkd,
  # nftables). Includes the management TAP — the host connects to the router via mgmt.
  # infraLans comes from infra/*/meta.nix builtinVm entries.
  infraLans = cfg.router.microvm.infraLans;
  allLans = infraLans ++ map (n: { tap = n.routerTap; subnet = n.subnet; }) allNetworks;

  # TAPs that need their own QEMU -netdev arg. The management TAP is declared
  # explicitly in extraArgs below, so exclude it to avoid duplicates.
  infraQemuTaps = lib.filter (l: l.tap != "mv-router-mgmt") infraLans;

  # Script run by QEMU *after* TUNSETIFF to bridge the TAP to its host bridge.
  # Using script= (not script=no) ensures QEMU holds the fd before bridge
  # attachment — eliminating the EBUSY race where a pre-bridged TAP blocks
  # TUNSETIFF (Linux rejects TUNSETIFF when an rx_handler is already registered).
  # TAPs are created on-demand by QEMU itself via TUNSETIFF; no pre-creation needed.
  tapBridgeScript = pkgs.writeShellScript "router-tap-bridge" ''
    TAP="$1"
    case "$TAP" in
      mv-router-mgmt)  BRIDGE="br-mgmt"    ;;
      mv-router-bldr)  BRIDGE="br-builder" ;;
      ${lib.optionalString useEthernetWan "mv-router-wan)   BRIDGE=\"br-wan\"   ;;\n      "}${lib.concatMapStrings (pn: "${pn.routerTap}) BRIDGE=\"br-${pn.name}\" ;;\n      ") profileNetworks}${lib.concatMapStrings (n: "${n.routerTap}) BRIDGE=\"br-${n.name}\" ;;\n      ") extraNetworks}# Unknown infra TAPs: udev catch-all bridges them after QEMU has the fd open
      *)               exit 0 ;;
    esac
    # Wait for bridge (max 5s; should exist via network.target before QEMU starts)
    for i in $(seq 10); do
      ${pkgs.iproute2}/bin/ip link show "$BRIDGE" > /dev/null 2>&1 && break
      sleep 0.5
    done
    ${pkgs.iproute2}/bin/ip link set "$TAP" master "$BRIDGE" 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip link set "$TAP" up 2>/dev/null || true
  '';
in {
  imports = [
    # Central options for config access
    ../../options.nix
    # QEMU Guest profile for virtio modules
    (modulesPath + "/profiles/qemu-guest.nix")
    # Live NixOS switch via vsock:14504 (microvm update / microvm switch)
    ./vm-switch.nix
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
    assertions = [
      {
        assertion = wanMode != "pci-passthrough" || wifiPciAddress != "";
        message = ''
          hydrix.hardware.vfio.wifiPciAddress is empty — the router VM needs a WiFi PCI
          address for VFIO passthrough when wan.mode = "pci-passthrough". Pass wifiPciAddress
          to mkMicrovmRouter in your flake:

            "microvm-router" = hydrix.lib.mkMicrovmRouter {
              wifiPciAddress = "00:14.3";  # from: lspci -D | grep -i wireless
            };

          The address should be in XX:XX.X format (without the 0000: domain prefix).

          Alternative: use wan.mode = "auto" (auto-detects WiFi or falls back to macvtap)
          or wan.mode = "macvtap" (uses ethernet instead of WiFi).
        '';
      }
    ];

    # ===== Basic Identity =====
    networking.hostName = lib.mkDefault "microvm-router";
    system.stateVersion = "25.05";
    nixpkgs.config.allowUnfree = true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== MicroVM Configuration =====
    microvm = {
      hypervisor = "qemu";
      qemu.machine = "q35"; # Q35 chipset - better PCIe/VFIO support (matches libvirt router)
      # Only disable seccomp when VFIO passthrough is in use (seccomp blocks /dev/vfio access)
      qemu.package = if usePciPassthrough then qemuNoSeccomp else pkgs.qemu_kvm;

      # Resources - router is lightweight (NAT/routing only, 1 vCPU sufficient)
      vcpu = 1;
      mem = 1024; # 1GB should be plenty

      # No store disk - we'll use virtiofs like other microvms
      storeDiskType = "squashfs";
      writableStoreOverlay = "/nix/.rw-store";

      # Headless - no graphics
      graphics.enable = false;

      # ===== Network Interfaces =====
      # All TAPs are created on-demand by QEMU via TUNSETIFF and bridged via
      # tapBridgeScript (called after TUNSETIFF, so QEMU holds the fd before
      # bridge attachment). microvm.interfaces is empty to avoid any tap-up
      # script that could race with QEMU's TUNSETIFF call.
      interfaces = [];

      # ===== Additional Network Interfaces + PCI Passthrough =====
      # Added via qemu.extraArgs for proper control over device ordering
      qemu.extraArgs =
        [
          # Headless flags
          "-vga"
          "none"
          "-display"
          "none"

          # Additional serial console via unix socket for interactive access
          # Connect with: socat -,rawer unix-connect:/var/lib/microvms/${config.networking.hostName}/console.sock
          "-chardev"
          "socket,id=console,path=/var/lib/microvms/${config.networking.hostName}/console.sock,server=on,wait=off"
          "-serial"
          "chardev:console"

          # Management TAP (br-mgmt) — created by QEMU, bridged by tapBridgeScript
          "-netdev" "tap,id=net-mgmt,ifname=mv-router-mgmt,script=${tapBridgeScript},downscript=no"
          "-device" "virtio-net-pci,netdev=net-mgmt,mac=02:00:00:01:00:01"

        ]
        # VFIO passthrough — only when using WiFi PCI passthrough as WAN
        ++ lib.optionals usePciPassthrough [
          "-device" "pcie-root-port,id=pcie.1,slot=1,chassis=1"
          # Strip "0000:" prefix if user provided full format (handles both "00:14.3" and "0000:00:14.3")
          "-device" "vfio-pci,host=0000:${lib.removePrefix "0000:" wifiPciAddress},bus=pcie.1"
        ]
        # Ethernet WAN TAP — only when using macvtap/ethernet as WAN
        ++ lib.optionals useEthernetWan [
          "-netdev" "tap,id=net-wan,ifname=mv-router-wan,script=${tapBridgeScript},downscript=no"
          "-device" "virtio-net-pci,netdev=net-wan,mac=02:00:00:01:09:01"
        ]
        # Profile network TAPs — derived from profileNetworks (profiles/*/meta.nix).
        # MACs: 02:00:00:01:XX:01, index+1 (index 0 = 01 avoids collision with mgmt=00).
        # Order follows alphabetical profile directory discovery.
        ++ lib.concatLists (lib.imap0 (i: pn: [
            "-netdev"
            "tap,id=net-${pn.name},ifname=${pn.routerTap},script=${tapBridgeScript},downscript=no"
            "-device"
            "virtio-net-pci,netdev=net-${pn.name},mac=02:00:00:01:${lib.fixedWidthString 2 "0" (builtins.toString (i + 1))}:01"
          ])
          profileNetworks)
        # Builtin infra VM TAPs (builtinVm = true: builder, etc.) — mgmt excluded (see infraQemuTaps).
        # MACs: 02:00:00:03:XX:01 — separate namespace from profiles (01) and extras (02).
        ++ lib.concatLists (lib.imap0 (i: l: [
            "-netdev"
            "tap,id=net-infra-${builtins.toString i},ifname=${l.tap},script=${tapBridgeScript},downscript=no"
            "-device"
            "virtio-net-pci,netdev=net-infra-${builtins.toString i},mac=02:00:00:03:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01"
          ])
          infraQemuTaps)
        # Extra network TAPs (infra VMs not already covered by profileNetworks).
        # MACs: 02:00:00:02:XX:01
        ++ lib.concatLists (lib.imap0 (i: n: [
            "-netdev"
            "tap,id=net-extra-${n.name},ifname=${n.routerTap},script=${tapBridgeScript},downscript=no"
            "-device"
            "virtio-net-pci,netdev=net-extra-${n.name},mac=02:00:00:02:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01"
          ])
          extraOnlyNetworks);

      # Limit virtiofsd threads: default spawns nproc threads per share, wasteful when idle
      virtiofsd.threadPoolSize = 1;

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
        # Secrets delivered by host hydrix-secrets-${vmName} service.
        # Populated when hydrix.microvmHost.vms."microvm-router".secrets includes "wifi".
        # Always shared (dir is pre-created by tmpfiles even when empty).
        {
          tag = "vm-secrets";
          source = "/run/hydrix-secrets/${vmName}";
          mountPoint = "/mnt/vm-secrets";
          proto = "virtiofs";
        }
      ];

      # ===== Persistent Volume for /var/lib =====
      # Stores VPN assignments, dnsmasq leases, etc.
      volumes = [
        {
          image = "/var/lib/microvms/${vmName}/var-lib.qcow2";
          mountPoint = "/var/lib";
          size = 512; # 512MB for router state
          autoCreate = true;
        }
      ];

      # ===== Vsock =====
      # lib.mkDefault: user can override via infra/router/default.nix (or meta.nix CID)
      vsock.cid = lib.mkDefault 200;
    };

    # ===== Disable auto-optimise-store =====
    nix.settings.auto-optimise-store = lib.mkForce false;

    # ===== Kernel Configuration =====
    boot.initrd.availableKernelModules = [
      "virtio_balloon"
      "virtio_blk"
      "virtio_pci"
      "virtio_ring"
      "virtio_net"
      "virtio_scsi"
      "virtio_mmio"
      "squashfs"
    ];

    boot.kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "random.trust_cpu=on"
    ];

    # Use latest kernel for best iwlwifi/WiFi support (matches libvirt router)
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

    boot.kernelModules = lib.mkDefault [
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

    # ===== Predictable Interface Naming =====
    # Inside the QEMU VM, virtio-net devices get kernel-assigned names (ens3, ens4, …),
    # not the host-side TAP names. These .link files rename each interface by its
    # known MAC address so that find_iface_by_name works in the setup scripts.
    # Interface renaming: MAC → stable TAP name inside the VM.
    # Matches the MAC assignments in qemu.extraArgs above so that
    # find_iface_by_name and all network services see consistent names.
    systemd.network.links = {
      "10-mv-router-mgmt" = { matchConfig.MACAddress = "02:00:00:01:00:01"; linkConfig.Name = "mv-router-mgmt"; };
    } // lib.optionalAttrs useEthernetWan {
      "10-mv-router-wan" = { matchConfig.MACAddress = "02:00:00:01:09:01"; linkConfig.Name = "mv-router-wan"; };
    } // lib.listToAttrs (lib.imap0 (i: pn: {
      name  = "10-${pn.routerTap}";
      value = {
        matchConfig.MACAddress = "02:00:00:01:${lib.fixedWidthString 2 "0" (builtins.toString (i + 1))}:01";
        linkConfig.Name = pn.routerTap;
      };
    }) profileNetworks)
    // lib.listToAttrs (lib.imap0 (i: l: {
      name  = "10-${l.tap}";
      value = {
        matchConfig.MACAddress = "02:00:00:03:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01";
        linkConfig.Name = l.tap;
      };
    }) infraQemuTaps)
    // lib.listToAttrs (lib.imap0 (i: n: {
      name  = "20-${n.routerTap}";
      value = {
        matchConfig.MACAddress = "02:00:00:02:${lib.fixedWidthString 2 "0" (builtins.toString i)}:01";
        linkConfig.Name = n.routerTap;
      };
    }) extraNetworks);

    # ===== LAN Interface Configuration (systemd-networkd) =====
    # Static IPs assigned at boot — no waiting for WiFi. Mirrors microvm-router-stable.
    # ConfigureWithoutCarrier ensures IPs come up even before TAP carrier is established,
    # so the host can reach 192.168.100.253 as soon as the VM boots.
    #
    # allLans = framework infra taps (fixed) ++ profile/extra-network taps (auto-discovered).
    # Adding a new infra VM with routerTap in hydrix-config automatically appears here.
    systemd.network = {
      enable = true;
      networks = lib.listToAttrs (lib.imap0 (i: l: {
        name = "${lib.fixedWidthString 2 "0" (toString i)}-${l.tap}";
        value = {
          matchConfig.Name = l.tap;
          networkConfig = { Address = "${l.subnet}.253/24"; DHCP = "no"; LinkLocalAddressing = "no"; ConfigureWithoutCarrier = "yes"; };
        };
      }) allLans);
    };

    # ===== Networking Configuration =====
    networking = {
      useDHCP = false;
      enableIPv6 = false;

      # NetworkManager for WiFi management only — LAN TAPs are handled by systemd-networkd
      networkmanager = {
        enable = true;
        wifi.powersave = false; # Prevent missed broadcast ARP replies
        # Store connections in /var/lib (persistent qcow2) instead of /etc (read-only squashfs)
        settings = {
          keyfile.path = "/var/lib/NetworkManager/system-connections";
        };
        ensureProfiles.profiles =
          # WiFi profiles (one per network)
          (lib.optionalAttrs hasWifiCredentials
            (builtins.listToAttrs (map (network: {
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
              })
              wifiNetworks)))
          # Ethernet WAN profile (for macvtap/ethernet WAN mode)
          // (lib.optionalAttrs useEthernetWan {
            wan-ethernet = {
              connection = {
                id = "wan-ethernet";
                type = "ethernet";
                interface-name = "mv-router-wan";
                autoconnect = "true";
              };
              ipv4.method = "auto";
              ipv6.method = "disabled";
            };
          });
      };
      # Not set here: NetworkManager's own module (networking.networkmanager)
      # sets wireless.enable = true + dbusControlled = true itself, to spin up
      # the wpa_supplicant backend it drives over D-Bus. Overriding it false
      # (even via mkForce) starves NM of that backend -> wifi device stuck
      # "unavailable". Let NM's module own this value.
      firewall.enable = false; # We use nftables directly

      # LAN TAPs managed by systemd-networkd — tell NM to leave them alone
      networkmanager.unmanaged = map (l: l.tap) allLans;
    };

    # ===== IP Forwarding and Kernel Hardening =====
    boot.kernel.sysctl = {
      # Routing (required)
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
      "net.ipv4.conf.default.rp_filter" = 0; # Required for policy routing
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
        # Routing tables — one per profile, using vsockCid as table ID (unique, stable)
        "iproute2/rt_tables".text = ''
          255     local
          254     main
          253     default
          0       unspec
          # Hydrix profile routing tables (ID = vsockCid)
        '' + lib.concatMapStrings (n:
          "  ${lib.last (lib.splitString "." n.subnet)}     ${n.name}\n"
        ) allNetworks;

        # Runtime network map for vpn-assign: name:tableId:subnet
        # Table ID = subnet last octet (e.g. 192.168.102 → 102), same as CID by convention
        "hydrix-router/network-map".text =
          lib.concatMapStrings (n:
            "${n.name}:${lib.last (lib.splitString "." n.subnet)}:${n.subnet}.0/24\n"
          ) allNetworks;

        # Static interface name map — generated at build time from known TAP names.
        # Consumed by dnsmasq-config; no runtime detection needed since names are
        # fixed by systemd.network.links above. Variable names match what
        # dnsmasq-config expects: profile name → IFACE_<NAME>, infra → IFACE_<TAP>.
        "hydrix-router/interfaces".text =
          lib.concatMapStrings (l: let
            varName = lib.toUpper (builtins.replaceStrings ["-" "mv-router-"] ["_" ""] l.tap);
          in "IFACE_${varName}=${l.tap}\n") infraLans
          + lib.concatMapStrings (n: let
              varName = lib.toUpper (builtins.replaceStrings ["-"] ["_"] n.name);
            in "IFACE_${varName}=${n.routerTap}\n") allNetworks
          ;
      }
      # Mullvad WireGuard conf files — processed via hydrix.router.vpn.mullvad.processConfig
      (lib.mkIf hasMullvad (
        lib.mapAttrs' (bridge: f: {
          name = "wireguard/wg-${bridge}.conf";
          value = { source = processConfig f; mode = "0600"; };
        }) mullvadBridges
      ))
    ];

    # ===== WAN Detection Service =====
    # LAN IPs are now handled by systemd-networkd at boot (see allLans above).
    # This service only detects and records the WAN interface for vpn-boot-assign
    # and waits for WiFi connection before declaring network-online.
    systemd.services.router-network-setup = {
      description = "Detect WAN interface and wait for WiFi connection";
      after = ["network.target" "local-fs.target" "systemd-tmpfiles-setup.service"];
      before = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.coreutils pkgs.gnugrep pkgs.iproute2 pkgs.networkmanager];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        STATE_DIR="/var/lib/hydrix-router"
        mkdir -p "$STATE_DIR"

        echo "=== WAN Detection Starting ==="

        # Find interface by MAC address
        find_iface_by_mac() {
          local target_mac="$1"
          for iface in $(ls /sys/class/net/ 2>/dev/null); do
            if [[ -f "/sys/class/net/$iface/address" ]]; then
              local mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
              [[ "$mac" == "$target_mac" ]] && { echo "$iface"; return; }
            fi
          done
          echo ""
        }

        USE_ETHERNET_WAN="${if useEthernetWan then "true" else "false"}"

        detect_wan() {
          if [[ "$USE_ETHERNET_WAN" == "true" ]]; then
            find_iface_by_mac "02:00:00:01:09:01"
          else
            for iface in $(ls /sys/class/net/ 2>/dev/null); do
              [[ "$iface" == wl* ]] && { echo "$iface"; return; }
            done
            for iface in $(ls /sys/class/net/ 2>/dev/null); do
              [[ -d "/sys/class/net/$iface/wireless" ]] && { echo "$iface"; return; }
            done
            echo ""
          fi
        }

        # Wait for WAN interface to appear
        if [[ "$USE_ETHERNET_WAN" == "true" ]]; then
          for i in $(seq 1 15); do
            WAN_IFACE=$(detect_wan)
            [[ -n "$WAN_IFACE" ]] && break
            echo "  waiting for ethernet WAN ($i/15)..."
            sleep 1
          done
        else
          for i in $(seq 1 30); do
            WAN_IFACE=$(detect_wan)
            [[ -n "$WAN_IFACE" ]] && break
            echo "  waiting for WiFi interface ($i/30)..."
            sleep 1
          done
        fi

        if [[ -z "$WAN_IFACE" ]]; then
          echo "WARNING: No WAN interface detected!"
          ${pkgs.iproute2}/bin/ip link show
          WAN_IFACE="none"
        fi

        echo "WAN interface: $WAN_IFACE"
        echo "$WAN_IFACE" > "$STATE_DIR/wan_interface"
        echo "standard" > "$STATE_DIR/mode"

        # Wait for WiFi to connect (NetworkManager handles the actual connection)
        if [[ "$WAN_IFACE" != "none" && "$USE_ETHERNET_WAN" != "true" ]]; then
          for i in $(seq 1 60); do
            if ${pkgs.networkmanager}/bin/nmcli device show "$WAN_IFACE" 2>/dev/null | grep -q "connected"; then
              echo "WiFi connected"
              break
            fi
            echo "  waiting for WiFi connection ($i/60)..."
            sleep 1
          done
        fi
      '';
    };

    # ===== Dynamic dnsmasq Configuration =====
    systemd.services.dnsmasq-config = {
      description = "Generate dnsmasq config from build-time interface names";
      after = ["systemd-networkd.service"];
      before = ["dnsmasq.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /etc/dnsmasq.d

        # Interface names are fixed at build time via systemd.network.links
        source /etc/hydrix-router/interfaces 2>/dev/null || true

        echo "Generating dnsmasq config with interfaces:"
        echo "  MGMT=$IFACE_MGMT"

        # Generate config only for interfaces that exist
        echo "bind-interfaces" > /etc/dnsmasq.d/hydrix.conf
        ${lib.optionalString cfg.router.microvm.dnsmasq.enableDhcpLogging
          ''echo "log-dhcp" >> /etc/dnsmasq.d/hydrix.conf''}
        ${lib.concatMapStrings (s: ''echo "server=${s}" >> /etc/dnsmasq.d/hydrix.conf
        '') cfg.router.microvm.dnsmasq.servers}

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

        # Infrastructure LANs (from infra/*/meta.nix)
        ${lib.concatStringsSep "\n        " (map (l:
          "add_iface \"${l.tap}\" \"${l.subnet}\" \"${l.subnet}.253\""
        ) infraLans)}
        # Profile + extra networks (from profiles/*/meta.nix + extraNetworks)
        ${lib.concatStringsSep "\n        " (map (n: let
          varName = lib.toUpper (builtins.replaceStrings ["-"] ["_"] n.name);
        in "add_iface \"$IFACE_${varName}\" \"${n.subnet}\" \"${n.subnet}.253\"") allNetworks)}

        echo "Generated dnsmasq config:"
        cat /etc/dnsmasq.d/hydrix.conf
      '';
    };

    services.dnsmasq = {
      enable = lib.mkDefault true;
      resolveLocalQueries = lib.mkDefault true;
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
      after = ["sysinit.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo "Configuring hardened firewall (LAN negation, WAN-agnostic)"

        ${pkgs.nftables}/bin/nft flush ruleset 2>/dev/null || true

        # Define VM network ranges (profile subnets from meta.nix + infra fixed subnets)
        VM_NETWORKS="{ ${lib.concatStringsSep ", " (map (l: "${l.subnet}.0/24") allLans)} }"

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

            # Allow non-LAN input (WAN, VPN interfaces — identified by negation)
            iifname != ${lanTapSetNft} accept
          }

          chain forward {
            type filter hook forward priority filter; policy drop;

            # Allow established/related
            ct state established,related accept
            ct state invalid drop

            # Shared subnets: allow inter-VM traffic (user-configurable)
            ${let shared = cfg.router.microvm.firewall.sharedSubnets;
              in lib.concatMapStrings (s: ''ip saddr ${s} accept
            ip daddr ${s} accept
            '') shared}
            # Isolated bridges: block inter-bridge traffic (auto-generated from topology)
            ${let
                allSubnets   = map (l: "${l.subnet}.0/24") allLans;
                shared       = cfg.router.microvm.firewall.sharedSubnets;
                isolated     = lib.filter (s: !builtins.elem s shared) allSubnets;
              in lib.concatMapStrings (src:
                let others = lib.filter (d: d != src) isolated;
                in if others == [] then ""
                   else "ip saddr ${src} ip daddr { ${lib.concatStringsSep ", " others} } drop\n            "
              ) isolated}
            # User extra rules
            ${lib.concatStringsSep "\n            " cfg.router.microvm.firewall.extraRules}

            # Allow forwarding out to WAN/VPN (any non-LAN egress)
            oifname != ${lanTapSetNft} accept
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            # Masquerade on any non-LAN egress (WiFi WAN, ethernet WAN, VPN interfaces)
            oifname != ${lanTapSetNft} masquerade
          }
        }
        EOF

        echo "Hardened firewall configured:"
        echo "  - VMs can use: DHCP, DNS only"
        echo "  - VMs cannot: SSH, HTTP, or access any router services"
        echo "  - Inter-VM traffic: blocked (use router.microvm.firewall.sharedSubnets to allow)"
      '';
    };

    # ===== Mullvad Boot-Assign Service =====
    # Connects configured tunnels and routes bridges at startup.
    # Generated from vpn.mullvad.bridges — no hardcoded network names.
    systemd.services.vpn-boot-assign = lib.mkIf hasMullvad {
      description = "Apply Mullvad VPN bridge assignments";
      after = [ "network-online.target" "router-firewall.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.wireguard-tools pkgs.iproute2 pkgs.gawk vpnAssign ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script =
        # Connect each configured tunnel — fall back to direct if wg-quick fails
        # so a failed tunnel never leaves a bridge with an empty routing table.
        # If the interface already exists (service restarted after partial run),
        # skip wg-quick and re-apply routing from whatever state the tunnel is in.
        lib.concatMapStrings (bridge: ''
          echo "Connecting wg-${bridge}..."
          if ip link show wg-${bridge} &>/dev/null; then
            echo "wg-${bridge} already up, re-applying routing"
            vpn-assign ${bridge} wg-${bridge}
          elif wg-quick up wg-${bridge}; then
            vpn-assign ${bridge} wg-${bridge}
          else
            echo "Warning: wg-${bridge} failed to connect, routing ${bridge} direct"
            vpn-assign ${bridge} direct
          fi
        '') (lib.attrNames mullvadBridges)
        # All other known networks go direct
        + lib.concatMapStrings (n:
          lib.optionalString (!lib.hasAttr n.name mullvadBridges) ''
            vpn-assign ${n.name} direct
          ''
        ) allNetworks;
    };

    # ===== WiFi Sync Service =====
    # Vsock server: host polls for WiFi credentials to sync to ~/hydrix-config
    systemd.services.wifi-sync = {
      description = "WiFi credential sync server (vsock port 14506)";
      wantedBy = ["multi-user.target"];
      after = ["NetworkManager.service" "network.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          handler = pkgs.writeShellScript "wifi-sync-handler" ''
            GREP="${pkgs.gnugrep}/bin/grep"
            SED="${pkgs.gnused}/bin/sed"

            json_esc() { printf '%s' "$1" | $SED 's/\\/\\\\/g; s/"/\\"/g'; }

            # Extract key=value from a keyfile using grep -m1 (no head, no SIGPIPE).
            # Strips the key= prefix with shell expansion — no awk or cut needed.
            kf_get() {
              local line
              line=$($GREP -m1 "^$1=" "$2" 2>/dev/null) || return 1
              printf '%s' "''${line#*=}"
            }

            # Read active SSID from kernel via iw — no D-Bus, works from socat EXEC context.
            get_current() {
              local line
              line=$(${pkgs.iw}/bin/iw dev 2>/dev/null | $GREP -m1 $'\tssid ') || true
              printf '%s' "''${line#*ssid }"
            }

            # Flat list of all wifi connections from both NM dirs.
            # /run/ = declared (from wifi.nix build); /var/lib/ = runtime-added (pending).
            # Dedup by SSID — /run/ takes precedence (listed first).
            get_connections() {
              local first=true seen="" ssid psk
              printf '['
              shopt -s nullglob
              for f in /run/NetworkManager/system-connections/*.nmconnection \
                       /var/lib/NetworkManager/system-connections/*.nmconnection; do
                [[ -f "$f" ]] || continue
                ssid=$(kf_get ssid "$f") || continue
                psk=$(kf_get psk "$f") || continue
                [[ -n "$ssid" && -n "$psk" ]] || continue
                case "$seen" in *"|''${ssid}|"*) continue ;; esac
                seen="''${seen}|''${ssid}|"
                [[ "$first" == true ]] || printf ','
                first=false
                printf '{"ssid":"%s","psk":"%s"}' "$(json_esc "$ssid")" "$(json_esc "$psk")"
              done
              shopt -u nullglob
              printf ']'
            }

            read -r cmd
            case "$cmd" in
              POLL|STATUS)
                printf '{"current":"%s","connections":' "$(json_esc "$(get_current)")"
                get_connections
                printf '}'
                ;;
              ADD)
                read -r ssid
                read -r pass
                [[ -n "$ssid" && -n "$pass" ]] || {
                  printf '{"ok":false,"error":"missing ssid or password"}'; exit 0; }
                # WPA-PSK: 8-63 plaintext chars, or exactly 64 hex chars (pre-hashed)
                psk_len=''${#pass}
                if [[ "$psk_len" -lt 8 || ( "$psk_len" -gt 63 && "$psk_len" -ne 64 ) ]]; then
                  printf '{"ok":false,"error":"PSK must be 8-63 chars (or 64-char hex hash), got %d"}' "$psk_len"
                  exit 0
                fi
                if ${pkgs.networkmanager}/bin/nmcli device wifi connect "$ssid" \
                   password "$pass" 2>/dev/null; then
                  printf '{"ok":true,"connected":true}'
                elif ${pkgs.networkmanager}/bin/nmcli connection add \
                   type wifi con-name "$ssid" ssid "$ssid" \
                   wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" \
                   connection.autoconnect yes 2>/dev/null; then
                  printf '{"ok":true,"connected":false}'
                else
                  printf '{"ok":false,"error":"failed to add connection"}'
                fi
                ;;
              REMOVE)
                read -r ssid
                [[ -n "$ssid" ]] || {
                  printf '{"ok":false,"error":"missing ssid"}'; exit 0; }
                if ${pkgs.networkmanager}/bin/nmcli con delete "$ssid" 2>/dev/null; then
                  printf '{"ok":true}'
                else
                  printf '{"ok":false,"error":"connection not found: %s"}' "$ssid"
                fi
                ;;
              *)
                printf '{"error":"unknown command"}'
                ;;
            esac
          '';
        in "${pkgs.socat}/bin/socat VSOCK-LISTEN:14506,reuseaddr,fork EXEC:${handler}";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== WiFi from Sops =====
    # Reads /mnt/vm-secrets/wifi/networks.json (delivered by host hydrix-secrets service)
    # and creates NM connections for each network. No-op when file is absent so
    # non-sops deployments (credentials still in modules/wifi.nix) are unaffected.
    systemd.services.hydrix-wifi-from-sops = {
      description = "Configure WiFi networks from sops secrets";
      wantedBy    = [ "network.target" ];
      after       = [ "NetworkManager.service" ];
      before      = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        jq    = "${pkgs.jq}/bin/jq";
        nmcli = "${pkgs.networkmanager}/bin/nmcli";
      in ''
        set -euo pipefail
        WIFI_FILE="/mnt/vm-secrets/wifi/networks.json"
        [ -f "$WIFI_FILE" ] || { echo "No wifi secrets — skipping"; exit 0; }
        count=0
        while IFS= read -r net; do
          ssid=$(printf '%s' "$net" | ${jq} -r '.ssid')
          psk=$(printf '%s' "$net" | ${jq} -r '.psk')
          prio=$(printf '%s' "$net" | ${jq} -r '.priority // 50')
          if ${nmcli} con show "$ssid" &>/dev/null; then
            echo "  $ssid: already configured"
          else
            ${nmcli} con add type wifi con-name "$ssid" ssid "$ssid" \
              wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$psk" \
              connection.autoconnect yes connection.autoconnect-priority "$prio" \
              ipv6.method disabled
            count=$((count+1))
          fi
        done < <(${jq} -c '.[]' "$WIFI_FILE")
        echo "$count network(s) configured from sops secrets"
      '';
    };

    # ===== Services =====
    services.openssh.enable = lib.mkDefault false; # No SSH - console only
    services.qemuGuest.enable = lib.mkDefault true;
    services.getty.autologinUser = lib.mkDefault routerUser;
    services.haveged.enable = lib.mkDefault true;

    # ===== User Configuration =====
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

    # ===== Packages =====
    environment.systemPackages = (with pkgs; [
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
    ] ++ lib.optionals hasMullvad [
      wireguard-tools
      vpnAssign
      vpnStatus
    ] ++ cfg.router.microvm.extraPackages);

    # ===== Tmpfiles =====
    systemd.tmpfiles.rules = [
      "d /etc/wireguard 0700 root root -"
      "d /etc/openvpn/client 0700 root root -"
      "d /var/lib/hydrix-vpn 0755 root root -"
      "d /var/lib/hydrix-router 0755 root root -"
      "d /etc/dnsmasq.d 0755 root root -"
    ];

    # ===== Locale =====
    # Inherited from shared/common.nix passed via mkMicrovmRouter modules argument

    # ===== MOTD =====
    users.motd = ''

      ┌─────────────────────────────────────────────────────┐
      │  Hydrix MicroVM Router (Serial Console Only)        │
      ├─────────────────────────────────────────────────────┤
      │  vpn-status           Network & VPN status          │
      │  vpn-assign --help    VPN routing commands          │
      │  wifi-sync            WiFi credential sync          │
      │  lan-control          Pentest LAN toggle            │
      └─────────────────────────────────────────────────────┘

    '';

    # ===== Banner =====
    systemd.services.router-banner = {
      description = "Display router status";
      wantedBy = ["multi-user.target"];
      after = ["router-network-setup.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo ""
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║           HYDRIX MICROVM ROUTER                          ║"
        echo "╠══════════════════════════════════════════════════════════╣"
        echo "║  Networks: ${lib.concatMapStringsSep ", " (l: l.subnet) (lib.take 3 allLans)}...  ║"
        echo "╚══════════════════════════════════════════════════════════╝"
        echo ""
      '';
    };
  };
}
