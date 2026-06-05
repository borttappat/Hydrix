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
    # Hyprland is the default compositor. Enable i3 or sway per-machine if needed.
    # Start hyprland: hyprland-session    Start i3: startx    Start sway: sway-session
    hyprland.enable = lib.mkDefault true;
    # sway.enable = lib.mkDefault false;  # Wayland/Sway — enable per machine
    # i3.enable   = lib.mkDefault false;  # X11/i3 — enable per machine
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

  # Wire the same keyboard layout into Hyprland / Sway (Wayland compositors).
  # Overriding hydrix.graphical.keyboard.xkbFile in machines/<serial>.nix takes
  # precedence and is used for custom keymaps (e.g. the § → ~ remap).
  hydrix.graphical.keyboard.layout  = lib.mkDefault "@XKB_LAYOUT@";
  hydrix.graphical.keyboard.variant = lib.mkDefault "@XKB_VARIANT@";

  # ─── Editor and pager defaults ───────────────────────────────────────
  environment.variables = {
    BAT_THEME = "ansi";
    EDITOR    = "vim";
    VISUAL    = "vim";
  };

  # ─── HiDPI / display scaling ─────────────────────────────────────────
  # 1.0 = no scaling (1080p/standard). For HiDPI: try GDK_SCALE = "1.5" + XCURSOR_SIZE = "32".
  # Override per-machine in machines/<serial>.nix to set different values per display.
  environment.variables =  {
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

  # ─── Extra walrgb theming hook ───────────────────────────────────────
  # Shell commands appended after core walrgb theming. Runs on every walrgb call.
  # Available variables: HEX_CODE (hex color, no #), WALLPAPER (path to wallpaper)
  # Full wal cache at ~/.cache/wal/colors.json for all 16 palette colors.
  # Example: RGB keyboard, Notion, custom scripts, etc.
  #
  # hydrix.graphical.walrgbExtraCommands = ''
  #   # Set OpenRGB device to wal primary color
  #   if command -v openrgb >/dev/null 2>&1; then
  #     openrgb --device 0 --mode static --color "$HEX_CODE" 2>/dev/null || true
  #   fi
  # '';

  # ─── Ranger file manager extensions ─────────────────────────────────
  # Extra key mappings (merged with framework defaults)
  # hydrix.graphical.ranger.extraMappings = {
  #   gw = "cd ~/work";
  # };

  # Extra rifle opener rules (appended after framework rules)
  # hydrix.graphical.ranger.extraRifle = [
  #   { condition = "ext md, has glow, X, flag f"; command = "glow -- \"$@\""; }
  # ];

  # ─── Packages on every machine ──────────────────────────────────────
  # environment.systemPackages = with pkgs; [ git neovim ripgrep ];

  # ─── User groups on every machine ───────────────────────────────────
  # users.users.${config.hydrix.username}.extraGroups = [ "libvirtd" "kvm" ];

  # ─── Services on every machine ──────────────────────────────────────
  # services.tailscale.enable = true;
  # services.openssh.enable = true;
}
