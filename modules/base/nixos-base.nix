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

  # Disable man-cache generation (very slow, not worth the build time)
  documentation.man.generateCaches = false;

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
    kernelParams = [ "quiet" "loglevel=3" ];

    kernel.sysctl = {
      "kernel.sysrq" = lib.mkDefault 1;
      "vm.swappiness" = lib.mkDefault 10;
      "vm.vfs_cache_pressure" = lib.mkDefault 50;
      "vm.dirty_ratio" = lib.mkDefault 10;
      "vm.dirty_background_ratio" = lib.mkDefault 5;
      "kernel.nmi_watchdog" = lib.mkDefault 0;
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
    settings.Manager.DefaultTimeoutStopSec = "10s";
  };

  # File descriptor limits - nix builds and nix-daemon open many files concurrently
  security.pam.loginLimits = [
    { domain = "*"; type = "soft"; item = "nofile"; value = "524288"; }
    { domain = "*"; type = "hard"; item = "nofile"; value = "524288"; }
  ];
  systemd.services.nix-daemon.serviceConfig.LimitNOFILE = lib.mkDefault 524288;

  # Hardware
  hardware.enableAllFirmware = true;

  # Locale and time - use mkDefault so VMs can override via hydrix.locale options
  time.timeZone = lib.mkDefault "Europe/Stockholm";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
  i18n.extraLocaleSettings = lib.mkDefault {
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

  console.keyMap = lib.mkDefault "sv-latin1";

  # X11 keyboard layout - use mkDefault so VMs can override
  services.xserver.xkb = {
    layout = lib.mkDefault "se";
    variant = lib.mkDefault "";
  };

  # Qt and GTK support
  # Use mkDefault so Stylix can override when graphical module is enabled
  qt = {
    enable = true;
    platformTheme = lib.mkDefault "gtk2";
  };

  environment.systemPackages = with pkgs; [
    # Note: 'rebuild' command is provided by modules/base/hydrix-scripts.nix
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
