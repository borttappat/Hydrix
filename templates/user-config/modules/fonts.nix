{ config, lib, pkgs, ... }:
{
  imports = [ ../fonts ];

  hydrix.graphical.font = {

    # ─── Font packages ─────────────────────────────────────────────────
    # Packages installed on the host graphical environment.
    packages = with pkgs; [ iosevka iosevka-bin cozette tamzen monocraft miracode ];

    # Map font family names → nix packages (used by Stylix for rendering)
    packageMap = with pkgs; {
      "Iosevka"        = iosevka;
      "JetBrains Mono" = jetbrains-mono;
      "Hack"           = hack-font;
      "Tamzen"         = tamzen;
      "CozetteVector"  = cozette;
      "Cozette"        = cozette;
      "Terminus"       = terminus_font;
      "Fira Code"      = fira-code;
    };

    # Always-installed packages (emoji, serif fallbacks)
    extraPackages = with pkgs; [ dejavu_fonts noto-fonts-color-emoji ];

    # Packages installed in microVMs
    vmPackages = with pkgs; [ iosevka tamzen scientifica gohufont font-awesome noto-fonts noto-fonts-emoji ];

    # ─── Font family and size ──────────────────────────────────────────
    # Set here for a shared default across all machines, or override per
    # machine in machines/<serial>.nix with plain assignment.
    #
    # family = lib.mkDefault "Iosevka";   # Must be a key in packageMap above
    # size   = lib.mkDefault 10;          # Base size at 96 DPI (supports decimals)

    # ─── Per-app size multipliers ──────────────────────────────────────
    # Final size = base × scale_factor × relation
    # Override individual apps without changing the base size.
    #
    # relations = lib.mkDefault {
    #   alacritty = 1.0;
    #   polybar   = 1.0;
    #   rofi      = 1.0;
    #   dunst     = 1.0;
    #   firefox   = 1.2;
    #   gtk       = 1.0;
    # };

    # Per-app multipliers when no external monitor is connected
    # standaloneRelations = lib.mkDefault {
    #   alacritty = 1.05;
    # };

    # ─── Per-app font family overrides ────────────────────────────────
    # Use a different font for specific apps while keeping the main family elsewhere.
    #
    # familyOverrides = lib.mkDefault {
    #   polybar = "Tamzen";
    # };

    # ─── Fixed size overrides (bypass DPI scaling) ─────────────────────
    # Pins an app to an exact pixel size regardless of DPI or relations.
    # Useful for bitmap fonts that only render well at specific sizes.
    #
    # overrides = lib.mkDefault {
    #   alacritty = 10.5;
    # };

    # Per-app maximum size caps (clamp after DPI scaling)
    # maxSizes = lib.mkDefault {
    #   polybar = 13;
    # };
  };
}
