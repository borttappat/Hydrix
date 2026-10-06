# Graphical Configuration - Shared across all machines
#
# UI preferences that apply to every machine.
# Machine-specific overrides go in machines/<serial>.nix using plain assignment
# there takes priority over the lib.mkDefault values here.
#
# Bar style and module layout -> modules/waybar.nix
# Font packages and mappings  -> modules/fonts.nix
# Font family/size/relations  -> modules/fonts.nix (or machines/<serial>.nix)
{lib, ...}: {
  hydrix.graphical = {
    # ─── Layout ────────────────────────────────────────────────────────
    # ui.gaps         = lib.mkDefault 10;    # Gap size everywhere (px): screen-to-bar, bar-to-window, window-to-window
    # ui.border       = lib.mkDefault 2;     # Window border width (px)
    # ui.cornerRadius = lib.mkDefault 2;     # Window corner radius (px); waybar pills = cornerRadius * pillRadiusScale, eww/wofi = cornerRadius + border - 1

    # ─── Shadows ───────────────────────────────────────────────────────
    # One setting for window (Hyprland), eww, waybar pill, wofi and notification shadows.
    # ui.shadow.enable   = lib.mkDefault true;
    # ui.shadow.strength = lib.mkDefault 1.0;   # Multiplier on every shadow's opacity and size

    # ─── Waybar sizing (active bar stack) ───────────────────────────────
    # Bar content height and pill vertical padding are auto-derived from
    # font.size and ui.gaps (see modules/waybar.nix).
    # ui.barGaps         = lib.mkDefault null;  # Bar-to-edge margin (null = gaps/2)
    # ui.pillRadius      = lib.mkDefault null;  # Explicit pill radius (null = cornerRadius * pillRadiusScale)
    # ui.pillRadiusScale = lib.mkDefault 2.0;   # Scale factor applied to cornerRadius for pill radius

    # ─── Opacity ───────────────────────────────────────────────────────
    # overlay: background opacity for alacritty, waybar, wofi, eww, notifications;
    # layer blur (modules/hyprland.nix) follows it. Override per machine.
    # ui.opacity.overlay          = lib.mkDefault 0.85;
    # ui.opacity.overlayOverrides = lib.mkDefault { };  # Per-app exceptions, e.g. { alacritty = 0.95; }
    # active/inactive: whole-window opacity (text included) for non-excluded Hyprland windows
    ui.opacity.active = lib.mkDefault 0.95;
    ui.opacity.inactive = lib.mkDefault 0.95;
    # ui.opacity.exclude          = lib.mkDefault [ "Alacritty" "feh" "Feh" "firefox" "Firefox" "mpv" "vlc" ];

    # ─── Keyboard remapping ────────────────────────────────────────────
    # keyboard.xmodmap = lib.mkDefault ''
    #   clear lock
    #   clear control
    #   keycode 66 = Control_L
    #   add control = Control_L Control_R
    # '';

    # ─── DPI scaling ───────────────────────────────────────────────────
    # scaling.auto                = lib.mkDefault true;
    # scaling.referenceDpi        = lib.mkDefault 96;
    # scaling.standaloneScaleFactor = lib.mkDefault 1.0;        # scale in VM standalone mode
    # scaling.applyOnLogin        = lib.mkDefault true;

    # ─── Blue light filter ─────────────────────────────────────────────
    # bluelight.enable       = lib.mkDefault true;
    # bluelight.defaultTemp  = lib.mkDefault 4500;
    # bluelight.minTemp      = lib.mkDefault 2500;
    # bluelight.maxTemp      = lib.mkDefault 6500;
    # bluelight.step         = lib.mkDefault 200;
    # bluelight.autoRestart  = lib.mkDefault false;
    # bluelight.schedule.dayTemp    = lib.mkDefault 6500;
    # bluelight.schedule.nightTemp  = lib.mkDefault 3500;
    # bluelight.schedule.dayStart   = lib.mkDefault 7;
    # bluelight.schedule.nightStart = lib.mkDefault 20;

    # ─── Lockscreen ────────────────────────────────────────────────────
    # lockscreen.idleTimeout = lib.mkDefault 600;  # seconds; null = disable auto-lock
    # lockscreen.font        = lib.mkDefault "CozetteVector";
    # lockscreen.fontSize    = lib.mkDefault 143;
    # lockscreen.clockSize   = lib.mkDefault 104;
    # lockscreen.text        = lib.mkDefault "Locked";        # set to whatever you like
    # lockscreen.wrongText   = lib.mkDefault "Wrong password"; # set to whatever you like
    # lockscreen.verifyText  = lib.mkDefault "Verifying...";
    # lockscreen.blur        = lib.mkDefault true;
    # lockscreen.rounding    = lib.mkDefault 3;     # DEFAULT: eww panelRadius * scale, physical px
    lockscreen.dim.timeout = lib.mkDefault 120; # dim the panel after 2 min idle; any input restores
    # lockscreen.dim.brightness = lib.mkDefault 10; # percent
    # lockscreen.battery.enable = lib.mkDefault true; # hidden without a battery

    # ─── pywal (walrgb color extraction) ───────────────────────────────
    # Default: pywal 3.3.0 instead of nixpkgs' pywal16 (tints dark backgrounds),
    # with a faster backend (same palettes) and a background service that
    # pre-generates palettes for your wallpapers so walrgb only applies colors.
    # pywal.pin.enable       = lib.mkDefault false;  # Upstream nixpkgs pywal only (also turns off precache)
    # pywal.precache.enable  = lib.mkDefault false;  # Keep the pin, no background palette generation
    # pywal.precache.directories = lib.mkDefault [ "/home/<user>/wallpapers" "/home/<user>/hydrix-config/wallpapers" ];
  };

  hydrix.colorscheme = lib.mkDefault "hydrix";

  # ─── VM color inheritance ─────────────────────────────────────────────
  # hydrix.colorschemeInheritance = lib.mkDefault "dynamic";
  #   "full"    — VMs use all host wal colors
  #   "dynamic" — VMs use host background + their own text colors
  #   "none"    — VMs use their own colorscheme independently
}
