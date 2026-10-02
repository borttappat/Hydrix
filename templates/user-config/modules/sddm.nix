# Hydrix SDDM login manager, themed to match the hyprlock lockscreen.
# Option declarations + implementation live in the framework
# (theming/dm/sddm.nix); this file just sets values.
#
# Text, font, clock size and blur follow hydrix.graphical.lockscreen.*, colors
# follow the active colorscheme, so login and lockscreen look the same.
#
# greetd (modules/greetd.nix) is the backup login manager. The two are
# mutually exclusive: to switch, set sddm.enable = false and
# greetd.enable = true.
{lib, ...}: {
  hydrix.sddm = {
    enable = lib.mkDefault true;
    # preview = lib.mkDefault false;  # DEFAULT: false - adds hydrix-sddm-preview (windowed test mode, Esc quits)
    # followWal = lib.mkDefault true;  # DEFAULT: false - follow runtime wal colors, restore-colorscheme reverts

    # background = ./wallpapers/login.png;  # DEFAULT: hydrix.grub.theme.background, null = solid bg color
    # scale = 1.5;                          # DEFAULT: hydrix.graphical.scaling.hyprInternalScale (or 1.0)
    # fieldWidth = 300;                     # DEFAULT: 300, mirrors hyprlock's input field
    # fieldHeight = 55;                     # DEFAULT: 55

    # colors = {                            # DEFAULT: colorscheme slots hyprlock uses
    #   bg     = "#050505";
    #   fg     = "#dfdfdf";
    #   accent = "#05AF5A";
    #   wrong  = "#ff5555";
    # };
  };
}
