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
  # -------------------------------------------------------------------------

  # Top bar
  # hydrix.graphical.ui.bar.top.left   = null;  # default: xworkspaces [workspace-desc] focus[-dynamic]
  # hydrix.graphical.ui.bar.top.center = null;  # default: (empty)
  # hydrix.graphical.ui.bar.top.right  = null;  # default: pomo[-dynamic] git[-changes] vms battery ... date

  # Bottom bar
  # hydrix.graphical.ui.bar.bottom.left   = null;  # default: power-profile-dynamic battery[-dynamic] ...
  # hydrix.graphical.ui.bar.bottom.center = null;  # default: (empty)
  # hydrix.graphical.ui.bar.bottom.right  = null;  # default: VM metrics (rproc cproc vm-ram ...)
}
