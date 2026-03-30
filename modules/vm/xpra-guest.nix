# Xpra guest module - seamless app forwarding from VM to host via virtio-vsock
#
# Runs an xpra server inside the VM listening on vsock port 14500.
# The host connects with: vm-app <vm-name> <command>
#
# Requirements:
#   - VM must have a vsock device (deploy-vm.sh adds --vsock cid.auto=yes)
#   - Host must have xpra-host.nix imported (provides vm-app script + xpra)
#
{ config, pkgs, lib, ... }:

{
  # Vsock transport kernel module
  boot.kernelModules = [ "vmw_vsock_virtio_transport" ];

  environment.systemPackages = with pkgs; [ xpra ];

  # Xpra server - listens on vsock port 14500 for host connections
  # Runs as a systemd user service (auto-login activates the user session)
  # Creates its own virtual X display — independent of the VM's main desktop
  systemd.user.services.xpra-vsock = {
    description = "Xpra seamless app server (vsock)";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.xpra}/bin/xpra start"
        "--bind-vsock=auto:14500"
        "--no-daemon"
        "--start-new-commands=yes"
        "--vsock-auth=none"
        "--sharing=yes"
        # Encoding: rgb = zero compression, zero CPU overhead
        # vsock is a local kernel transport — bandwidth is free, compression is pure waste
        "--encoding=rgb"
        "--speed=100"
        "--video=no"
        # Disable unneeded features
        "--pulseaudio=no"
        "--mdns=no"
        "--notifications=no"
        "--systemd-run=no"
      ];
      Restart = "always";
      RestartSec = 5;
    };
  };
}
