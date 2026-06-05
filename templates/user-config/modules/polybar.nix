# Polybar — User Configuration
#
# All polybar settings go through hydrix.graphical.ui.* options.
# The framework generates the full polybar config from these values at build time.
# Plain assignment here overrides lib.mkDefault values from graphical.nix.
#
# Available modules by style:
#
#   MODULAR (dynamic underline style):
#     pomo-dynamic  sync-dynamic   git-dynamic    mvms-dynamic   vms-dynamic
#     volume-dynamic temp-dynamic  ram-dynamic    cpu-dynamic    fs-dynamic
#     uptime-dynamic date-dynamic  battery-dynamic battery-time-dynamic
#     focus-dynamic  xworkspaces   workspace-desc spacer
#     power-profile-dynamic
#     (bottom) rproc-bottom  cproc-bottom  vm-ram-bottom  vm-cpu-bottom
#              vm-sync-dev-bottom  vm-sync-stg-bottom  vm-fs-bottom
#              vm-tun-bottom  vm-up-bottom
#
#   UNIBAR (solid bar style):
#     pomo  git-changes  vm-count  vm-sync  battery  essid
#     nwup  nwdown  ip  volume  temp  memory  cpu  filesystem  uptime  date
#     focus  xworkspaces  workspace-desc  spacer
#
# null = use the style default layout.

{ lib, ... }:

{
  # -------------------------------------------------------------------------
  # Style
  # "modular" — floating modules with transparent background and dynamic underlines
  # "unibar"  — classic solid bar with separator between modules
  # -------------------------------------------------------------------------
  hydrix.graphical.ui.polybarStyle = lib.mkDefault "modular";

  # -------------------------------------------------------------------------
  # Bar visibility
  # -------------------------------------------------------------------------
  hydrix.graphical.ui.floatingBar = lib.mkDefault true;   # detached from screen edge
  hydrix.graphical.ui.bottomBar   = lib.mkDefault true;   # second bar with VM metrics

  # -------------------------------------------------------------------------
  # Bar gaps
  # barGaps — space between bar and screen edge in pixels (null = gaps/2)
  # barEdgeGapsFactor — scale bar-to-edge spacing (0.0 = flush, 1.0 = full gap)
  # -------------------------------------------------------------------------
  # hydrix.graphical.ui.barGaps           = lib.mkDefault null;
  # hydrix.graphical.ui.barEdgeGapsFactor = lib.mkDefault 1.0;

  # -------------------------------------------------------------------------
  # Workspace labels  (number → display string)
  # -------------------------------------------------------------------------
  hydrix.graphical.ui.workspaceLabels = lib.mkDefault {
    "1" = "I";  "2" = "II";  "3" = "III"; "4" = "IV"; "5" = "V";
    "6" = "VI"; "7" = "VII"; "8" = "VIII"; "9" = "IX"; "10" = "X";
  };

  # -------------------------------------------------------------------------
  # Workspace descriptions  (shown by workspace-desc module)
  # Map workspace number → short label (e.g. VM name, task description)
  # VM workspaces are auto-populated from the vm-registry; add host-only ones here.
  # -------------------------------------------------------------------------
  # hydrix.graphical.ui.workspaceDescriptions = lib.mkDefault {
  #   "1" = "HOST";
  # };

  # -------------------------------------------------------------------------
  # Module layout  (null = use style default)
  # Set to a space-separated string of module names to override.
  # Full defaults shown below for reference — uncomment and edit to customise.
  # -------------------------------------------------------------------------

  # Top bar left  (default when VMs present: xworkspaces spacer workspace-desc focus-dynamic)
  # hydrix.graphical.ui.bar.top.left = "xworkspaces spacer workspace-desc focus-dynamic";

  # Top bar center  (default: empty)
  # hydrix.graphical.ui.bar.top.center = "";

  # Top bar right  (modular default)
  # hydrix.graphical.ui.bar.top.right = "pomo-dynamic spacer sync-dynamic git-dynamic mvms-dynamic vms-dynamic spacer volume-dynamic temp-dynamic spacer ram-dynamic cpu-dynamic spacer fs-dynamic uptime-dynamic date-dynamic";

  # Bottom bar left  (modular default)
  # hydrix.graphical.ui.bar.bottom.left = "power-profile-dynamic battery-dynamic battery-time-dynamic spacer rproc-dynamic cproc-dynamic";

  # Bottom bar center  (default: empty)
  # hydrix.graphical.ui.bar.bottom.center = "";

  # Bottom bar right  (modular default)
  # hydrix.graphical.ui.bar.bottom.right = "rproc-bottom cproc-bottom vm-ram-bottom vm-cpu-bottom spacer vm-sync-dev-bottom vm-sync-stg-bottom vm-fs-bottom spacer vm-tun-bottom vm-up-bottom";
}
