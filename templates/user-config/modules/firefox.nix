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
# Built-in extension registry (select per-profile via firefox.extensions):
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
#
# To add a custom extension, use firefox-extension-add <slug> to get the entry,
# then add it to firefox.extensionRegistry below and select it per-profile.

{ config, lib, pkgs, ... }:

let
  reg  = config.hydrix.graphical.firefox.extensionRegistry;
  exts = config.hydrix.graphical.firefox.extensions;
  # Extensions with a pinned reg.<name>.hash are fetched once at build time
  # and hash-verified instead of Firefox fetching install_url live at runtime.
  # Opt-in per extension; see firefox.extensionRegistry.<name>.hash in
  # Hydrix/theming/options.nix.
  mkExtSettings = names:
    builtins.listToAttrs (map (n: let
      ext = reg.${n};
      installUrl =
        if ext.hash != null
        then "file://${pkgs.fetchFirefoxAddon {
               name = n;
               url = ext.url;
               hash = ext.hash;
               fixedExtid = ext.id;
             }}/${ext.id}.xpi"
        else ext.url;
    in {
      name  = ext.id;
      value = { install_url = installUrl; installation_mode = "force_installed"; };
    }) (builtins.filter (n: reg ? ${n}) names));
in

{
  # Install Firefox on the host system (it's always on in VMs)
  hydrix.graphical.firefox.hostEnable = lib.mkDefault true;

  # Default extension set for the host — override in machines/<serial>.nix if needed
  hydrix.graphical.firefox.extensions = lib.mkDefault [
    "ublock-origin" "bitwarden" "vimium-ff" "darkreader" "pywalfox"
  ];

  # Wire extensions into the actual Firefox policy so they are force-installed.
  # References the final merged value of hydrix.graphical.firefox.extensions, so
  # profile-specific lists in profiles/<name>/default.nix are respected automatically.
  programs.firefox.policies.ExtensionSettings = mkExtSettings exts;

  # User-agent spoofing — set per-profile, not globally
  # hydrix.graphical.firefox.userAgent = lib.mkDefault "edge-windows";

  # UI preferences (applied to all VMs/host)
  hydrix.graphical.firefox.verticalTabs = lib.mkDefault true;
  hydrix.graphical.firefox.uidensity = lib.mkDefault 1;  # 0=normal, 1=compact, 2=touch
  hydrix.graphical.firefox.search.default = lib.mkDefault "ddg";

  # Startup homepage — set to your preferred URL, or leave null for about:home
  # hydrix.graphical.firefox.homepage = lib.mkDefault "https://example.com";

  # New tab page — null = Firefox activity stream, "about:blank" = blank
  # Custom URLs require the "New Tab Override" extension in your profile's extension list
  # hydrix.graphical.firefox.newTab = lib.mkDefault "about:blank";
}
