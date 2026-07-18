# Host-Only System Defaults
# Settings that apply to the physical host but not to VMs.
# Imported by mkHost in lib/default.nix.
{ config, lib, pkgs, ... }:

{
  # Boot menu / os-release branding
  system.nixos.distroName = lib.mkDefault "Hydrix";

  # GTK dark theme default for host apps (virt-manager, file pickers, etc.)
  # Overridden by Stylix when hydrix.graphical.enable = true
  environment.etc."gtk-3.0/settings.ini".text = lib.mkDefault ''
    [Settings]
    gtk-application-prefer-dark-theme=1
  '';

  # nftables for the host (VMs keep iptables — files-agent uses extraCommands)
  networking.nftables.enable = true;
}
