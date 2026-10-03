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
#   3. Start microvm router: shard start microvm-router
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

  # Compiled persistent vsock server, zero fork/exec per connection. Replaces
  # the old fork-per-connection socat listeners for wifi-sync/net-stats/
  # wg-status. Source lives alongside this file as router-stats-server.c.
  routerStatsServerBin =
    pkgs.runCommand "router-stats-server" {
      nativeBuildInputs = [pkgs.gcc];
    } ''
      mkdir -p $out/bin
      gcc -O2 -o $out/bin/router-stats-server ${./router-stats-server.c}
    '';

  # Queries nl80211 (WiFi SSID) and WireGuard genl (peer stats) directly via
  # libmnl, with no exec of `iw`/`wg` - a new process on this VM's single
  # vCPU means resolving an ELF binary and its shared libraries over a
  # virtiofs-backed /nix/store, a real CPU cost the netlink call itself
  # doesn't pay. Source lives alongside this file as router-netlink-poller.c.
  # Writes /tmp/wifi-sync-status.json and /tmp/wg-status.json, the same
  # cache files router-stats-server reads to answer host queries.
  routerNetlinkPollerBin =
    pkgs.runCommand "router-netlink-poller" {
      nativeBuildInputs = [pkgs.gcc];
      buildInputs = [pkgs.libmnl];
    } ''
      mkdir -p $out/bin
      gcc -O2 -o $out/bin/router-netlink-poller ${./router-netlink-poller.c} -lmnl
    '';

  routerPollInterval = toString cfg.router.polling.interval;

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
  useEthernetWan = wanMode == "macvtap" || (wanMode == "auto" && wifiPciAddress == "");

  # Mullvad VPN active when enabled and at least one bridge configured
  hasMullvad = vpnCfg.mullvad.enable && vpnCfg.mullvad.bridges != {};
  mullvadBridges = vpnCfg.mullvad.bridges; # attrset: bridge-name → conf-file path

  # WireGuard config processing hook - user-defined via hydrix.router.vpn.mullvad.processConfig
  # Default: identity (pass through raw conf files unmodified)
  processConfig = vpnCfg.mullvad.processConfig;

  # Named derivations so the boot-assign service can reference them in path
  vpnAssign = pkgs.writeShellScriptBin "vpn-assign" (''
      export PATH=${lib.makeBinPath (with pkgs; [iproute2 nftables wireguard-tools gawk gnugrep gnused coreutils])}:$PATH
    ''
    + builtins.readFile ../../../scripts/vpn-assign.sh);
  vpnStatus = pkgs.writeShellScriptBin "vpn-status" (builtins.readFile ../../../scripts/vpn-status.sh);

  vmName = cfg.vm.storeName;
  extraNetworks = cfg.networking.extraNetworks;
  profileNetworks = cfg.networking.profileNetworks;
  # extraNetworks may contain user-defined profiles that are already in
  # profileNetworks (profileNetworks = ALL discovered profiles; extraNetworks =
  # non-framework profiles + infra VMs).  Filter out duplicates to avoid double
  # QEMU TAP entries (EBUSY) and duplicate dnsmasq/nftables config.
  extraOnlyNetworks =
    lib.filter (
      n:
        !(builtins.any (pn: pn.routerTap == n.routerTap) profileNetworks)
    )
    extraNetworks;
  # All networks the router serves: declared profiles + extra-only (infra VMs)
  allNetworks = profileNetworks ++ extraOnlyNetworks;

  # LAN interface names - all statically known at build time via MAC→name links.
  # Used in nftables to identify WAN/VPN egress by negation so the firewall
  # never depends on runtime WAN detection (which can fail on fresh installs).
  # Derived from infraLans + all profile/extra networks - no hardcoded names.
  lanTaps =
    map (l: l.tap) cfg.router.microvm.infraLans
    ++ map (n: n.routerTap) allNetworks;

  # nftables set literal: { "lo", "mv-router-mgmt", ... }
  lanTapSetNft = "{ " + lib.concatMapStringsSep ", " (t: "\"${t}\"") (["lo"] ++ lanTaps) + " }";

  # All LAN segments the router serves (networking config: dnsmasq, systemd-networkd,
  # nftables). Includes the management TAP - the host connects to the router via mgmt.
  # infraLans comes from infra/*/meta.nix builtinVm entries.
  infraLans = cfg.router.microvm.infraLans;
  allLans =
    infraLans
    ++ map (n: {
      tap = n.routerTap;
      subnet = n.subnet;
    })
    allNetworks;

  # One record per LAN NIC (plus the ethernet WAN): the single source for QEMU
  # args, .link renames, tap -> bridge wiring and the boot check.
  routerNics = import ./router-nics.nix {inherit lib;};
  wanMac = "02:00:00:06:ff:02";
  infraBridges = {
    "mv-router-mgmt" = "br-mgmt";
    "mv-router-bldr" = "br-builder";
  };
  nics =
    map (l: routerNics.mkNic "06" (l // {bridge = infraBridges.${l.tap} or null;}))
    (lib.sort (a: b: a.tap == "mv-router-mgmt" && b.tap != "mv-router-mgmt") infraLans)
    ++ map (n:
      routerNics.mkNic "06" {
        tap = n.routerTap;
        inherit (n) subnet;
        bridge = "br-${n.name}";
      })
    allNetworks
    ++ lib.optional useEthernetWan {
      tap = "mv-router-wan";
      subnet = null;
      bridge = "br-wan";
      mac = wanMac;
    };

  # ===== Router nftables ruleset (loaded by router-firewall) =====
  # WAN-side private space: the local network the router's uplink sits on
  # (home/hotel/office LAN, carrier NAT, link-local).
  privateNets = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 }";
  # Egress interfaces that are tunnels, not the physical uplink
  tunnelIfaces = ["wg-*" "tun*" "mullvad-*" "tailscale0"];
  # Mark on replies to connections a router DNAT created; routed via main
  dnatReplyMark = "0x100";
  vmNetworks = "{ ${lib.concatMapStringsSep ", " (l: "${l.subnet}.0/24") allLans} }";
  routerLanIps = "{ ${lib.concatMapStringsSep ", " (l: "${l.subnet}.253") allLans} }";
  # Each LAN may only source its own subnet. Traffic isolation and the
  # per-network VPN tables both key on source address, so this is what makes
  # them hold against a VM spoofing another network's addresses.
  antiSpoof =
    lib.concatMapStringsSep "\n    " (l: ''iifname "${l.tap}" ip saddr != ${l.subnet}.0/24 drop'')
    allLans;
  # Networks routed through a tunnel at boot start with their DNS redirected
  # into it; vpn-assign keeps the map in step with runtime reassignments.
  vpnDnsElements =
    lib.concatMapStringsSep ", " (n: "\"${n.routerTap}\" : ${vpnCfg.mullvad.dns}")
    (lib.filter (n: mullvadBridges ? ${n.name}) allNetworks);
  firewallRules = pkgs.writeText "router-firewall.nft" ''
    table inet router
    delete table inet router
    table inet router {
      # LAN tap -> in-tunnel resolver, for networks whose traffic is tunnelled
      # or blocked. Direct networks are absent and use the router's resolver.
      map vpn_dns {
        type ifname : ipv4_addr
        ${lib.optionalString (vpnDnsElements != "") "elements = { ${vpnDnsElements} }"}
      }

      # LAN taps allowed to reach private addresses on the WAN side (the
      # physical LAN the router's uplink is on). router-lan-control adds and
      # removes networks at runtime; the host's management network is always in.
      set lan_access {
        type ifname
        elements = { "mv-router-mgmt" }
      }

      # Replies to connections a DNAT rule on the router created (port
      # forwards, VPN DNS) are routed via the main table, i.e. back the way
      # the connection came in, not into the VM network's tunnel table.
      chain dnat_reply {
        type filter hook prerouting priority mangle; policy accept;
        ct direction reply ct status dnat meta mark set meta mark | ${dnatReplyMark}
      }

      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ip daddr ${routerLanIps} meta l4proto { tcp, udp } th dport 53 dnat ip to iifname map @vpn_dns
      }

      chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        # DHCP DISCOVER/REQUEST come from 0.0.0.0 (client has no IP yet)
        iifname ${lanTapSetNft} udp dport 67 accept

        ${antiSpoof}

        # DNS and rate-limited ICMP from VMs; everything else from VMs is dropped
        ip saddr ${vmNetworks} udp dport 53 accept
        ip saddr ${vmNetworks} tcp dport 53 accept
        ip saddr ${vmNetworks} ip protocol icmp limit rate 10/second accept
        ip saddr ${vmNetworks} counter log prefix "ROUTER-BLOCKED: " drop

        # WAN side: only DHCP replies for the router's own lease; replies to
        # connections the router made are covered by the ct rule above
        iifname != ${lanTapSetNft} udp sport 67 udp dport 68 accept
      }

      chain forward {
        type filter hook forward priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop

        ${antiSpoof}

        # Connections a DNAT rule on the router redirected on purpose (port
        # forwards from router-lan-control or user services, VPN DNS). Only
        # root on the router can create those, and this keeps them working
        # across a firewall reload without inserting rules into this table.
        ct status dnat accept

        # Shared subnets: allow inter-VM traffic (user-configurable)
        ${lib.concatMapStrings (sub: ''
        ip saddr ${sub} accept
            ip daddr ${sub} accept
      '')
      cfg.router.microvm.firewall.sharedSubnets}
        # Allowed access: scoped exceptions to isolation (user-configurable)
        ${lib.concatMapStrings (
        a:
          lib.concatMapStrings (port: ''
            ip saddr ${a.from} ip daddr ${a.to} ${a.proto} dport ${toString port} accept
          '')
          a.ports
      )
      cfg.router.microvm.firewall.allowedAccessTo}
        # Isolated bridges: block inter-bridge traffic (auto-generated from topology)
        ${let
      allSubnets = map (l: "${l.subnet}.0/24") allLans;
      shared = cfg.router.microvm.firewall.sharedSubnets;
      isolated = lib.filter (sub: !builtins.elem sub shared) allSubnets;
    in
      lib.concatMapStrings (
        src: let
          others = lib.filter (d: d != src) isolated;
        in
          lib.optionalString (others != []) "ip saddr ${src} ip daddr { ${lib.concatStringsSep ", " others} } drop\n    "
      )
      isolated}
        # User extra rules
        ${lib.concatStringsSep "\n    " cfg.router.microvm.firewall.extraRules}

        # VM networks reach the router uplink's own LAN only when granted
        # (router-lan-control); tunnels and the internet are unaffected
        iifname != @lan_access oifname != ${lanTapSetNft} ${lib.concatMapStringsSep " " (t: "oifname != \"${t}\"") tunnelIfaces} ip daddr ${privateNets} drop

        # Allow forwarding out to WAN/VPN (any non-LAN egress)
        oifname != ${lanTapSetNft} accept
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # Masquerade on any non-LAN egress (WiFi WAN, ethernet WAN, VPN interfaces)
        oifname != ${lanTapSetNft} masquerade
      }
    }
  '';

  # Script run by QEMU *after* TUNSETIFF to bridge the TAP to its host bridge.
  # Using script= (not script=no) ensures QEMU holds the fd before bridge
  # attachment - eliminating the EBUSY race where a pre-bridged TAP blocks
  # TUNSETIFF (Linux rejects TUNSETIFF when an rx_handler is already registered).
  # TAPs are created on-demand by QEMU itself via TUNSETIFF; no pre-creation needed.
  tapBridgeScript = pkgs.writeShellScript "router-tap-bridge" ''
    TAP="$1"
    case "$TAP" in
      ${routerNics.bridgeCases nics}# Unknown infra TAPs: udev catch-all bridges them after QEMU has the fd open
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
    # Live NixOS switch via vsock:14504 (shard switch)
    ./vm-switch.nix
    # Serial console follows the attached terminal's size
    ../../common/serial-console.nix
  ];

  config = {
    assertions =
      [
        {
          assertion = wanMode != "pci-passthrough" || wifiPciAddress != "";
          message = ''
            hydrix.hardware.vfio.wifiPciAddress is empty - the router VM needs a WiFi PCI
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
      ]
      ++ routerNics.assertions nics;

    # ===== Basic Identity =====
    # storeName drives host-side paths (/var/lib/microvms/<storeName>, secrets,
    # console socket); hydrix.vm.hostname is only the name visible inside the VM.
    hydrix.vm.storeName = lib.mkDefault "microvm-router";
    hydrix.vm.hostname = lib.mkDefault cfg.vm.storeName;
    networking.hostName = lib.mkOverride 500 cfg.vm.hostname;
    system.stateVersion = "25.05";
    nixpkgs.config.allowUnfree = true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== MicroVM Configuration =====
    microvm = {
      hypervisor = "qemu";
      # Verified working with real VFIO WiFi passthrough on router-stable
      # (identical pcie-root-port + vfio-pci wiring below) before promoting
      # here.
      qemu.machine = "microvm";
      # microvm.nix's own qemu.serialConsole (default true) unconditionally
      # adds its own "-serial chardev:stdio" on top of the console.sock one
      # below - two legacy serial ports, only q35 tolerated that cleanly.
      # Only ever needed the one console.sock port to begin with.
      qemu.serialConsole = false;
      # Only disable seccomp when VFIO passthrough is in use (seccomp blocks /dev/vfio access)
      qemu.package =
        if usePciPassthrough
        then qemuNoSeccomp
        else pkgs.qemu_kvm;

      # Resources - router is lightweight (NAT/routing only, 1 vCPU sufficient)
      vcpu = 1;
      mem = 1024; # 1GB should be plenty

      balloon = true;
      deflateOnOOM = true;

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
          # Connect with: socat -,rawer unix-connect:/var/lib/microvms/${vmName}/console.sock
          "-chardev"
          "socket,id=console,path=/var/lib/microvms/${vmName}/console.sock,server=on,wait=off"
          "-serial"
          "chardev:console"
        ]
        # VFIO passthrough - only when using WiFi PCI passthrough as WAN
        ++ lib.optionals usePciPassthrough [
          "-device"
          "pcie-root-port,id=pcie.1,slot=1,chassis=1"
          # Strip "0000:" prefix if user provided full format (handles both "00:14.3" and "0000:00:14.3")
          "-device"
          "vfio-pci,host=0000:${lib.removePrefix "0000:" wifiPciAddress},bus=pcie.1"
        ]
        # LAN TAPs (and ethernet WAN), created by QEMU and bridged by tapBridgeScript
        ++ routerNics.qemuArgs tapBridgeScript nics;

      # Limit virtiofsd threads: default spawns nproc threads per share, wasteful when idle
      virtiofsd.threadPoolSize = 1;
      # Use auto cache mode (matches microvm-profile-base.nix): /nix/store files
      # have stable mtimes so they stay cached indefinitely once faulted in -
      # without this, poller-forked binaries (iw, grep, wg, jq...) re-validate
      # with the host virtiofsd on every exec instead of hitting guest cache.
      virtiofsd.extraArgs = ["--cache" "auto"];

      # ===== Shared Filesystems =====
      shares = [
        # Share host /nix/store via virtiofs
        {
          tag = "nix-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          proto = "virtiofs";
        }
        # VM config directory - used by vm-switch to receive .switch-reg nix DB dump.
        # Created by `shard build` at /var/lib/microvms/<name>/config on the host.
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

      # ===== /var/lib is ephemeral by default =====
      # /var/lib (NetworkManager connections, dnsmasq leases, VPN assignment
      # state) lives on the tmpfs root and is wiped on every restart unless
      # hydrix.router.persistence.enable is set, in which case just
      # /var/lib/NetworkManager gets a small persistent qcow2 volume so
      # runtime-added (nmcli) connections survive. Declared config (wifi.nix,
      # hydrix.router.vpn.mullvad.*) is the source of truth for anything
      # declarative either way; no `shard purge` needed to clear stale
      # runtime state.
      volumes = lib.optionals cfg.router.persistence.enable [
        {
          image = "/var/lib/microvms/${vmName}/network-manager.qcow2";
          mountPoint = "/var/lib/NetworkManager";
          size = cfg.router.persistence.size;
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
    hardware.enableRedistributableFirmware = true;

    # ===== Predictable Interface Naming =====
    # Inside the QEMU VM, virtio-net devices get kernel-assigned names (ens3, ens4, ...),
    # not the host-side TAP names. These .link files rename each interface by its
    # MAC to its TAP name, so networkd, nftables and the setup scripts can match
    # on names known at build time. router-nic-check verifies this at boot.
    systemd.network.links = routerNics.links nics;
    systemd.services.router-nic-check = routerNics.checkService pkgs nics;

    # ===== LAN Interface Configuration (systemd-networkd) =====
    # Static IPs assigned at boot - no waiting for WiFi. Mirrors microvm-router-stable.
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
            networkConfig = {
              Address = "${l.subnet}.253/24";
              DHCP = "no";
              LinkLocalAddressing = "no";
              ConfigureWithoutCarrier = "yes";
            };
          };
        })
        allLans);
    };

    # ===== Networking Configuration =====
    networking = {
      useDHCP = false;
      enableIPv6 = false;

      # NetworkManager for WiFi management only - LAN TAPs are handled by systemd-networkd
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

      # NM only manages the WAN. LAN TAPs belong to systemd-networkd, and any
      # other NIC (e.g. one whose .link rename failed) stays down rather than
      # getting a DHCP client on whatever bridge it is plugged into.
      networkmanager.unmanaged =
        ["*" "except:type:wifi"]
        ++ lib.optional useEthernetWan "except:interface-name:mv-router-wan";
      networkmanager.settings.main.no-auto-default = "*";
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
        # Routing tables - one per profile, using vsockCid as table ID (unique, stable)
        "iproute2/rt_tables".text =
          ''
            255     local
            254     main
            253     default
            0       unspec
            # Hydrix profile routing tables (ID = vsockCid)
          ''
          + lib.concatMapStrings (
            n: "  ${lib.last (lib.splitString "." n.subnet)}     ${n.name}\n"
          )
          allNetworks;

        # Runtime network map for vpn-assign: name:tableId:subnet
        # Table ID = subnet last octet (e.g. 192.168.102 → 102), same as CID by convention
        "hydrix-router/network-map".text =
          lib.concatMapStrings (
            n: "${n.name}:${lib.last (lib.splitString "." n.subnet)}:${n.subnet}.0/24\n"
          )
          allNetworks;

        # Resolver that tunnelled/blocked networks' DNS is DNATed to (vpn-assign)
        "hydrix-router/vpn-dns".text = vpnCfg.mullvad.dns;

        # Static interface name map - generated at build time from known TAP names.
        # Consumed by dnsmasq-config; no runtime detection needed since names are
        # fixed by systemd.network.links above. Variable names match what
        # dnsmasq-config expects: profile name → IFACE_<NAME>, infra → IFACE_<TAP>.
        "hydrix-router/interfaces".text =
          lib.concatMapStrings (l: let
            varName = lib.toUpper (builtins.replaceStrings ["-" "mv-router-"] ["_" ""] l.tap);
          in "IFACE_${varName}=${l.tap}\n")
          infraLans
          + lib.concatMapStrings (n: let
            varName = lib.toUpper (builtins.replaceStrings ["-"] ["_"] n.name);
          in "IFACE_${varName}=${n.routerTap}\n")
          allNetworks;
      }
      # Mullvad WireGuard conf files - processed via hydrix.router.vpn.mullvad.processConfig
      (lib.mkIf hasMullvad (
        lib.mapAttrs' (bridge: f: {
          name = "wireguard/wg-${bridge}.conf";
          value = {
            source = processConfig f;
            mode = "0600";
          };
        })
        mullvadBridges
      ))
    ];

    # ===== Fail-closed policy routing =====
    # Installed before any interface comes up. Every network gets its own
    # table (ID = subnet octet), selected by source address, holding an
    # unreachable default as its last resort, so a network is never routed by
    # the main table's WAN default unless vpn-assign says `direct` (a throw
    # route). Mullvad networks stay blocked until vpn-boot-assign brings their
    # tunnel up. Traffic *to* a router LAN always uses the main table, so
    # router replies and inter-LAN traffic never enter a tunnel table (the
    # firewall decides on inter-LAN traffic).
    systemd.services.vpn-policy-init = {
      description = "Install fail-closed per-network routing tables";
      wantedBy = ["multi-user.target"];
      wants = ["network-pre.target"];
      before = ["network-pre.target"];
      after = ["local-fs.target"];
      unitConfig.DefaultDependencies = false;
      # Idempotent, so a live switch re-runs it and picks up new rules.
      # Assignments vpn-assign already made are left alone.
      path = [pkgs.iproute2];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        table = n: lib.last (lib.splitString "." n.subnet);
      in ''
        rule() {
          ip rule del "$@" 2>/dev/null || true
          ip rule add "$@"
        }
        ${lib.concatMapStrings (l: "rule to ${l.subnet}.0/24 lookup main priority 10
") allLans}
        rule fwmark ${dnatReplyMark}/${dnatReplyMark} lookup main priority 20
        ${lib.concatMapStrings (n: ''
            rule from ${n.subnet}.0/24 lookup ${table n} priority ${table n}
            ip route replace unreachable default metric 4294967295 table ${table n}
            ${lib.optionalString (!(mullvadBridges ? ${n.name})) "[ -e /var/lib/hydrix-vpn/${n.name}.assignment ] || ip route add throw default table ${table n} 2>/dev/null || true"}
          '')
          allNetworks}
      '';
    };
    # networkd must leave vpn-assign's rules and tables alone when it restarts
    systemd.network.config.networkConfig = {
      ManageForeignRoutingPolicyRules = false;
      ManageForeignRoutes = false;
    };

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

        USE_ETHERNET_WAN="${
          if useEthernetWan
          then "true"
          else "false"
        }"

        detect_wan() {
          if [[ "$USE_ETHERNET_WAN" == "true" ]]; then
            find_iface_by_mac "${wanMac}"
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
        ${lib.concatMapStrings (s: ''            echo "server=${s}" >> /etc/dnsmasq.d/hydrix.conf
          '')
          cfg.router.microvm.dnsmasq.servers}

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
        ${lib.concatStringsSep "\n        " (map (
            l: "add_iface \"${l.tap}\" \"${l.subnet}\" \"${l.subnet}.253\""
          )
          infraLans)}
        # Profile + extra networks (from profiles/*/meta.nix + extraNetworks)
        ${lib.concatStringsSep "\n        " (map (n: let
          varName = lib.toUpper (builtins.replaceStrings ["-"] ["_"] n.name);
        in "add_iface \"$IFACE_${varName}\" \"${n.subnet}\" \"${n.subnet}.253\"")
        allNetworks)}

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
    # - Each LAN only accepts its own subnet as source (anti-spoofing)
    # - No new connections from the WAN side reach the router
    # - SSH is disabled entirely (services.openssh.enable = false)
    # - Host manages router via console only (vsock/serial)
    #
    # Loaded before any interface comes up. A reload atomically replaces only
    # `table inet router`, so tables owned by others (router-lan-control's
    # iptables rules, tailscaled) survive it; DNS redirects are then restored
    # from vpn-assign's saved assignments.
    systemd.services.router-firewall = {
      description = "Configure router firewall";
      wantedBy = ["multi-user.target"];
      wants = ["network-pre.target"];
      before = ["network-pre.target" "shutdown.target"];
      after = ["local-fs.target" "systemd-modules-load.service"];
      conflicts = ["shutdown.target"];
      unitConfig.DefaultDependencies = false;
      path = [pkgs.nftables vpnAssign];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        nft -f ${firewallRules}
        vpn-assign sync-dns >/dev/null 2>&1 || true
        echo "Router firewall loaded (DHCP/DNS only from VMs, inter-VM blocked, no WAN input)"
      '';
    };

    # ===== Mullvad Boot-Assign Service =====
    # Connects configured tunnels and routes bridges at startup.
    # Generated from vpn.mullvad.bridges - no hardcoded network names.
    systemd.services.vpn-boot-assign = lib.mkIf hasMullvad {
      description = "Apply Mullvad VPN bridge assignments";
      after = ["network-online.target" "router-firewall.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.wireguard-tools pkgs.iproute2 vpnAssign];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        # Connect each configured tunnel. A tunnel that fails to connect leaves
        # its network blocked, never direct: its traffic must not leave
        # outside the tunnel. If the interface already exists (service
        # restarted after partial run),
        # skip wg-quick and re-apply routing from whatever state the tunnel is in.
        lib.concatMapStrings (bridge: ''
          echo "Connecting wg-${bridge}..."
          if ip link show wg-${bridge} &>/dev/null; then
            echo "wg-${bridge} already up, re-applying routing"
            vpn-assign ${bridge} wg-${bridge}
          elif wg-quick up wg-${bridge}; then
            vpn-assign ${bridge} wg-${bridge}
          else
            echo "Warning: wg-${bridge} failed to connect, ${bridge} stays blocked"
            vpn-assign ${bridge} blocked
          fi
        '') (lib.attrNames mullvadBridges)
        # All other known networks go direct
        + lib.concatMapStrings (
          n:
            lib.optionalString (!lib.hasAttr n.name mullvadBridges) ''
              vpn-assign ${n.name} direct
            ''
        )
        allNetworks;
    };

    # ===== Allowed-Access VPN Bypass =====
    # Mirrors the LAN-bypass trick each allowedAccessTo destination needs if
    # it has its own outbound VPN policy-routing table: without this, return
    # traffic to the allowed source gets pulled into that table's tunnel
    # interface and dropped instead of going out the destination's own
    # bridge. Runs after vpn-boot-assign so it always wins regardless of
    # whether that table exists yet.
    systemd.services.router-access-bypass = lib.mkIf (cfg.router.microvm.firewall.allowedAccessTo != []) {
      description = "VPN policy-route bypass for allowedAccessTo pairs";
      after = ["vpn-boot-assign.service"];
      wants = ["vpn-boot-assign.service"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.iproute2];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # Bypass needed in both directions: the source subnet's own outbound
      # policy table (e.g. its Mullvad exit-node table) may have no route to
      # the destination at all ("Network is unreachable"), and symmetrically
      # the destination's table may not route back to the source either.
      script =
        lib.concatMapStrings (a: ''
          ip rule del from ${a.to}/32 to ${a.from} lookup main priority 100 2>/dev/null || true
          ip rule add from ${a.to}/32 to ${a.from} lookup main priority 100
          ip rule del from ${a.from} to ${a.to}/32 lookup main priority 100 2>/dev/null || true
          ip rule add from ${a.from} to ${a.to}/32 lookup main priority 100
        '')
        cfg.router.microvm.firewall.allowedAccessTo;
    };

    # ===== Router Stats =====
    # WiFi/NM state and WireGuard peer status are sampled by
    # router-netlink-poller (router-netlink-poller.c); geo-lookup runs in
    # router-geo-refresh. Network throughput has no sampler: router-stats-server
    # measures it per NET/ALL request from /proc/net/dev.

    # See routerNetlinkPollerBin's comment above and router-netlink-poller.c
    # for what this queries and writes.
    systemd.services.router-netlink-poller = {
      description = "Router WiFi/WireGuard native-netlink poller";
      wantedBy = ["multi-user.target"];
      after = ["NetworkManager.service" "network.target"];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${routerNetlinkPollerBin}/bin/router-netlink-poller ${routerPollInterval} ${
          if cfg.router.polling.enableWgStatus
          then "1"
          else "0"
        }";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Resolves WireGuard peer endpoint IPs to city/country via the Mullvad
    # relay list, falling back to ipinfo.io, and caches each result at
    # /tmp/wg-loc-<ip>. Reads endpoint IPs from wg-status.json
    # (router-netlink-poller writes that file and only ever reads this
    # cache, never populates it). The 300s interval is fine since a peer's
    # location only changes if its endpoint IP does, and lookup_location
    # skips any IP already cached.
    systemd.services.router-geo-refresh = lib.mkIf cfg.router.polling.enableWgStatus {
      description = "WireGuard peer geo-location cache refresh";
      wantedBy = ["multi-user.target"];
      after = ["router-netlink-poller.service"];
      serviceConfig = {
        Type = "simple";
        ExecStart = let
          refresher = pkgs.writeShellScript "router-geo-refresh" ''
            relay_cache="/tmp/wg-mullvad-relays.json"

            refresh_relay_cache() {
              local now relay_age
              now=$(date +%s)
              relay_age=0
              [ -f "$relay_cache" ] && relay_age=$(( now - $(stat -c %Y "$relay_cache" 2>/dev/null || echo 0) ))
              if [ ! -f "$relay_cache" ] || [ "$relay_age" -gt 3600 ]; then
                ${pkgs.curl}/bin/curl -sf --max-time 15 "https://api.mullvad.net/www/relays/all/" 2>/dev/null \
                  > "$relay_cache.tmp" && mv "$relay_cache.tmp" "$relay_cache" || true
              fi
            }

            lookup_location() {
              local ip="$1" cache loc city country result
              cache="/tmp/wg-loc-''${ip}"
              if [ -f "$cache" ]; then
                return
              fi

              city=""; country=""

              # Try Mullvad relay list first
              if [ -f "$relay_cache" ]; then
                city=$(${pkgs.jq}/bin/jq -r --arg ip "$ip" \
                  '.[] | select(.ipv4_addr_in == $ip) | .city_name // empty' \
                  "$relay_cache" 2>/dev/null | head -1 || true)
                country=$(${pkgs.jq}/bin/jq -r --arg ip "$ip" \
                  '.[] | select(.ipv4_addr_in == $ip) | .country_code // empty' \
                  "$relay_cache" 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]' || true)
              fi

              # Fall back to ipinfo.io
              if [ -z "$city" ] || [ -z "$country" ]; then
                result=$(${pkgs.curl}/bin/curl -sf --max-time 10 "https://ipinfo.io/''${ip}/json" 2>/dev/null || true)
                city=$(echo    "$result" | ${pkgs.jq}/bin/jq -r '.city    // empty' 2>/dev/null || true)
                country=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.country // empty' 2>/dev/null || true)
              fi

              if [ -n "$city" ] && [ -n "$country" ]; then
                loc="''${city}, ''${country}"
              else
                loc="$ip"
              fi
              echo "$loc" > "$cache"
            }

            while true; do
              refresh_relay_cache
              if [ -f /tmp/wg-status.json ]; then
                while IFS= read -r ip; do
                  [ -n "$ip" ] || continue
                  lookup_location "$ip"
                done < <(${pkgs.jq}/bin/jq -r '.[].endpoint' /tmp/wg-status.json 2>/dev/null | sort -u)
              fi
              sleep 300
            done
          '';
        in "${refresher}";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Persistent no-fork vsock server (port 14506). Handles POLL/STATUS/ADD/
    # REMOVE (unchanged wire protocol, scripts/wifi-sync.sh needs no changes)
    # plus NET/ALL/WG, consolidating what used to be three separate ports
    # (14506/14515/14517) onto this one process, and WEATHER/VPN/VPNSET for
    # the host eww dashboard. See router-stats-server.c.
    systemd.services.router-stats-server = {
      description = "Router stats vsock server (port 14506)";
      wantedBy = ["multi-user.target"];
      after = ["router-netlink-poller.service"];
      # VPNSET execs vpn-assign, which needs the same tools as vpn-boot-assign.
      path = lib.optionals hasMullvad [vpnAssign];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${routerStatsServerBin}/bin/router-stats-server${lib.optionalString (!cfg.router.polling.enableNetStats) " --no-net"}";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Weather relay for the host's eww widget, which has no internet of its
    # own in lockdown mode. router-stats-server's WEATHER command records the
    # host's coordinate list in /tmp/weather-request (already validated to
    # digits and ".,- "); this fetches the Open-Meteo forecast for it when it
    # changes and every 15 minutes after, into /tmp/weather.json.
    systemd.paths.router-weather = {
      wantedBy = ["multi-user.target"];
      pathConfig.PathChanged = "/tmp/weather-request";
    };

    systemd.timers.router-weather = {
      wantedBy = ["timers.target"];
      timerConfig.OnUnitActiveSec = "15min";
    };

    systemd.services.router-weather = {
      description = "Fetch weather forecast for the host";
      unitConfig.ConditionPathExists = "/tmp/weather-request";
      serviceConfig.Type = "oneshot";
      script = ''
        read -r lats lons < /tmp/weather-request
        case "$lats$lons" in *[!0-9.,-]*|"") exit 0 ;; esac
        data=$(${pkgs.curl}/bin/curl -sf --max-time 15 \
          "https://api.open-meteo.com/v1/forecast?latitude=$lats&longitude=$lons&current=temperature_2m,weather_code,is_day&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=3&timezone=auto") \
          || exit 0
        printf '{"query":"%s %s","fetched":%s,"data":%s}\n' "$lats" "$lons" "$(date +%s)" "$data" \
          > /tmp/weather.json.tmp
        mv /tmp/weather.json.tmp /tmp/weather.json
      '';
    };

    # ===== WiFi from Sops =====
    # Reads /mnt/vm-secrets/wifi/networks.json (delivered by host hydrix-secrets service)
    # and creates NM connections for each network. No-op when file is absent so
    # non-sops deployments (credentials still in modules/wifi.nix) are unaffected.
    systemd.services.hydrix-wifi-from-sops = {
      description = "Configure WiFi networks from sops secrets";
      wantedBy = ["network.target"];
      after = ["NetworkManager.service"];
      before = ["network.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        jq = "${pkgs.jq}/bin/jq";
        nmcli = "${pkgs.networkmanager}/bin/nmcli";
      in ''
        set -euo pipefail
        WIFI_FILE="/mnt/vm-secrets/wifi/networks.json"
        [ -f "$WIFI_FILE" ] || { echo "No wifi secrets - skipping"; exit 0; }
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
    environment.systemPackages = with pkgs;
      [
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
      ]
      ++ lib.optionals hasMullvad [
        wireguard-tools
        vpnAssign
        vpnStatus
      ]
      ++ cfg.router.microvm.extraPackages;

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
