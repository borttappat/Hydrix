# Graphical Configuration - Shared across all machines
#
# UI preferences that apply to every machine.
# Machine-specific overrides go in machines/<serial>.nix — plain assignment
# there takes priority over the lib.mkDefault values here.

{ config, lib, pkgs, ... }:

{
  hydrix.graphical = {

    # ─── Bar style ─────────────────────────────────────────────────────
    # ui.polybarStyle = lib.mkDefault "modular";  # "unibar", "modular", "pills"
    # ui.floatingBar  = lib.mkDefault true;
    # ui.bottomBar    = lib.mkDefault true;       # Bottom bar with VM metrics

    # ─── Bar module layout ─────────────────────────────────────────────
    # Override which modules appear in each bar position.
    # null = use the style default for that position.
    # Available modules depend on polybarStyle:
    #   modular style uses *-dynamic variants (volume-dynamic, cpu-dynamic, etc.)
    #   unibar style uses plain names (volume, cpu, etc.)
    #
    # ui.bar.top.left   = lib.mkDefault null;
    # ui.bar.top.center = lib.mkDefault null;
    # ui.bar.top.right  = lib.mkDefault null;
    #   # e.g. "volume-dynamic cpu-dynamic ram-dynamic date-dynamic"
    #
    # ui.bar.bottom.left   = lib.mkDefault null;
    # ui.bar.bottom.center = lib.mkDefault null;
    # ui.bar.bottom.right  = lib.mkDefault null;
    #   # e.g. "battery-dynamic spacer cpu-dynamic ram-dynamic"

    # ─── Layout ────────────────────────────────────────────────────────
    # ui.gaps        = lib.mkDefault 15;   # i3 inner gaps
    # ui.border      = lib.mkDefault 2;    # Window border width
    # ui.cornerRadius = lib.mkDefault 2;   # Picom corner radius

    # ─── Workspace labels ──────────────────────────────────────────────
    # Default: roman numerals I–X
    # ui.workspaceLabels = lib.mkDefault { "1" = "web"; "2" = "code"; };
    # ui.workspaceDescriptions = lib.mkDefault { "1" = "browsing"; };

    # ─── Opacity ───────────────────────────────────────────────────────
    # ui.opacity.overlay         = lib.mkDefault 0.85;
    # ui.opacity.overlayOverrides = lib.mkDefault { alacritty = 0.95; };
    # ui.opacity.active          = lib.mkDefault 1.0;
    # ui.opacity.inactive        = lib.mkDefault 1.0;
    # ui.opacity.exclude         = lib.mkDefault [ "Alacritty" "firefox" "mpv" ];
    # ui.opacity.rules           = lib.mkDefault { "Polybar" = 95; };

    # ─── Compositor (picom) ────────────────────────────────────────────
    # ui.compositor.animations = lib.mkDefault "modern";  # "none" or "modern"
    # ui.shadowRadius = lib.mkDefault 18;
    # ui.shadowOffset = lib.mkDefault 17;

    # ─── Keyboard remapping ────────────────────────────────────────────
    # keyboard.xmodmap = lib.mkDefault ''
    #   clear lock
    #   clear control
    #   keycode 66 = Control_L
    #   add control = Control_L Control_R
    # '';

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
    # lockscreen.idleTimeout = lib.mkDefault 600;  # null to disable
    # lockscreen.text        = lib.mkDefault "Papers, please";
    # lockscreen.wrongText   = lib.mkDefault "Ah ah ah! You didn't say the magic word!!";
    # lockscreen.verifyText  = lib.mkDefault "Verifying...";
    # lockscreen.blur        = lib.mkDefault true;

    # ─── Splash screen ─────────────────────────────────────────────────
    # splash.enable     = lib.mkDefault false;
    # splash.title      = lib.mkDefault "HYDRIX";
    # splash.text       = lib.mkDefault "initializing...";
    # splash.maxTimeout = lib.mkDefault 15;
  };

  # ─── VM color inheritance ─────────────────────────────────────────────
  # hydrix.colorschemeInheritance = lib.mkDefault "dynamic";
  #   "full"    — VMs use all host wal colors
  #   "dynamic" — VMs use host background + their own text colors
  #   "none"    — VMs use their own colorscheme independently
}
