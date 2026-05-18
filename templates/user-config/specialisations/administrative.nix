# Administrative Mode - User customizations
#
# The framework handles all infrastructure:
#   - Default gateway through router VM
#   - DNS through router
#   - Libvirtd, firewall, virtualisation packages
#   - Mode identification
#
# Add your extra administrative packages and settings here.
# This file is imported INSIDE specialisation.administrative.configuration
# in your machine config.
#
{ config, lib, pkgs, ... }:

{
  # Enable host-level apps that are gated off in lockdown
  hydrix.graphical.firefox.hostEnable = true;
  hydrix.graphical.obsidian.hostEnable = true;

  hydrix.services.tailscale.enable = true;

  environment.systemPackages = with pkgs; [
    # Network tools
    iproute2
    iptables
    nftables
    tcpdump
    nmap
    netcat-gnu
    socat
    curl
    wget
    bind.dnsutils

    # Development
    git
    gh
    gnumake
    gcc
    python3

    # File management
    rsync
    rclone

    # System administration
    parted
    gptfdisk
    cryptsetup
    smartmontools

    # Security tools
    gnupg
    age
    sops
    pass

    # Documentation
    man-pages
    man-pages-posix
  ];
}
