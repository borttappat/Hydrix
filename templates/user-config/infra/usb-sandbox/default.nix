# USB Sandbox Infra VM - NixOS Configuration
#
# Ephemeral VM for safely handling USB storage devices.
# USB devices are passed through via QEMU USB hotplug (no network bridge to host).
# The host sends device_add/device_del commands to the QEMU monitor socket.
#
# File transfer to/from other VMs uses the shared files-agent (vsock 14506),
# imported via flake.nix (hydrix.microvm.filesAgent = true in meta.nix) —
# same agent every profile VM uses, no separate copy here.
#
#   microvm files transfer <src-vm>/<path> usb-sandbox/shared/
#   microvm files transfer usb-sandbox/shared/<path> <dst-vm>/<dest>
#
# Paths are relative to /home/sandbox/ inside the VM.
# Mount USB drives at /home/sandbox/usb/ for convenient access.
{ config, lib, pkgs, ... }:

let
  meta = import ./meta.nix;

  sandboxUser = "sandbox";
  sandboxHome = "/home/${sandboxUser}";
  vmName      = "microvm-usb-sandbox";

in {
  # The shared files-agent.nix (imported externally via flake.nix) expects
  # config.hydrix.username to match this VM's actual user/home directory —
  # override the host-username default that mkInfraVm applies to all infra VMs.
  hydrix.username = lib.mkForce sandboxUser;
  # Scopes the files-agent's port-8888 firewall rule to the files VM's IP on
  # this bridge, same as every profile VM's default.nix does from its own meta.nix.
  hydrix.networking.vmSubnet = meta.subnet;

  # =========================================================================
  # MICROVM CONFIGURATION
  # =========================================================================
  microvm = {
    # Ephemeral rootfs is tmpfs, sized ~50% of this by microvm-nix — needs real
    # headroom since transient transfer blobs (~/shared/xfer.enc) land there
    # before extraction. 4096 gives ~2GB of usable space for that.
    mem  = 4096;

    interfaces = [{
      type = "tap";
      id   = meta.tapId;
      mac  = meta.tapMac;
    }];

    vsock.cid = meta.vsockCid;

    # QEMU monitor socket for host-side disk hotplug
    # Host sends: drive_add + device_add virtio-blk-pci  (no libusb needed)
    #             device_del + drive_del to release
    # -sandbox off: microvm.nix sets -sandbox on by default, which blocks openat()
    # for new devices after init — needed for drive_add hotplug to work.
    qemu.extraArgs = [
      "-sandbox"  "off"
      "-chardev" "socket,id=monitor,path=/var/lib/microvms/${vmName}/monitor.sock,server=on,wait=off"
      "-mon"     "chardev=monitor,mode=readline"
    ];
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # =========================================================================
  # NETWORK
  # =========================================================================
  networking.useDHCP = lib.mkForce false;

  systemd.network = {
    enable = true;
    networks."10-usb-sandbox" = {
      matchConfig.MACAddress = meta.tapMac;
      address = [ "${meta.subnet}.10/24" ];
      # No gateway — isolated bridge, files VM only, no internet
      linkConfig.RequiredForOnline = "no";
    };
  };

  # =========================================================================
  # HOME LAYOUT
  # Files agent (vsock 14506) is imported externally via flake.nix — it owns
  # ~/shared and the port-8888 HTTP transfer service itself.
  # =========================================================================
  systemd.tmpfiles.rules = [
    "d ${sandboxHome}     0750 ${sandboxUser} users -"
    "d ${sandboxHome}/usb 0750 ${sandboxUser} users -"
  ];

  networking.firewall.enable = lib.mkForce true;

  # =========================================================================
  # USERS
  # =========================================================================
  users.groups.sandbox = {};
  users.users.sandbox = {
    isNormalUser = true;
    group        = "sandbox";
    extraGroups  = [ "wheel" "disk" ];
    password     = "sandbox";
    shell        = pkgs.bash;
  };
  services.getty.autologinUser = sandboxUser;

  users.motd = ''

    ╔══════════════════════════════════════════════════════╗
    ║              USB SANDBOX  —  microvm-usb-sandbox     ║
    ╚══════════════════════════════════════════════════════╝

    The USB drive appears as /dev/vdb once attached from the host.
    Read-only unless the host ran 'usb attach <busid> --rw'.
    Files leave only via the files VM — nothing else has egress.

    COMMANDS
      usb list                    — show block devices + mount state
      usb scan                    — detect filesystems on /dev/vdb*
      usb mount /dev/vdbX         — mount under ~/usb/ (reports read-only/read-write)
      usb mount /dev/vdbX --owner — as above + own the files as $(whoami) (FAT/exFAT only)
      usb umount /dev/vdbX        — unmount
      lsusb                       — USB device info
      lsblk                       — block device tree

    FILE TRANSFER (from host, via the files VM)
      microvm files transfer <src-vm>/<path> usb-sandbox/shared/
        → lands at ~/shared/<name> here; 'cp' it into ~/usb/vdbX/ once mounted read-write
      microvm files transfer usb-sandbox/shared/<path> <dst-vm>/<dest>
        → send a file back out the same way

    Ctrl+] to detach console (VM keeps running)

  '';

  # =========================================================================
  # PACKAGES
  # =========================================================================
  environment.systemPackages = with pkgs; [
    # USB & filesystem inspection
    usbutils exfatprogs ntfs3g
    # Partitioning/formatting
    dosfstools util-linux
    # Utilities
    gawk gnugrep gnused unzip p7zip iproute2 file
    # USB helper
    (writeShellScriptBin "usb" ''
      set -uo pipefail
      USB_DIR="${sandboxHome}/usb"
      mkdir -p "$USB_DIR"

      usage() {
        echo "Usage: usb <command>"
        echo ""
        echo "  list                    show block devices + mount state"
        echo "  scan                    detect filesystems on /dev/vdb*"
        echo "  mount /dev/vdbX [--owner]"
        echo "                          mount under ~/usb/, reports read-only/read-write"
        echo "                          --owner: add uid=/gid=$(id -u) (FAT/exFAT only)"
        echo "  umount /dev/vdbX        unmount"
        echo ""
        echo "File transfer (run on the host, not in here):"
        echo "  microvm files transfer <src-vm>/<path> usb-sandbox/shared/"
        echo "  microvm files transfer usb-sandbox/shared/<path> <dst-vm>/<dest>"
      }

      case "''${1:-}" in
        list)
          lsblk -o NAME,SIZE,FSTYPE,LABEL,RO,MOUNTPOINT 2>/dev/null || echo "No block devices"
          ;;
        scan)
          for dev in /dev/sd[a-z] /dev/sd[a-z][0-9] /dev/vd[b-z] /dev/vd[b-z][0-9]; do
            [ -b "$dev" ] || continue
            FS=$(${pkgs.file}/bin/file -bs "$dev" | cut -d: -f1)
            echo "$dev: $FS"
          done
          ;;
        mount)
          DEV="$2"
          if [ -z "$DEV" ]; then
            usage
            exit 1
          fi
          OWNER_OPT=""
          [ "''${3:-}" = "--owner" ] && OWNER_OPT="-o uid=$(id -u),gid=$(id -g)"
          MP="$USB_DIR/$(basename "$DEV")"
          mkdir -p "$MP"
          if ! sudo mount -t auto $OWNER_OPT "$DEV" "$MP"; then
            echo "Mount failed — run 'usb scan' to check the filesystem was detected"
            exit 1
          fi
          if [ "$(sudo blockdev --getro "$DEV" 2>/dev/null)" = "1" ]; then
            echo "Mounted $DEV at $MP (READ-ONLY — host must run 'usb attach <busid> --rw' for write access)"
          else
            echo "Mounted $DEV at $MP (read-write)"
          fi
          ;;
        umount)
          DEV="$2"
          if [ -z "$DEV" ]; then
            echo "Usage: usb umount /dev/vdbX"
            exit 1
          fi
          sudo umount "$USB_DIR/$(basename "$DEV")"
          ;;
        *)
          usage
          ;;
      esac
    '')
  ];

}
