# Zathura PDF Viewer — User Configuration
#
# All settings use hydrix.graphical.zathura.* options.
# Framework defaults are shown commented out — uncomment to override.
# Colors and font are injected at runtime from the wal cache (no rebuild needed).
#
# Framework defaults:
#   recolor = true, recolorReverseVideo = true, recolorKeepHue = false
#   selectionClipboard = "clipboard"
#   scrollPageAware = true, scrollStep = 100, scrollFullOverlap = "0.01"
#   zoomMin = 10, zoomMax = 400, zoomStep = 10
#   incrementalSearch = true
#   sandbox = "none"
#   mappings = { D=toggle_page_mode, r=reload, R=rotate, K=zoom in, J=zoom out, i=recolor, p=print }

{ lib, ... }:

{
  # ── Recolor ────────────────────────────────────────────────────────────────
  # hydrix.graphical.zathura.recolor             = true;
  # hydrix.graphical.zathura.recolorReverseVideo = true;
  # hydrix.graphical.zathura.recolorKeepHue      = false;

  # ── Clipboard ──────────────────────────────────────────────────────────────
  # hydrix.graphical.zathura.selectionClipboard = "clipboard";  # or "primary"

  # ── Scroll ─────────────────────────────────────────────────────────────────
  # hydrix.graphical.zathura.scrollPageAware  = true;
  # hydrix.graphical.zathura.scrollStep       = 100;
  # hydrix.graphical.zathura.scrollFullOverlap = "0.01";

  # ── Zoom ───────────────────────────────────────────────────────────────────
  # hydrix.graphical.zathura.zoomMin  = 10;
  # hydrix.graphical.zathura.zoomMax  = 400;
  # hydrix.graphical.zathura.zoomStep = 10;

  # ── Search ─────────────────────────────────────────────────────────────────
  # hydrix.graphical.zathura.incrementalSearch = true;

  # ── Sandbox ────────────────────────────────────────────────────────────────
  # hydrix.graphical.zathura.sandbox = "none";  # none, normal, strict

  # ── Key mappings ───────────────────────────────────────────────────────────
  # Override the full mapping set (replaces framework defaults):
  # hydrix.graphical.zathura.mappings = {
  #   D = "toggle_page_mode";
  #   r = "reload";
  #   R = "rotate";
  #   K = "zoom in";
  #   J = "zoom out";
  #   i = "recolor";
  #   p = "print";
  # };

  # ── Extra config ───────────────────────────────────────────────────────────
  # hydrix.graphical.zathura.extraConfig = ''
  #   set pages-per-row 1
  #   set adjust-open best-fit
  # '';
}
