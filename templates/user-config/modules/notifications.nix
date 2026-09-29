# Notifications (swaync) - user preferences
#
# Layout (placement, sizing, timeouts) is written to ~/.config/swaync on every
# rebuild; colors and per-sender borders come from wal and the window border
# logic via swaync-apply-colors, rewritten on every colorscheme change and
# hydrix-focus toggle. Popups appear top-right, below the bar, inset by
# offset (5px default) past a tiled window's edge on both axes. $mod+Shift+N
# opens the panel (history, do not disturb).
{lib, ...}: {
  # Show popups (off = notifications only land in the panel)
  hydrix.graphical.ui.notifications.popups = lib.mkDefault true;

  # Popup width (pixels)
  hydrix.graphical.ui.notifications.width = lib.mkDefault 300;

  # Notification sound: set to a sound file path to enable
  # hydrix.graphical.ui.notifications.sound = lib.mkDefault null;

  # Timeouts per urgency (seconds, 0 = never expire)
  hydrix.graphical.ui.notifications.timeout.low = lib.mkDefault 5;
  hydrix.graphical.ui.notifications.timeout.normal = lib.mkDefault 10;
  hydrix.graphical.ui.notifications.timeout.critical = lib.mkDefault 0;
}
