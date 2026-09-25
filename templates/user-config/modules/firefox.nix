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
#
# Wal-themed Firefox chrome and hints, both on by default:
#   vimiumHints  restyles stock vimium-ff link hints (userContent.css)
#   walMenus     restyles context and dropdown menus (userChrome.css)
# A user service regenerates vimium-hints.css and wal-menus.css in the profile's
# chrome/ dir from ~/.cache/wal/colors.json at login and whenever it changes;
# Firefox reads them at startup, so new colors apply on the next launch. Opt
# out per VM with e.g.
#   hydrix.graphical.firefox.vimiumHints.enable = false;

{ config, lib, pkgs, ... }:

let
  reg  = config.hydrix.graphical.firefox.extensionRegistry;
  exts = config.hydrix.graphical.firefox.extensions;
  # Extensions with a pinned reg.<name>.hash are fetched once at build time
  # and hash-verified instead of Firefox fetching install_url live at runtime.
  # Opt-in per extension; see firefox.extensionRegistry.<name>.hash in
  # Hydrix/theming/options.nix.
  #
  # Uses plain pkgs.fetchurl, not pkgs.fetchFirefoxAddon -- the latter
  # unpacks the .xpi, rewrites manifest.json (injects a legacy "applications"
  # key via jq) and re-zips, but reuses the *original* META-INF/manifest.mf,
  # which still lists the digest of the pre-rewrite manifest.json. That
  # mismatch makes Firefox reject the install as "not correctly signed"
  # (confirmed via Browser Console: addons.xpi-utils WARN Add-on <id> is not
  # correctly signed). fetchurl does zero content modification -- the hash
  # pins the exact untouched upstream bytes, signature intact.
  mkExtSettings = names:
    builtins.listToAttrs (map (n: let
      ext = reg.${n};
      installUrl =
        if ext.hash != null
        then "file://${pkgs.fetchurl { name = "${n}.xpi"; url = ext.url; hash = ext.hash; }}"
        else ext.url;
    in {
      name  = ext.id;
      value = { install_url = installUrl; installation_mode = "force_installed"; };
    }) (builtins.filter (n: reg ? ${n}) names));

  hints    = config.hydrix.graphical.firefox.vimiumHints;
  menus    = config.hydrix.graphical.firefox.walMenus;
  username = config.hydrix.username;
  # Same profile path the Hydrix firefox launcher uses.
  chromeDir   = "/home/${username}/.mozilla/firefox/default/chrome";
  hintCssPath = "${chromeDir}/vimium-hints.css";
  menuCssPath = "${chromeDir}/wal-menus.css";
  hintSel     = "#vimium-hint-marker-container div.internal-vimium-hint-marker";

  # Absolute: userChrome/userContent.css are home-manager symlinks into the
  # store, and a relative @import resolves against the link target. @import
  # must precede every other rule in the sheet.
  importCss = path: lib.mkBefore ''
    @import url("file://${path}");
  '';

  generateWalCss = pkgs.writeShellScript "firefox-wal-css" ''
    set -eu
    colors="$HOME/.cache/wal/colors.json"
    [ -f "$colors" ] || exit 0
    mkdir -p "${chromeDir}"
    c() { ${pkgs.jq}/bin/jq -er --arg k "$1" '.colors[$k] // .special[$k]' "$colors"; }
    ${lib.optionalString hints.enable ''
    cat > "${hintCssPath}.tmp" <<EOF
    ${hintSel} {
      background: color-mix(in srgb, $(c ${hints.colors.bg}) ${toString hints.opacity}%, transparent) !important;
      border: ${hints.borderWidth} solid $(c ${hints.colors.border}) !important;
      border-radius: ${hints.borderRadius} !important;
      padding: ${hints.padding} !important;
      box-shadow: ${if hints.shadow then "0 1px 3px rgba(0, 0, 0, 0.4)" else "none"} !important;
    }
    ${hintSel} span {
      color: $(c ${hints.colors.text}) !important;
      font-size: ${hints.fontSize} !important;
      ${lib.optionalString (hints.fontFamily != null) ''font-family: "${hints.fontFamily}", monospace !important;''}
      text-shadow: none !important;
    }
    ${hintSel} > .matchingCharacter {
      color: $(c ${hints.colors.match}) !important;
    }
    #vimium-hint-marker-container div.vimiumActiveHintMarker span {
      color: $(c ${hints.colors.active}) !important;
    }
    EOF
    mv "${hintCssPath}.tmp" "${hintCssPath}"
    ''}
    ${lib.optionalString menus.enable ''
    cat > "${menuCssPath}.tmp" <<EOF
    menupopup:not([type="arrow"]) {
      --panel-background-color: $(c ${menus.colors.bg}) !important;
      --panel-text-color: $(c ${menus.colors.text}) !important;
      --panel-border-color: $(c ${menus.colors.border}) !important;
      --panel-separator-color: $(c ${menus.colors.border}) !important;
      --text-color-disabled: $(c ${menus.colors.disabled}) !important;
    }
    menupopup :is(menu, menuitem)[_moz-menuactive]:not([disabled]) {
      color: $(c ${menus.colors.hoverText}) !important;
      background-color: $(c ${menus.colors.hoverBg}) !important;
    }
    EOF
    mv "${menuCssPath}.tmp" "${menuCssPath}"
    ''}
  '';

  # Color roles take a wal key: "color0".."color15", "background", "foreground".
  strOpt = default: lib.mkOption { type = lib.types.str; inherit default; };
