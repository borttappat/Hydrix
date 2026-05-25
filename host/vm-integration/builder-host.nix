# Builder Host Module - Host-side support for the builder microVM
#
# The builder VM allows rebuilding Hydrix in lockdown mode by running
# nix builds inside a separate microVM with network access.
#
# The builder functionality is integrated into the microvm script:
#   microvm start microvm-builder   # Stops host nix-daemon, starts builder
#   microvm builder-exec <flake>    # Build in builder VM
#   microvm builder-status          # Check status
#   microvm stop microvm-builder    # Stops builder, restarts nix-daemon
#
# This module enables the required host-side packages and services.

{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.builder;
in {
  config = lib.mkIf cfg.enable {
    # Declare the builder VM so it is built on first boot (hydrix-firstboot-vms)
    # and included in infrastructure-only builds (e.g. fresh lockdown installs).
    # autostart = false: builder is not started automatically — only on demand.
    hydrix.microvmHost.vms."microvm-builder" = {
      enable = lib.mkDefault true;
      autostart = lib.mkDefault false;
    };

    # Ensure socat is available for vsock communication
    environment.systemPackages = [ pkgs.socat ];
  };
}
