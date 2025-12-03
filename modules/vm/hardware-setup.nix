# Hardware configuration auto-generation for VMs
# Generates /etc/nixos/hardware-configuration.nix on first boot
{ config, pkgs, lib, ... }:

{
  # Systemd service to auto-generate hardware-configuration.nix
  systemd.services.hydrix-hardware-setup = {
    description = "Auto-generate VM hardware configuration";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "hydrix-copy-to-home.service" ];
    before = [ "hydrix-shape.service" ];  # Must run before shaping

    # Only run once on first boot
    unitConfig = {
      ConditionPathExists = "!/var/lib/hydrix-hwconf-generated";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      echo "=== Generating hardware configuration ==="

      # Detect root filesystem
      ROOT_DEV=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE /)
      ROOT_FS=$(${pkgs.util-linux}/bin/findmnt -n -o FSTYPE /)

      # Detect disk device (strip partition number)
      DISK_DEV=$(echo "$ROOT_DEV" | ${pkgs.gnused}/bin/sed 's/[0-9]*$//')
      if [ -z "$DISK_DEV" ]; then
        DISK_DEV="/dev/vda"
      fi

      echo "Detected configuration:"
      echo "  Root: $ROOT_DEV ($ROOT_FS)"
      echo "  Disk: $DISK_DEV"

      # Generate hardware configuration
      ${pkgs.coreutils}/bin/mkdir -p /etc/nixos
      ${pkgs.coreutils}/bin/cat > /etc/nixos/hardware-configuration.nix << EOF
# Auto-generated hardware configuration for Hydrix VM
{ config, lib, pkgs, ... }:

{
  imports = [ ];

  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi" "virtio_console" "ahci" "xhci_pci"
    "sd_mod" "sr_mod"
  ];

  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "$ROOT_DEV";
    fsType = "$ROOT_FS";
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  boot.loader.grub = {
    enable = true;
    device = "$DISK_DEV";
    efiSupport = false;
    useOSProber = false;
  };
}
EOF

      # Mark as complete
      ${pkgs.coreutils}/bin/touch /var/lib/hydrix-hwconf-generated

      echo "✓ Hardware configuration generated at /etc/nixos/hardware-configuration.nix"
    '';
  };
}
