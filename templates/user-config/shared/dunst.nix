# Dunst Notification Daemon — User Preferences
#
# Dunst config is generated at runtime by the framework (generate-dunstrc) from
# scaling.json and xrdb colors. Most visual settings follow the colorscheme
# automatically. The options below control dunst behaviour via hydrix.* options.

{ lib, ... }:

{
  # -------------------------------------------------------------------------
  # Notification sounds
  # Default: true — set to false to silence all notification sounds.
  # -------------------------------------------------------------------------
  # hydrix.graphical.ui.dunstSound = lib.mkDefault false;

  # -------------------------------------------------------------------------
  # Notification popup width (pixels)
  # Default: 300
  # -------------------------------------------------------------------------
  # hydrix.graphical.ui.dunstWidth = lib.mkDefault 300;

  # -------------------------------------------------------------------------
  # Offset from screen edge (pixels)
  # Default: 24 — distance of notification popup from bar/screen edge.
  # -------------------------------------------------------------------------
  # hydrix.graphical.ui.dunstOffset = lib.mkDefault 24;
}
