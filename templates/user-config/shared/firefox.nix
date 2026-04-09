# Firefox — User Configuration
#
# Controls whether Firefox is installed on the host and which user-agent to use.
# Firefox is always enabled in VMs (browsing, dev, etc.) — this only affects the host.
#
# Extensions are managed per-profile in the framework.
# To add an extension to a VM profile, run inside the VM:
#   firefox-extension-add <extension-slug>
# (slug = last part of addons.mozilla.org/en-US/firefox/addon/<slug>/)
#
# Available userAgent presets:
#   "edge-windows"     — Microsoft Edge on Windows
#   "chrome-windows"   — Google Chrome on Windows
#   "chrome-mac"       — Google Chrome on macOS
#   "safari-mac"       — Safari on macOS
#   "firefox-windows"  — Firefox on Windows (only changes OS fingerprint)
#   null               — Real Firefox UA (default)

{ lib, ... }:

{
  # Install Firefox on the host system (it's always on in VMs)
  hydrix.graphical.firefox.hostEnable = lib.mkDefault false;

  # User-agent spoofing (applies everywhere Firefox runs)
  # hydrix.graphical.firefox.userAgent = lib.mkDefault "edge-windows";
}
