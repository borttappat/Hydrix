{ config, lib, pkgs, ... }:

let
  # Check if this is a legacy install (has /etc/nixos/hardware-configuration.nix)
  # vs a disko install (disk config is declarative, no hardware-configuration.nix needed)
  hasLegacyHardwareConfig = builtins.pathExists /etc/nixos/hardware-configuration.nix;
  hasLegacyConfig = builtins.pathExists /etc/nixos/configuration.nix;

  # Check if disko is managing disks (disko.devices is set)
  isDisko = config.disko.devices.disk != {};

  # Find the ESP path among the filesystems
  getEspPath = filesystems:
    let
      # Filter filesystems to find ones mounted at /boot or /boot/efi
      bootMounts = lib.filterAttrs
        (mountPoint: _: mountPoint == "/boot" || mountPoint == "/boot/efi")
        filesystems;

      # Get the mount point names
      bootMountNames = lib.attrNames bootMounts;
    in
      # Check if list is non-empty before calling head
      if bootMountNames != [] then lib.head bootMountNames else "/boot";

  espPath = getEspPath config.fileSystems;

  # Only import user's original NixOS configuration if it exists (legacy installs)
  userConfig = if hasLegacyConfig
    then import /etc/nixos/configuration.nix { inherit config pkgs lib; }
    else {};
in {
  # Import the system-generated hardware configuration ONLY for legacy installs
  # For disko installs, disk/filesystem config is declarative - no hardware-configuration.nix needed
  imports = lib.optionals hasLegacyHardwareConfig [ /etc/nixos/hardware-configuration.nix ];

  # Import boot.initrd settings from user's configuration.nix (legacy installs only)
  # Some users have LUKS settings here instead of hardware-configuration.nix
  boot.initrd = lib.mkIf hasLegacyConfig (lib.mkMerge [
    (userConfig.boot.initrd or {})
  ]);

  # Configure bootloader with GRUB - only for legacy installs
  # For disko installs, boot.loader is configured in machines/<serial>.nix
  boot.loader = lib.mkIf (!isDisko) (lib.mkForce {
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      useOSProber = true;
    };
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = espPath;
    };
  });
}
