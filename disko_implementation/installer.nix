# installer/installer.nix - Custom installer configuration
{ pkgs, modulesPath, lib, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  # Better installer experience
  isoImage.isoBaseName = "nixos-custom-installer";
  isoImage.makeEfiBootable = true;
  isoImage.makeUsbBootable = true;

  # Enable fish shell
  programs.fish.enable = true;

  # Networking
  networking.wireless.enable = false;
  networking.networkmanager.enable = true;

  # Auto-start installer wizard on login
  programs.fish.interactiveShellInit = ''
    if test (tty) = /dev/tty1
      clear
      echo "╔════════════════════════════════════════════════════════════╗"
      echo "║       NixOS Custom Installer with BTRFS Support           ║"
      echo "╚════════════════════════════════════════════════════════════╝"
      echo ""
      echo "To start the installation wizard, run:"
      echo "  fish /etc/installer/install-wizard.fish"
      echo ""
      echo "For manual installation:"
      echo "  1. Partition disks (or run: sudo fdisk /dev/sdX)"
      echo "  2. Mount at /mnt"
      echo "  3. Generate config: nixos-generate-config --root /mnt"
      echo "  4. Edit /mnt/etc/nixos/configuration.nix"
      echo "  5. Install: nixos-install"
      echo ""
    end
  '';

  # Essential packages for installation
  environment.systemPackages = with pkgs; [
    fish
    git
    vim
    neovim
    htop
    wget
    curl
    parted
    gptfdisk
    btrfs-progs
    cryptsetup
    lvm2
    rsync
    pciutils
    usbutils
    dmidecode
    smartmontools
    nvme-cli
  ];

  # Larger font for HiDPI displays
  console.font = lib.mkDefault "${pkgs.terminus_font}/share/consolefonts/ter-v32n.psf.gz";

  # Enable SSH for remote installation
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # Set a default password for installer (warn users to change this)
  users.users.nixos.initialPassword = "nixos";
  users.users.root.initialPassword = "nixos";

  # Faster boot
  boot.kernelParams = [ "quiet" ];
  
  # Support for most filesystems
  boot.supportedFilesystems = [ "btrfs" "ext4" "xfs" "ntfs" "vfat" ];
}
