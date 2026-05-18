# Graphical Configuration — Shared across all machines
#
# UI preferences that apply to every machine.
# Machine-specific overrides go in machines/<serial>.nix — plain assignment
# there takes priority over the lib.mkDefault values here.
#
# Bar style and module layout → shared/polybar.nix
# Font packages and mappings  → shared/fonts.nix
# Font family/size/relations  → shared/fonts.nix (or machines/<serial>.nix)

{ lib, ... }:

{
  hydrix.graphical = {

    # ─── Layout ────────────────────────────────────────────────────────
    # ui.gaps         = lib.mkDefault 15;    # i3 inner gaps (px)
    # ui.border       = lib.mkDefault 2;     # Window border width (px)
    # ui.cornerRadius = lib.mkDefault 2;     # Picom corner radius (px)

    # ─── Polybar sizing ────────────────────────────────────────────────
    # ui.barHeight          = lib.mkDefault 23;    # Bar height (px)
    # ui.barPadding         = lib.mkDefault 2;     # Internal bar padding
    # ui.polybarFontOffset  = lib.mkDefault 3;     # Vertical text centering offset
    # ui.barGaps            = lib.mkDefault null;  # Bar-to-edge margin (null = gaps/2)
    # ui.barEdgeGapsFactor  = lib.mkDefault 1.0;   # Scale bar-to-edge spacing (0.0–1.0)
    # ui.outerGapsMatchBar  = lib.mkDefault false; # i3 outer gaps match barGaps

    # ─── Opacity ───────────────────────────────────────────────────────
    # ui.opacity.overlay          = lib.mkDefault 0.85;
    # ui.opacity.overlayOverrides = lib.mkDefault { alacritty = 0.95; };
    # ui.opacity.active           = lib.mkDefault 1.0;
    # ui.opacity.inactive         = lib.mkDefault 1.0;
    # ui.opacity.exclude          = lib.mkDefault [ "Alacritty" "feh" "Feh" "firefox" "Firefox" "mpv" "vlc" ];
    # ui.opacity.rules            = lib.mkDefault { "Polybar" = 95; };

    # ─── Compositor (picom) ────────────────────────────────────────────
    # ui.compositor.animations = lib.mkDefault "modern";  # "none" or "modern"
    # ui.shadowRadius          = lib.mkDefault 18;
    # ui.shadowOffset          = lib.mkDefault 17;

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
    # scaling.internalResolution  = lib.mkDefault "1920x1200";  # null = auto-detect
    # scaling.standaloneScaleFactor = lib.mkDefault 1.0;        # scale in VM standalone mode
    # scaling.applyOnLogin        = lib.mkDefault true;

    # ─── VM resource bar (inside VMs) ──────────────────────────────────
    # vmBar.enable   = lib.mkDefault true;
    # vmBar.position = lib.mkDefault "bottom";

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
    # lockscreen.text        = lib.mkDefault "Papers, please";
    # lockscreen.wrongText   = lib.mkDefault "Ah ah ah! You didn't say the magic word!!";
    # lockscreen.verifyText  = lib.mkDefault "Verifying...";
    # lockscreen.blur        = lib.mkDefault true;

    # ─── Splash screen ─────────────────────────────────────────────────
    # splash.enable     = lib.mkDefault false;
    # splash.title      = lib.mkDefault "HYDRIX";
    # splash.text       = lib.mkDefault "initializing...";
    # splash.maxTimeout = lib.mkDefault 15;
    # splash.font       = lib.mkDefault null;  # null = CozetteVector
  };

  # ─── VM color inheritance ─────────────────────────────────────────────
  # hydrix.colorschemeInheritance = lib.mkDefault "dynamic";
  #   "full"    — VMs use all host wal colors
  #   "dynamic" — VMs use host background + their own text colors
  #   "none"    — VMs use their own colorscheme independently
}
