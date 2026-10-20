# Host USB handling
#
# Storage: the host kernel never binds USB storage (usb_storage and uas are
# blocked, in the initrd too), so an untrusted stick is never parsed here: no
# /dev/sdX, no partition scan, no filesystem probing. Plugging one in only
# sends a notification. The `usb` command hands the whole USB device to a VM
# after a y/N confirmation on the host:
#
#   usb list                       storage devices and where they are attached
#   usb attach <busid> <vm> [-y]   to a running microVM whose meta.nix sets
#                                  usbPassthrough = true, or a libvirt domain
#   usb detach <busid>             take it back (unmount inside the VM first)
#   usb host on|off|status         let the host kernel read USB storage, on demand
#
# `usb host on` loads usb_storage/uas explicitly (modprobe --ignore-install skips the
# block for the module it names), after a y/N: sticks then appear as /dev/sdX on the host,
# for mounting there or virt-manager's own USB dialog. `usb host off` unloads them again
# (refused while a USB disk is mounted). Nothing persists: every boot starts blocked.
#
# Inside a Hydrix microVM the device arrives read-only; `usb-rw <dev>` there
# makes it writable. A fallback/recovery specialisation should set
# hydrix.usb.blockHostStorage = false so install media works on the host.
#
# Static devices: a VM whose meta.nix lists usbDevices ("vvvv:pppp") gets
# those devices at start (vm/microvm/usb-passthrough.nix); the host grants the
# kvm group access to exactly those vendor:product IDs.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.usb;
  falseBin = "${pkgs.coreutils}/bin/false";

  staticDevices = lib.unique (lib.concatMap (v: v.usbDevices) (lib.attrValues config.hydrix.networking.vmRegistry));
  deviceRule = id: let
    p = lib.splitString ":" id;
  in ''SUBSYSTEM=="usb", ATTR{idVendor}=="${lib.elemAt p 0}", ATTR{idProduct}=="${lib.elemAt p 1}", GROUP="kvm", MODE="0660"'';

  notifyScript = pkgs.writeShellScript "hydrix-usb-notify" ''
    busid=''${1%%:*}
    product=$(cat "/sys/bus/usb/devices/$busid/product" 2>/dev/null || echo "USB storage")
    if [ -d /sys/module/usb_storage ]; then
      body="$product ($busid). Host USB storage is ON (usb host on): the host kernel reads it.
    Block it again: usb host off"
    else
      body="$product ($busid), not mounted on the host.
    To pass it to a VM: usb attach $busid <vm>"
    fi
    # Critical: swaync keeps it until clicked (timeout-critical 0; it ignores -t 0), so a
    # stick plugged in while away is not missed.
    ${pkgs.libnotify}/bin/notify-send -a usb -u critical "USB storage plugged in" "$body"
  '';

  usbCli = pkgs.writeShellScriptBin "usb" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [pkgs.jq pkgs.socat pkgs.coreutils pkgs.gnugrep pkgs.util-linux pkgs.libnotify]}:$PATH
    MODPROBE=${pkgs.kmod}/bin/modprobe
    BLOCKED=${lib.boolToString cfg.blockHostStorage}
    REGISTRY=/etc/hydrix/vm-registry.json
    STATE="''${XDG_RUNTIME_DIR:-/tmp}/hydrix-usb"
    LIBVIRT=qemu:///system
    mkdir -p "$STATE"

    die() { echo "usb: $*" >&2; exit 1; }
    attr() { cat "/sys/bus/usb/devices/$1/$2" 2>/dev/null || echo "?"; }
    devnode() { printf '/dev/bus/usb/%03d/%03d' "$((10#$(attr "$1" busnum)))" "$((10#$(attr "$1" devnum)))"; }
    describe() { echo "$(attr "$1" idVendor):$(attr "$1" idProduct) $(attr "$1" manufacturer) $(attr "$1" product), serial $(attr "$1" serial)"; }
    is_storage() {
      local f
      for f in "/sys/bus/usb/devices/$1/$1":*/bInterfaceClass; do
        [ "$(cat "$f" 2>/dev/null)" = 08 ] && return 0
      done
      return 1
    }
    # Registry key or vmName of a microVM that opted in (meta.nix usbPassthrough).
    microvm_of() {
      jq -r --arg v "$1" 'to_entries[]
        | select((.key == $v or .value.vmName == $v) and .value.usbPassthrough == true)
        | .value.vmName' "$REGISTRY" 2>/dev/null | head -n1
    }
    # QMP socket: <hostname>.sock in the VM's state dir; not virtiofs or console.
    qmp_sock() {
      local dir=/var/lib/microvms/$1 s
      if [ -S "$dir/$1.sock" ]; then echo "$dir/$1.sock"; return 0; fi
      for s in "$dir"/*.sock; do
        case "$s" in *-virtiofs-* | */console.sock | */monitor.sock) ;; *) [ -S "$s" ] && { echo "$s"; return 0; } ;; esac
      done
      return 1
    }
    qmp() {
      printf '{"execute":"qmp_capabilities"}\n%s\n' "$2" | sudo socat -t2 - "UNIX-CONNECT:$1"
    }
    host_on() { [ -d /sys/module/usb_storage ]; }
    host_mode() {
      if [ "$BLOCKED" != true ]; then echo "allowed (hydrix.usb.blockHostStorage = false)"
      elif host_on; then echo "ON until 'usb host off' or reboot"
      else echo "blocked"; fi
    }
    # Host block devices (/dev/sdX) of a USB device, empty while the host does not read it.
    host_disks() {
      local b
      for b in /sys/block/sd*; do
        [ -e "$b" ] || continue
        case "$(readlink -f "$b")" in */"$1"/*) echo "/dev/$(basename "$b")" ;; esac
      done
    }
    # Mount points on a disk or its partitions
    disk_mounts() { lsblk -nro MOUNTPOINTS "$1" 2>/dev/null | grep -v '^$' || true; }
    hostdev_xml() {
      printf "<hostdev mode='subsystem' type='usb' managed='yes'><source><address bus='%d' device='%d'/></source></hostdev>\n" \
        "$((10#$(attr "$1" busnum)))" "$((10#$(attr "$1" devnum)))"
    }

    cmd=''${1:-}
    shift || true
    case "$cmd" in
      list)
        echo "USB storage devices:"
        found=0
        for d in /sys/bus/usb/devices/*; do
          b=$(basename "$d")
          [[ "$b" == *:* ]] && continue
          [ -f "$d/idVendor" ] && is_storage "$b" || continue
          found=1
          at=-
          if [ -f "$STATE/$b" ]; then
            read -r _ vm node < "$STATE/$b"
            # A replug gets a new device node: the old attachment is gone.
            if [ "$node" = "$(devnode "$b")" ]; then at=$vm; else rm -f "$STATE/$b"; fi
          fi
          printf '  %-10s %s\n             attached: %s\n' "$b" "$(describe "$b")" "$at"
          disks=$(host_disks "$b" | tr '\n' ' ')
          [ -n "$disks" ] && printf '             on the host: %s\n' "$disks"
        done
        [ "$found" = 1 ] || echo "  (none)"
        echo
        echo "Host USB storage: $(host_mode)"
        echo "microVMs accepting USB devices: $(jq -r '[to_entries[] | select(.value.usbPassthrough == true) | .key] | join(" ")' "$REGISTRY" 2>/dev/null)"
        echo "libvirt domains also work: usb attach <busid> <domain>"
        ;;

      attach)
        busid=''${1:-}
        target=''${2:-}
        [ -n "$busid" ] && [ -n "$target" ] || die "usage: usb attach <busid> <vm> [-y]"
        [ -d "/sys/bus/usb/devices/$busid" ] || die "no USB device $busid (see: usb list)"
        is_storage "$busid" || die "$busid is not a USB storage device"
        [ -f "$STATE/$busid" ] && die "$busid is already attached to $(cut -d' ' -f2 "$STATE/$busid")"
        node=$(devnode "$busid")
        for d in $(host_disks "$busid"); do
          [ -z "$(disk_mounts "$d")" ] || die "$busid is mounted on the host ($d), unmount it first"
        done
        vm=$(microvm_of "$target")
        if [ -n "$vm" ]; then
          kind=microvm
          [ -L "/run/systemd/units/invocation:microvm@$vm.service" ] || die "$vm is not running"
        elif command -v virsh >/dev/null && virsh --connect "$LIBVIRT" dominfo "$target" >/dev/null 2>&1; then
          kind=libvirt
          vm=$target
        else
          die "$target is neither a microVM with usbPassthrough (meta.nix) nor a libvirt domain"
        fi

        echo "Device: $(describe "$busid")"
        echo "Busid:  $busid ($node)"
        echo "Target: $vm ($kind)"
        if [ "''${3:-}" != -y ]; then
          read -rp "Attach this device to $vm? [y/N] " answer
          case "$answer" in y | Y | yes) ;; *) echo "Cancelled."; exit 1 ;; esac
        fi

        case "$kind" in
          microvm)
            sock=$(qmp_sock "$vm") || die "no QMP socket for $vm"
            sudo chown microvm:kvm "$node"
            out=$(qmp "$sock" "{\"execute\":\"device_add\",\"arguments\":{\"driver\":\"usb-host\",\"bus\":\"xhci.0\",\"hostdevice\":\"$node\",\"id\":\"usb-$busid\"}}") || out=""
            if grep -q '"error"' <<< "$out" || ! grep -q '"return"' <<< "$out"; then
              sudo chown root:root "$node"
              die "QEMU refused the device: $(grep -o '"desc": *"[^"]*"' <<< "$out" || echo "$out")"
            fi
            ;;
          libvirt)
            virsh --connect "$LIBVIRT" attach-device "$vm" <(hostdev_xml "$busid") --live >/dev/null
            ;;
        esac
        echo "$kind $vm $node" > "$STATE/$busid"
        echo "Attached $busid to $vm."
        if [ "$kind" = microvm ]; then
          echo "It arrives read-only there; run 'usb-rw <dev>' inside the VM to write."
        fi
        ;;

      detach)
        busid=''${1:-}
        [ -n "$busid" ] || die "usage: usb detach <busid>"
        [ -f "$STATE/$busid" ] || die "$busid is not attached (see: usb list)"
        read -r kind vm node < "$STATE/$busid"
        case "$kind" in
          microvm)
            if sock=$(qmp_sock "$vm"); then
              qmp "$sock" "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"usb-$busid\"}}" >/dev/null || true
            fi
            sudo chown root:root "$node" 2>/dev/null || true
            ;;
          libvirt)
            virsh --connect "$LIBVIRT" detach-device "$vm" <(hostdev_xml "$busid") --live >/dev/null || true
            ;;
        esac
        rm -f "$STATE/$busid"
        echo "Detached $busid from $vm."
        ;;

      host)
        case "''${1:-status}" in
          status)
            echo "Host USB storage: $(host_mode)"
            ;;
          on)
            [ "$BLOCKED" = true ] || die "host USB storage is not blocked in this boot mode"
            host_on && { echo "Host USB storage is already on."; exit 0; }
            echo "The host kernel will read every USB stick plugged in from now on: partition"
            echo "tables and filesystems are parsed here, not in a VM. Use it for a stick you trust,"
            echo "or one going to a libvirt VM through virt-manager. Until 'usb host off' or reboot."
            if [ "''${2:-}" != -y ]; then
              read -rp "Let the host read USB storage? [y/N] " answer
              case "$answer" in y | Y | yes) ;; *) echo "Cancelled."; exit 1 ;; esac
            fi
            # usb_storage first: --ignore-install only applies to the module named.
            sudo "$MODPROBE" --ignore-install usb_storage
            sudo "$MODPROBE" --ignore-install uas
            notify-send -a usb "Host USB storage ON" "Sticks appear as /dev/sdX on the host until 'usb host off' or reboot." || true
            echo "Host USB storage is on. Plugged-in sticks appear as /dev/sdX (lsblk)."
            ;;
          off)
            [ "$BLOCKED" = true ] || die "host USB storage is not blocked in this boot mode"
            host_on || { echo "Host USB storage is already blocked."; exit 0; }
            for d in $(lsblk -dnrpo NAME,TRAN | grep ' usb$' | cut -d' ' -f1); do
              m=$(disk_mounts "$d")
              [ -z "$m" ] || die "$d is mounted ($(tr '\n' ' ' <<< "$m")), unmount it first"
            done
            sudo "$MODPROBE" -r uas usb_storage || die "could not unload usb_storage (still in use?)"
            notify-send -a usb "Host USB storage blocked" "USB sticks are no longer read by the host." || true
            echo "Host USB storage is blocked again."
            ;;
          *) die "usage: usb host on [-y] | off | status" ;;
        esac
        ;;

      *)
        echo "usage: usb list | attach <busid> <vm> [-y] | detach <busid> | host on|off|status"
        exit 1
        ;;
    esac
  '';
in {
  imports = [
    (lib.mkRenamedOptionModule ["hydrix" "usbSandbox" "blockHostStorage"] ["hydrix" "usb" "blockHostStorage"])
  ];

  options.hydrix.usb.blockHostStorage = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Keep the host kernel from binding USB storage (usb_storage, uas), so
      sticks are only ever parsed by the VM they are attached to. Set false in
      a fallback/recovery specialisation so install media works on the host.
    '';
  };

  config = lib.mkIf (config.hydrix.vmType == "host") (lib.mkMerge [
    {environment.systemPackages = [usbCli];}

    (lib.mkIf (staticDevices != []) {
      services.udev.extraRules = lib.concatMapStringsSep "\n" deviceRule staticDevices;
    })

    (lib.mkIf cfg.blockHostStorage {
      boot.blacklistedKernelModules = ["usb_storage" "uas"];
      # Also lands in the initrd: both initrd flavours embed modprobe.d/nixos.conf.
      boot.extraModprobeConfig = ''
        install usb_storage ${falseBin}
        install uas ${falseBin}
      '';

      # Plugging in a stick only notifies; nothing is attached until `usb attach`.
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTR{bInterfaceClass}=="08", TAG+="systemd", ENV{SYSTEMD_USER_WANTS}+="hydrix-usb-notify@%k.service"
      '';
      systemd.user.services."hydrix-usb-notify@" = {
        description = "Notify about plugged-in USB storage %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${notifyScript} %i";
        };
      };
    })
  ]);
}