in

{
  options.hydrix.graphical.firefox.vimiumHints = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Theme vimium-ff link hints from wal colors via userContent.css.";
    };
    colors = {
      bg     = strOpt "color3";
      border = strOpt "color8";
      text   = strOpt "color0";
      match  = strOpt "color1";
      active = strOpt "foreground";
    };
    opacity = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 100;
      description = "Hint background opacity in percent. Text stays opaque.";
    };
    borderRadius = strOpt "3px";
    borderWidth  = strOpt "1px";
    padding      = strOpt "1px 3px";
    fontSize     = strOpt "11px";
    fontFamily = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Hint font. Null keeps the userContent.css system font.";
    };
    shadow = lib.mkOption { type = lib.types.bool; default = true; };
  };

  options.hydrix.graphical.firefox.walMenus = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Theme Firefox context and dropdown menus from wal colors via userChrome.css.";
    };
    colors = {
      bg        = strOpt "background";
      text      = strOpt "foreground";
      border    = strOpt "color8";
      disabled  = strOpt "color8";
      hoverBg   = strOpt "color3";
      hoverText = strOpt "background";
    };
  };

  config = lib.mkMerge [
    {
      # Install Firefox on the host system (it's always on in VMs)
      hydrix.graphical.firefox.hostEnable = lib.mkDefault true;

      # Default extension set for the host; override in machines/<serial>.nix if needed
      hydrix.graphical.firefox.extensions = lib.mkDefault [
        "ublock-origin" "bitwarden" "vimium-ff" "darkreader" "pywalfox"
      ];

      # Wire extensions into the actual Firefox policy so they are force-installed.
      # References the final merged value of hydrix.graphical.firefox.extensions, so
      # profile-specific lists in profiles/<name>/default.nix are respected automatically.
      programs.firefox.policies.ExtensionSettings = mkExtSettings exts;

      # User-agent spoofing: set per-profile, not globally
      # hydrix.graphical.firefox.userAgent = lib.mkDefault "edge-windows";

      # UI preferences (applied to all VMs/host)
      hydrix.graphical.firefox.verticalTabs = lib.mkDefault true;
      hydrix.graphical.firefox.uidensity = lib.mkDefault 1;  # 0=normal, 1=compact, 2=touch
      hydrix.graphical.firefox.search.default = lib.mkDefault "ddg";

      # Toolbar decluttering: each hides one element, independent of the others
      # hydrix.graphical.firefox.hideFirefoxViewButton = lib.mkDefault true;
      # hydrix.graphical.firefox.hideAllTabsButton = lib.mkDefault true;
      # hydrix.graphical.firefox.hideSidebarLauncher = lib.mkDefault true;
      # hydrix.graphical.firefox.hideExtensionIcons = lib.mkDefault true;

      # Startup homepage: set to your preferred URL, or leave null for about:home
      # hydrix.graphical.firefox.homepage = lib.mkDefault "https://example.com";

      # New tab page: null = Firefox activity stream, "about:blank" = blank
      # Custom URLs require the "New Tab Override" extension in your profile's extension list
      # hydrix.graphical.firefox.newTab = lib.mkDefault "about:blank";
    }

    (lib.mkIf (config.programs.firefox.enable && (hints.enable || menus.enable)) {
      home-manager.users.${username} = {
        programs.firefox.profiles.default = {
          userContent = lib.mkIf hints.enable (importCss hintCssPath);
          userChrome = lib.mkIf menus.enable (importCss menuCssPath);
        };

        systemd.user.services.firefox-wal-css = {
          Unit.Description = "Generate Firefox chrome/hint CSS from wal colors";
          Service = { Type = "oneshot"; ExecStart = "${generateWalCss}"; };
          Install.WantedBy = [ "default.target" ];
        };
        systemd.user.paths.firefox-wal-css = {
          Unit.Description = "Regenerate Firefox wal CSS when wal colors change";
          Path.PathChanged = "%h/.cache/wal/colors.json";
          Install.WantedBy = [ "default.target" ];
        };
      };
    })
  ];
}
