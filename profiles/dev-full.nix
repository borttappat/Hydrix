# Dev VM - Full profile
# Software development and compilation system
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # QEMU guest profile from nixpkgs
    (modulesPath + "/profiles/qemu-guest.nix")

    # Base system
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/base/networking.nix
    ../modules/vm/qemu-guest.nix

    # Core desktop environment (i3, fish, etc.)
    ../modules/core.nix

    # Theming system
    ../modules/theming/static-colors.nix
    ../modules/desktop/xinitrc.nix
  ];

  # ===== Inline hardware configuration for QEMU VMs =====
  boot.initrd.availableKernelModules = [
    "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
    "virtio_net" "virtio_scsi" "virtio_console"
    "ahci" "xhci_pci" "sd_mod" "sr_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.extraModulePackages = [ ];

  boot.loader.grub = {
    enable = true;
    device = lib.mkDefault "/dev/vda";
    efiSupport = false;
    useOSProber = false;
  };

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  swapDevices = [ ];
  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Hostname
  networking.hostName = lib.mkForce "dev-vm";

  # VM type and colorscheme
  hydrix.vmType = "dev";
  hydrix.colorscheme = "perp";

  # Development packages
  environment.systemPackages = with pkgs; [
    # Programming languages
    python3
    python3Packages.pip
    python3Packages.virtualenv
    nodejs
    go
    rustc
    cargo
    gcc
    clang

    # Build tools
    gnumake
    cmake
    ninja
    meson

    # Version control
    git
    gh
    git-lfs

    # Editors/IDEs
    vscode
    neovim

    # Debugging
    gdb
    lldb
    valgrind

    # Database clients
    postgresql
    sqlite

    # Container tools
    docker
    docker-compose

    # API testing
    postman
    curl
    httpie

    # Documentation
    man-pages
    man-pages-posix

    # Code formatters/linters
    nixpkgs-fmt
    shellcheck
    shfmt

    # Terminal multiplexers
    tmux
    screen

    # Rebuild script
    (pkgs.writeShellScriptBin "rebuild" ''
      #!/usr/bin/env bash
      set -e
      cd /home/traum/Hydrix
      echo "Pulling latest changes..."
      git pull
      echo "Rebuilding system..."
      sudo nixos-rebuild switch --flake '.#vm-dev' --impure
    '')
  ];

  # Enable Docker for containerized development
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
  };

  # Add user to docker group
  users.users.traum.extraGroups = [ "docker" ];

  # Enable PostgreSQL for database development
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
  };
}
