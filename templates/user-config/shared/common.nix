# Common Configuration - Shared across all machines
#
# Settings here apply to ALL machines via lib.mkDefault.
# Machine-specific overrides in machines/<serial>.nix use plain assignment,
# which automatically takes priority without needing lib.mkForce.
#
# Populated automatically by the installer. Edit here to change all machines at once.

{ config, lib, pkgs, ... }:

{
  hydrix = {
    # ─── Window manager stack ───────────────────────────────────────────
    # Both i3 (X11) and sway (Wayland) are available on all machines.
    # Start i3: startx    Start sway: sway-session
    # Override per-machine to restrict to one WM.
    sway.enable = lib.mkDefault true;
    i3.enable   = lib.mkDefault true;
  };

  # ─── Locale and timezone ─────────────────────────────────────────────
  # Populated automatically by the installer from your current system.
  # Change here to apply to all machines (and VMs) at once.
  time.timeZone                    = lib.mkDefault "@TIMEZONE@";
  i18n.defaultLocale               = lib.mkDefault "@LOCALE@";
  i18n.extraLocaleSettings         = lib.mkDefault { LC_TIME = "@LOCALE@"; };
  console.keyMap                   = lib.mkDefault "@CONSOLE_KEYMAP@";
  services.xserver.xkb.layout     = lib.mkDefault "@XKB_LAYOUT@";
  services.xserver.xkb.variant    = lib.mkDefault "@XKB_VARIANT@";

  # ─── HiDPI / display scaling ─────────────────────────────────────────
  # 1.0 = no scaling (1080p/standard). For HiDPI: try GDK_SCALE = "1.5" + XCURSOR_SIZE = "32".
  # Override per-machine in machines/<serial>.nix to set different values per display.
  environment.variables = lib.mkDefault {
    GDK_SCALE       = "1.0";
    GDK_DPI_SCALE   = "1.0";
    QT_SCALE_FACTOR = "1.0";
    XCURSOR_SIZE    = "24";
  };

  # ─── VM color inheritance ────────────────────────────────────────────
  # hydrix.colorschemeInheritance = "dynamic";  # DEFAULT: "dynamic"
  #   "full"    — VMs use all host wal colors
  #   "dynamic" — VMs use host background + their own text colors
  #   "none"    — VMs use their own colorscheme independently

  # ─── Packages on every machine ──────────────────────────────────────
  # environment.systemPackages = with pkgs; [ git neovim ripgrep ];

  # ─── User groups on every machine ───────────────────────────────────
  # users.users.${config.hydrix.username}.extraGroups = [ "libvirtd" "kvm" ];

  # ─── Services on every machine ──────────────────────────────────────
  # services.tailscale.enable = true;
  # services.openssh.enable = true;
}
