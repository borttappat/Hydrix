# Hydrix greetd login manager, the backup to SDDM (modules/sddm.nix).
# Option declarations + implementation live in the framework
# (theming/dm/greetd.nix); this file just sets values.
#
# The two are mutually exclusive: to switch, set greetd.enable = true and
# sddm.enable = false.
#
# Two interchangeable frontends, switch `frontend` to compare:
#   - tuigreet (default): minimal TUI, colors only, no known open issues
#   - regreet: GTK greeter with background image + CSS theming, nicer visual
#     ceiling but has rough edges (oversized default font, incomplete CSS
#     coverage on some widgets), not yet as solid as tuigreet.
{
  config,
  lib,
  pkgs,
  ...
}: {
  hydrix.greetd = {
    enable = lib.mkDefault false;
    frontend = lib.mkDefault "tuigreet";
    # fontSize = lib.mkDefault 16;  # DEFAULT: 16, regreet only (tuigreet has no font control)

    # Wallpaper for the regreet background. Ignored by tuigreet.
    # background = "${hydrix}/theming/wallpapers/Hydrix.png";

    # colors = {
    #   bg     = "#050505";
    #   fg     = "#dfdfdf";
    #   accent = "#05AF5A";
    #   muted  = "#A0A0A0";
    # };
  };
}
