# VM Packages - Core packages for ALL VMs
#
# Lighter than host-packages.nix - no WiFi tools, nix build tools, VPN, etc.
# Profile-specific packages go in profiles/<type>/packages.nix
#
{ config, lib, pkgs, ... }:

{
  imports = [
    ./shell-packages.nix
  ];

  # Hardware graphics: mesa/llvmpipe for alacritty GL rendering
  hardware.graphics.enable = true;

  # Faster VM terminals, both off by default (DOCUMENTATION.md, "VM Terminal Speed").
  # Uncomment for every profile VM; a profile's own default.nix can still turn one off with a
  # plain assignment (e.g. hydrix.microvm.terminalDaemon.enable = false;). Apply: shard -bR <vm>.
  #
  # Resident alacritty per VM: a new terminal (Mod+Return) opens as a window of it at once.
  # Its terminals share one process, so they all close if it exits.
  # hydrix.microvm.terminalDaemon.enable = lib.mkDefault true;

  # The guest keeps its cached view of the read-only /nix/store instead of re-checking every
  # file with the host: much faster program starts (shells, prompts). Store paths never
  # change, so the cache cannot go stale. See hydrix.microvm.storeCache.
  # hydrix.microvm.storeCache = lib.mkDefault "always";

  environment.variables = {
    EDITOR = config.hydrix.editor;
    VISUAL = config.hydrix.editor;
  };

  environment.systemPackages = with pkgs; [
    # Editors
    vim
    nano

    # System monitoring
    htop

    # File management
    ranger
    file
    tree

    # Core utilities
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    busybox

    # Media
    feh
    zathura
    mpv

    # Network tools
    wget
    curl

    # Version control
    git
    gh

    # Archive tools
    unzip
    p7zip

    # System utilities
    killall
    pciutils
    lshw

    # Nix tools
    nh

    # GUI apps (waypipe forwarded)
    pywal
  ];
}
