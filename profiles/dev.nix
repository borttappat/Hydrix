# Dev VM - Full profile
# Software development and compilation system
#
# Hostname customization:
#   - Default: "dev-vm"
#   - Override: Create local/vm-instance.nix with: { hostname = "dev-myname"; }
#   - The build-vm.sh script generates this automatically
#
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    # Hydrix options - MUST BE FIRST to define hydrix.* options before other modules use them
    ../modules/base/hydrix-options.nix

    # VM base module - handles all common VM config (hardware, locale, etc.)
    ../modules/vm/vm-base.nix
  ];

  # VM identity
  hydrix.vmType = "dev";
  hydrix.colorscheme = "perp";
  hydrix.vm.defaultHostname = "dev-vm";

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
  ];

  # Enable Docker for containerized development
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
  };

  # Add VM user to docker group
  users.users.${config.hydrix.username}.extraGroups = [ "docker" ];

  # Enable PostgreSQL for database development
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
  };
}
