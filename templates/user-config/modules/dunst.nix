# Dunst Notification Daemon — User Preferences
#
# Layout (offset/sizing/timeouts) is written once per rebuild by
# generate-dunstrc-layout; colors come from wal via generate-dunstrc-colors,
# rewritten on every colorscheme change. Notifications appear top-right,
# below the bar. Options below configure behaviour via hydrix.graphical.ui.dunst* options.

{ lib, ... }:

{
  # Enable popup display
  hydrix.graphical.ui.dunstEnablePopup = lib.mkDefault true;

  # Notification popup width (pixels)
  hydrix.graphical.ui.dunstWidth = lib.mkDefault 300;

  # Notification sound — set to a sound file path to enable
  # hydrix.graphical.ui.dunstSound = lib.mkDefault null;

  # Browser used to open URLs from notifications
  hydrix.graphical.ui.dunstBrowser = lib.mkDefault "firefox";

  # Urgency timeouts in seconds (0 = never expire)
  hydrix.graphical.ui.dunstUrgencyTimeout.low      = lib.mkDefault 5;
  hydrix.graphical.ui.dunstUrgencyTimeout.normal   = lib.mkDefault 10;
  hydrix.graphical.ui.dunstUrgencyTimeout.critical = lib.mkDefault 0;
}
