# Fallback Mode - User customizations
#
# The framework handles all infrastructure:
#   - VFIO release, WiFi re-enabled
#   - NetworkManager, bridges removed
#   - Mode identification
#
# Add your extra fallback packages and settings here.
# This file is imported INSIDE specialisation.fallback.configuration
# in your machine config.
#
# NOTE: Switching to/from fallback requires a REBOOT (kernel parameter changes).
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # WiFi tools (essential for fallback)
    networkmanager
    wpa_supplicant
    iw
    wirelesstools

    # Network basics
    iproute2
    iptables
    tcpdump
    curl
    wget
    bind.dnsutils

    # Browser (direct access in fallback)
    firefox

    # Virtualisation (for recovery)
    virt-manager
    virt-viewer
    libvirt
    qemu

    # Development
    git
    gh
    gnumake

    # File management
    rsync

    # System tools
    parted
    gptfdisk
    cryptsetup
    smartmontools
  ];
}
