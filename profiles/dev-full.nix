# Dev VM - Full profile (applied after shaping)
# Software development and compilation system
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # QEMU guest profile
    (modulesPath + "/profiles/qemu-guest.nix")

    # Hardware configuration (generated on first boot)
    /etc/nixos/hardware-configuration.nix

    # Base system
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/base/networking.nix
    ../modules/vm/qemu-guest.nix

    # Core desktop environment (i3, fish, etc.)
    ../modules/core.nix

    # Theming system
    ../modules/theming/static-colors.nix  # Static purple theme for dev
    ../modules/desktop/xinitrc.nix        # X session bootstrap + config deployment
  ];

  # Boot loader configuration for VMs
  boot.loader.grub = {
    enable = true;
    device = lib.mkForce "/dev/vda";
    efiSupport = false;
  };

  # Hostname is set during VM deployment (e.g., "dev-rust")
  # Do not override it here

  # VM type for static color generation
  hydrix.vmType = "dev";  # Generates purple theme

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
    gh  # GitHub CLI
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
