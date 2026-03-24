# Dev Profile Packages
#
# Development toolkit - languages, build tools, devops.
# Core VM packages are in shared/vm-packages.nix.
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Version control
    git
    gh

    # Languages
    python3
    jython
    nodejs
    go
    rustc
    cargo

    # Build tools
    gnumake
    cmake
    gcc
    clang

    # Container tools
    docker-compose

    # DevOps/Automation
    ansible

    # Terminal utilities
    tmux
    fzf
    ripgrep
    fd
    jq
    yq

    # Network tools
    curl
    wget

    # Crypto/SSL
    openssl
  ];
}
