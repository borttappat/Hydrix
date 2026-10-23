# Hostsync infra VM - secure host file inbox
#
# Receives encrypted file transfers through the files VM and decrypts them
# into /mnt/host-inbox/, which is virtiofs-shared to ~/vm-inbox/ on the host.
# No internet access. Only the files VM (192.168.214.2) can reach port 8888.
#
# Usage from host:
#   shard files transfer <src-vm>/<path> hostsync/<dest-subdir>
#   -> files appear at ~/vm-inbox/<dest-subdir>/<name>
#
#   Drop a file into ~/vm-inbox/, then:
#   shard files transfer hostsync/<name> <dst-vm>/<dest-path>
#   -> delivered from the inbox into the destination VM
#
# vsock 14506: the shared files agent (Hydrix vm/dev/files-agent.nix, imported
# through `filesAgent = true` in meta.nix), rooted at the inbox.
{
  config,
  lib,
  pkgs,
  ...
}: let
  meta = import ./meta.nix;

  hostUsername = config.hydrix.username;

  inbox = "/mnt/host-inbox";
in {
  hydrix.files.agent = {
    root = inbox;
    user = "hostsync";
    openFirewall = false; # nftables below
  };
  hydrix.networking.vmSubnet = meta.subnet;

  microvm.vsock.cid = meta.vsockCid;

  microvm.interfaces = [
    {
      type = "tap";
      id = meta.tapId;
      mac = meta.tapMac;
    }
  ];

  microvm.mem = lib.mkForce 256;

  # Host inbox share - virtiofsd on host maps ~/vm-inbox -> /mnt/host-inbox in VM.
  # Files decrypted here are immediately visible on the host.
  # Note: nix-store share is provided by microvm-infra-base; this appends to it.
  microvm.shares = [
    {
      tag = "host-inbox";
      source = "/home/${hostUsername}/vm-inbox";
      mountPoint = "${inbox}";
      proto = "virtiofs";
      posixAcl = false; # required by uid translation
      extraArgs = config.hydrix.microvm.ownedShareArgs;
    }
  ];

  # No persistent volumes - fully ephemeral (inbox data lives on the host via
  # the virtiofs share above, not in VM-local storage).
  boot.kernelModules = ["vmw_vsock_virtio_transport"];

  networking.useDHCP = lib.mkForce false;

  systemd.network = {
    enable = true;
    networks."10-hostsync" = {
      matchConfig.MACAddress = meta.tapMac;
      # Own CID as last octet, matching get_vm_ip's subnet.cid derivation in
      # scripts/shard.nix (same convention every profile VM uses).
      address = ["${meta.subnet}.${toString meta.vsockCid}/24"];
      linkConfig.RequiredForOnline = "no";
    };
  };

  # Only the files VM (.2 on this bridge) may reach port 8888.
  # vsock traffic is kernel-mediated and not subject to nftables.
  networking.nftables = {
    enable = true;
    tables."hostsync" = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter; policy drop;
          iif lo accept
          ct state established,related accept
          ct state invalid drop
          ip protocol icmp accept
          ip saddr ${meta.subnet}.2 tcp dport 8888 accept
        }
        chain forward {
          type filter hook forward priority filter; policy drop;
        }
      '';
    };
  };

  users.users.hostsync = {
    # Same uid as the host owner of its writable share (uid translation).
    uid = config.hydrix.microvm.hostOwner.uid;
    isNormalUser = true;
    extraGroups = ["wheel"];
    password = "hostsync";
    home = "/home/hostsync";
  };
  services.getty.autologinUser = "hostsync";
}
