# System configuration from dotfiles - performance and desktop essentials
# This module contains settings that are NOT in /etc/nixos/configuration.nix
{ config, pkgs, lib, ... }:

{
  # ========== SYSTEMD SERVICES ==========

  # Lock screen before suspend
  systemd.services.i3lock-on-suspend = {
    description = "Lock screen before suspend";
    before = [ "sleep.target" ];
    wantedBy = [ "sleep.target" ];
    serviceConfig = {
      User = "traum";
      Type = "forking";
      Environment = [
        "DISPLAY=:0"
        "XAUTHORITY=/home/traum/.Xauthority"
        "HOME=/home/traum"
        "PATH=/run/current-system/sw/bin"
      ];
      ExecStart = "${pkgs.i3lock-color}/bin/i3lock -c 000000";  # Simple black lock
    };
  };

  # Lid switch behavior
  services.logind.lidSwitch = "suspend";

  # ========== DISPLAY MANAGEMENT ==========

  # Autorandr for automatic display configuration
  services.autorandr.enable = true;

  # Set ranger as default file manager
  xdg.mime.defaultApplications = {
    "inode/directory" = "ranger.desktop";
  };

  # ========== NIX SETTINGS ==========

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    download-buffer-size = 524288000;

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

  # ========== BOOT AND KERNEL ==========

  boot.kernel.sysctl = {
    "kernel.sysrq" = 1;
    "vm.swappiness" = 10;
    "vm.vfs_cache_pressure" = 50;
    "vm.dirty_ratio" = 10;
    "vm.dirty_background_ratio" = 5;
    "kernel.nmi_watchdog" = 0;  # Saves power
  };

  # Use latest kernel (unless overridden by machine profile)
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  # ========== MEMORY MANAGEMENT ==========

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

  # ========== SYSTEMD OPTIMIZATIONS ==========

  systemd = {
    services.nix-daemon.enable = true;
    extraConfig = ''
      DefaultTimeoutStopSec=10s
    '';
  };

  # ========== SECURITY AND LIMITS ==========

  security.pam.loginLimits = [
    { domain = "*"; type = "soft"; item = "nofile"; value = "4096"; }
    { domain = "*"; type = "hard"; item = "nofile"; value = "8192"; }
  ];

  # ========== HARDWARE ==========

  hardware.enableAllFirmware = true;

  # ========== SHELL ==========

  # Setting fish shell as default
  programs.fish.enable = true;
  users.defaultUserShell = pkgs.fish;

  # ========== X11 AND DESKTOP ==========

  # Enable the X11 windowing system
  services.xserver.enable = true;

  # Window manager and display manager
  services.xserver.displayManager.startx.enable = true;
  services.xserver.windowManager.i3.enable = true;

  # ========== QT AND GTK ==========

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
    MOZ_ENABLE_WAYLAND = "1";
    MOZ_USE_XINPUT2 = "1";
  };

  environment.etc."gtk-3.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=1
  '';

  # ========== NETWORKING ==========

  # Firewall settings
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 8080 4444 4445 8000 ];
    allowedUDPPorts = [ 22 53 80 4444 4445 5353 5355 5453 ];
  };

  networking.nftables.enable = false;
}
