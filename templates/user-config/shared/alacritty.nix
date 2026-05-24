# Alacritty Terminal — User Configuration
#
# The framework handles: DPI font size, window opacity, color import,
# VM color inheritance, and keyboard bindings.
# Set cursor and selection preferences here.
#
# Framework defaults:
#   cursor.shape           = "Underline"  (Block | Underline | Beam)
#   cursor.blinking        = "Always"     (Never | Off | On | Always)
#   cursor.thickness       = 0.35
#   cursor.unfocusedHollow = false
#   cursor.blinkTimeout    = 0            (0 = never stop blinking)
#   cursor.blinkInterval   = 500
#   selection.saveToClipboard = true
#
# Opacity is set via hydrix.graphical.ui.opacity.overlay in graphical.nix.

{ lib, ... }:

{
  # ── Cursor ────────────────────────────────────────────────────────────────
  hydrix.graphical.alacritty.cursor.shape         = lib.mkDefault "Underline";
  hydrix.graphical.alacritty.cursor.blinking      = lib.mkDefault "Always";
  hydrix.graphical.alacritty.cursor.thickness     = lib.mkDefault 0.35;
  hydrix.graphical.alacritty.cursor.blinkTimeout  = lib.mkDefault 0;
  hydrix.graphical.alacritty.cursor.blinkInterval = lib.mkDefault 500;

  # ── Selection ──────────────────────────────────────────────────────────────
  hydrix.graphical.alacritty.selection.saveToClipboard = lib.mkDefault true;
}
