# Router NIC table, shared by microvm-router.nix and microvm-router-stable.nix.
#
# Each router builds one list of NIC records ({ tap, subnet, bridge, mac }) and
# derives its QEMU -netdev args, its MAC -> name .link files, its TAP -> bridge
# wiring and a boot-time check from that one list, so they cannot disagree
# about which NIC is which.
#
# MAC plan (02:00:00:<role>:<id>:<n>, locally administered):
#   00, 02  VM NICs (profile VMs hash-based, infra VMs from their meta.nix tapMac)
#   06      main router LAN NICs
#   07      router-stable LAN NICs
# For router NICs <id> is the third octet of the LAN's subnet, unique per LAN
# because the router owns .253 on each. MACs therefore never shift when a
# network is added or removed, and never overlap a VM's MAC on the same bridge.
{lib}: let
  hex2 = n: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString n));
  octet = subnet: lib.toInt (lib.last (lib.splitString "." subnet));
  dupes = xs: lib.unique (lib.filter (x: lib.count (y: y == x) xs > 1) xs);
in {
  # role: "06" main router, "07" router-stable. bridge = null leaves the TAP
  # to the host's udev catch-all.
  mkNic = role: {
    tap,
    subnet,
    bridge ? null,
  }: {
    inherit tap subnet bridge;
    mac = "02:00:00:${role}:${hex2 (octet subnet)}:01";
  };

  qemuArgs = script: nics:
    lib.concatMap (n: [
      "-netdev"
      "tap,id=net-${n.tap},ifname=${n.tap},script=${script},downscript=no"
      "-device"
      "virtio-net-pci,netdev=net-${n.tap},mac=${n.mac}"
    ])
    nics;

  links = nics:
    lib.listToAttrs (map (n: {
        name = "10-${n.tap}";
        value = {
          matchConfig.MACAddress = n.mac;
          linkConfig.Name = n.tap;
        };
      })
      nics);

  # case arms for the QEMU tap script: `<tap>) BRIDGE="<bridge>" ;;`
  bridgeCases = nics:
    lib.concatMapStrings (n: "${n.tap}) BRIDGE=\"${n.bridge}\" ;;\n      ")
    (lib.filter (n: n.bridge != null) nics);

  assertions = nics: let
    macs = dupes (map (n: n.mac) nics);
    taps = dupes (map (n: n.tap) nics);
    long = lib.filter (n: lib.stringLength n.tap > 15) nics;
    badSubnet = lib.filter (n: n.subnet != null && !(builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" n.subnet != null && octet n.subnet <= 255)) nics;
  in [
    {
      assertion = macs == [];
      message = "Router NICs share MAC(s) ${toString macs}: two LANs use the same subnet.";
    }
    {
      assertion = taps == [];
      message = "Router NICs share TAP name(s): ${toString taps}.";
    }
    {
      assertion = long == [];
      message = "Router TAP names over 15 chars: ${toString (map (n: n.tap) long)}.";
    }
    {
      assertion = badSubnet == [];
      message = "Router LAN subnets must be a three-octet prefix like 192.168.103: ${toString (map (n: n.subnet) badSubnet)}.";
    }
  ];

  # Boot check: every NIC got its declared name, and no virtio NIC was left
  # under a kernel name (a MAC with no matching .link file).
  checkService = pkgs: nics: {
    description = "Verify router LAN NICs were renamed by MAC";
    wantedBy = ["multi-user.target"];
    after = ["systemd-udev-settle.service" "systemd-networkd.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [pkgs.coreutils];
    script = ''
      fail=0
      for tap in ${lib.concatMapStringsSep " " (n: n.tap) nics}; do
        [ -e "/sys/class/net/$tap" ] || { echo "<3>missing NIC $tap"; fail=1; }
      done
      for dev in /sys/class/net/*; do
        name=''${dev##*/}
        [ -e "$dev/device" ] || continue
        [ -d "$dev/wireless" ] && continue
        case " ${lib.concatMapStringsSep " " (n: n.tap) nics} " in
          *" $name "*) ;;
          *) echo "<3>unexpected NIC $name ($(cat "$dev/address")), left unconfigured"; fail=1 ;;
        esac
      done
      exit $fail
    '';
  };
}
