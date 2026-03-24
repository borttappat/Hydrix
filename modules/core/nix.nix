# Nix Configuration - Settings, caches, garbage collection
{ config, pkgs, lib, ... }:

{
  # Use latest Nix with git support
  nix.package = pkgs.nixVersions.git;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    download-buffer-size = 524288000;
    max-jobs = "auto";
    cores = 0;

    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  # Disable man-cache generation (very slow, not worth the build time)
  documentation.man.generateCaches = false;

  # Weekly garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 10d";
  };

  # nix-ld for unpatched binaries
  programs.nix-ld.enable = true;

  # Boot settings
  boot = {
    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    kernel.sysctl = {
      "kernel.sysrq" = 1;
      "vm.swappiness" = 10;
      "vm.vfs_cache_pressure" = 50;
      "vm.dirty_ratio" = 10;
      "vm.dirty_background_ratio" = 5;
      "kernel.nmi_watchdog" = 0;
    };
  };

  # Zram swap
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Earlyoom prevents freezes
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    enableNotifications = true;
  };

  # Systemd optimizations
  systemd.settings.Manager.DefaultTimeoutStopSec = "10s";

  # File descriptor limits
  security.pam.loginLimits = [
    { domain = "*"; type = "soft"; item = "nofile"; value = "4096"; }
    { domain = "*"; type = "hard"; item = "nofile"; value = "8192"; }
  ];

  # Firmware
  hardware.enableAllFirmware = true;

  # State version
  system.stateVersion = lib.mkDefault "25.05";
}
