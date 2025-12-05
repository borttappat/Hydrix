# Minimal NixOS system configuration for base VM images
# Only includes essentials for booting, networking, and shaping
{ config, pkgs, lib, ... }:

{
  # Nix settings - minimal flakes support
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  # Boot settings - use stable kernel for smaller size
  boot = {
    kernelPackages = pkgs.linuxPackages;

    kernel.sysctl = {
      "vm.swappiness" = 10;
    };
  };

  # Enable zram for better memory management
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Systemd - just the essentials
  systemd = {
    services.nix-daemon.enable = true;
    extraConfig = ''
      DefaultTimeoutStopSec=10s
    '';
  };

  # Locale and time - minimal
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";

  console.keyMap = "sv-latin1";

  # Minimal environment
  environment.variables = {
    EDITOR = "vim";
  };

  # State version
  system.stateVersion = "25.05";
}
