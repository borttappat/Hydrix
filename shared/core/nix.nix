# Universal System Defaults
# Applied to all Hydrix systems: host, microVMs, QEMU VMs.
# All values use lib.mkDefault so any module can override with plain assignment.
{ config, pkgs, lib, ... }:

{
  # Use latest Nix with git support
  nix.package = lib.mkDefault pkgs.nixVersions.git;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = lib.mkDefault true;
    download-buffer-size = lib.mkDefault 524288000;
    max-jobs = lib.mkDefault "auto";
    cores = lib.mkDefault 0;

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
  # Plain assignment intentional: overrides fish module's lib.mkDefault true.
  # generateAtRuntime is the actual expensive part: a systemd service (mandb.service)
  # that rsyncs and reindexes every package's man pages on every activation where
  # the systemPackages closure changed at all (even unrelated packages). cache.enable
  # alone only skips baking a cache into the store, it doesn't stop this. Both must
  # be disabled together; fish's module sets both to true by default.
  documentation.man.cache.enable = false;
  documentation.man.cache.generateAtRuntime = false;

  # Weekly garbage collection
  nix.gc = {
    automatic = lib.mkDefault true;
    dates = lib.mkDefault "weekly";
    options = lib.mkDefault "--delete-older-than 10d";
  };

  # nix-ld for unpatched binaries
  programs.nix-ld.enable = lib.mkDefault true;

  # Boot settings
  boot = {
    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    kernelParams = lib.mkDefault [ "quiet" "loglevel=3" ];
    kernel.sysctl = {
      "kernel.sysrq" = lib.mkDefault 1;
      "vm.swappiness" = lib.mkDefault 10;
      "vm.vfs_cache_pressure" = lib.mkDefault 50;
      "vm.dirty_ratio" = lib.mkDefault 10;
      "vm.dirty_background_ratio" = lib.mkDefault 5;
      "kernel.nmi_watchdog" = lib.mkDefault 0;
    };
  };

  # Zram swap
  zramSwap = {
    enable = lib.mkDefault true;
    algorithm = lib.mkDefault "zstd";
    memoryPercent = lib.mkDefault 50;
  };

  # Earlyoom prevents freezes under memory pressure
  services.earlyoom = {
    enable = lib.mkDefault true;
    freeMemThreshold = lib.mkDefault 5;
    freeSwapThreshold = lib.mkDefault 10;
    enableNotifications = lib.mkDefault true;
  };

  # Systemd optimizations
  systemd = {
    services.nix-daemon.enable = lib.mkDefault true;
    settings.Manager.DefaultTimeoutStopSec = lib.mkDefault "10s";
  };

  # File descriptor limits — nix builds and nix-daemon open many files concurrently
  security.pam.loginLimits = [
    { domain = "*"; type = "soft"; item = "nofile"; value = "524288"; }
    { domain = "*"; type = "hard"; item = "nofile"; value = "524288"; }
  ];
  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkDefault 524288;

  services.openssh.enable = lib.mkDefault true;

  # Firmware
  hardware.enableAllFirmware = lib.mkDefault true;

  # State version default — override per machine in machines/<serial>.nix
  system.stateVersion = lib.mkDefault "25.05";
}
