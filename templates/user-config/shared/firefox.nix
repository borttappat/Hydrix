# Firefox — User Configuration
#
# Base Firefox settings applying to all machines and VMs.
# Profile-specific extensions are set in each profiles/<name>/default.nix.
#
# Available userAgent presets:
#   "edge-windows"     — Microsoft Edge on Windows
#   "chrome-windows"   — Google Chrome on Windows
#   "chrome-mac"       — Google Chrome on macOS
#   "safari-mac"       — Safari on macOS
#   "firefox-windows"  — Firefox on Windows (only changes OS fingerprint)
#   null               — Real Firefox UA (default)
#
# Available extensions (set per-profile in profiles/<name>/default.nix):
#   ublock-origin   — ad and tracker blocking
#   pywalfox        — colorscheme sync with pywal
#   vimium-ff       — vim-like keyboard navigation
#   detach-tab      — detach tabs to new windows
#   bitwarden       — password manager
#   foxyproxy       — proxy management (pentest)
#   wappalyzer      — tech stack detection (pentest)
#   singlefile      — save complete web pages (pentest)
#   darkreader      — dark mode for all websites
#   styl-us         — user styles manager

{ lib, ... }:

{
  # Install Firefox on the host system (it's always on in VMs)
  hydrix.graphical.firefox.hostEnable = lib.mkDefault false;

  # User-agent spoofing — set per-profile, not globally
  # hydrix.graphical.firefox.userAgent = lib.mkDefault "edge-windows";

  # UI preferences (applied to all VMs/host)
  hydrix.graphical.firefox.verticalTabs = lib.mkDefault true;
  hydrix.graphical.firefox.uidensity = lib.mkDefault 1;  # 0=normal, 1=compact, 2=touch
  hydrix.graphical.firefox.search.default = lib.mkDefault "ddg";
}
