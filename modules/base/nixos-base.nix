# Core NixOS system configuration
{ config, pkgs, lib, ... }:

{
  # Nix settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    download-buffer-size = 524288000;

    # Parallel build settings for faster image builds
    max-jobs = "auto";  # Parallel derivations = number of CPU cores
    cores = 0;          # Each build job uses all available cores

    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  # Automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 10d";
  };

  # nix-ld for running unpatched binaries
  programs.nix-ld.enable = true;

  # Boot settings
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;

    kernel.sysctl = {
      "kernel.sysrq" = 1;
      "vm.swappiness" = 10;
      "vm.vfs_cache_pressure" = 50;
      "vm.dirty_ratio" = 10;
      "vm.dirty_background_ratio" = 5;
      "kernel.nmi_watchdog" = 0;
    };
  };

  # Enable zram for better memory management
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Enable earlyoom to prevent system freezes
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    enableNotifications = true;
  };

  # Systemd optimizations
  systemd = {
    services.nix-daemon.enable = true;
    extraConfig = ''
      DefaultTimeoutStopSec=10s
    '';
  };

  # Security and limits
  security.pam.loginLimits = [
    { domain = "*"; type = "soft"; item = "nofile"; value = "4096"; }
    { domain = "*"; type = "hard"; item = "nofile"; value = "8192"; }
  ];

  # Hardware
  hardware.enableAllFirmware = true;

  # Locale and time
  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "sv_SE.UTF-8";
    LC_IDENTIFICATION = "sv_SE.UTF-8";
    LC_MEASUREMENT = "sv_SE.UTF-8";
    LC_MONETARY = "sv_SE.UTF-8";
    LC_NAME = "sv_SE.UTF-8";
    LC_NUMERIC = "sv_SE.UTF-8";
    LC_PAPER = "sv_SE.UTF-8";
    LC_TELEPHONE = "sv_SE.UTF-8";
    LC_TIME = "sv_SE.UTF-8";
  };

  console.keyMap = "sv-latin1";

  # X11 keyboard layout
  services.xserver.xkb = {
    layout = "se";
    variant = "";
  };

  # Qt and GTK support
  qt = {
    enable = true;
    platformTheme = "gtk2";
  };

  environment.systemPackages = with pkgs; [
    adwaita-icon-theme
    gtk-engine-murrine
    gtk_engines
    gsettings-desktop-schemas
  ];

  environment.variables = {
    GDK_SCALE = "1.5";
    GDK_DPI_SCALE = "1.0";
    QT_SCALE_FACTOR = "1.5";
    XCURSOR_SIZE = "32";
    BAT_THEME = "ansi";
    EDITOR = "vim";
    VISUAL = "vim";
  };

  environment.etc."gtk-3.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=1
  '';

  # State version
  system.stateVersion = "25.05";
}
