# Firefox - User Configuration
#
# Base Firefox settings applying to all machines and VMs.
# Profile-specific extensions are set in each profiles/<name>/default.nix.
#
# Available userAgent presets:
#   "edge-windows"      Microsoft Edge on Windows
#   "chrome-windows"    Google Chrome on Windows
#   "chrome-mac"        Google Chrome on macOS
#   "safari-mac"        Safari on macOS
#   "firefox-windows"   Firefox on Windows (only changes OS fingerprint)
#   null                Real Firefox UA (default)
#
# Built-in extension registry (select per-profile via firefox.extensions):
#   ublock-origin    ad and tracker blocking
#   pywalfox         colorscheme sync with pywal
#   vimium-ff        vim-like keyboard navigation
#   detach-tab       detach tabs to new windows
#   bitwarden        password manager
#   foxyproxy        proxy management (pentest)
#   wappalyzer       tech stack detection (pentest)
#   singlefile       save complete web pages (pentest)
#   darkreader       dark mode for all websites
#   styl-us          user styles manager
#
# To add a custom extension, use firefox-extension-add <slug> to get the entry,
# then add it to firefox.extensionRegistry below and select it per-profile.
#
# Wal-themed Firefox chrome and vimium, all on by default:
#   vimiumHints  restyles stock vimium-ff link hints
#   vimiumUi     restyles the vimium vomnibar (o, O, T, b), HUD and help (?)
#   walMenus     restyles context menus, dropdowns and panels (hamburger menu)
# A user service regenerates vimium-hints.css, vimium-ui.css and wal-menus.css
# in the profile's chrome/ dir from ~/.cache/wal/colors.json at login and
# whenever it changes. An autoconfig script baked into the Firefox package
# registers the sheets and
# reloads them when they change, so new colors reach open windows live. Opt
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
  ui       = config.hydrix.graphical.firefox.vimiumUi;
  menus    = config.hydrix.graphical.firefox.walMenus;
  username = config.hydrix.username;
  # Same profile path the Hydrix firefox launcher uses.
  chromeDir   = "/home/${username}/.mozilla/firefox/default/chrome";
  hintCssPath = "${chromeDir}/vimium-hints.css";
  uiCssPath   = "${chromeDir}/vimium-ui.css";
  menuCssPath = "${chromeDir}/wal-menus.css";
  hintSel     = "#vimium-hint-marker-container div.internal-vimium-hint-marker";

  # Firefox autoconfig (mozilla.cfg, privileged). Registers the generated
  # sheets as user sheets, which the stylesheet service applies to chrome and
  # to every content process, then polls their mtime and swaps in a fresh copy
  # on change. The mtime query makes each version a distinct URI, bypassing
  # the style loader's per-URI cache.
  walCssPaths = lib.optional hints.enable hintCssPath
    ++ lib.optional ui.enable uiCssPath
    ++ lib.optional menus.enable menuCssPath;
  walCssReload = pkgs.writeText "firefox-wal-css-reload.js" ''
    try {
      const { classes: Cc, interfaces: Ci } = Components;
      const sss = Cc["@mozilla.org/content/style-sheet-service;1"].getService(Ci.nsIStyleSheetService);
      const io = Cc["@mozilla.org/network/io-service;1"].getService(Ci.nsIIOService);
      const sheets = ${builtins.toJSON walCssPaths}.map(path => ({ path, mtime: 0, uri: null }));
      const poll = () => {
        for (const s of sheets) {
          try {
            const f = Cc["@mozilla.org/file/local;1"].createInstance(Ci.nsIFile);
            f.initWithPath(s.path);
            const mtime = f.exists() ? f.lastModifiedTime : 0;
            if (mtime === s.mtime) continue;
            const old = s.uri;
            s.uri = mtime ? io.newURI("file://" + s.path + "?" + mtime) : null;
            s.mtime = mtime;
            if (s.uri) sss.loadAndRegisterSheet(s.uri, sss.USER_SHEET);
            if (old) sss.unregisterSheet(old, sss.USER_SHEET);
          } catch (e) {}
        }
      };
      const timer = Cc["@mozilla.org/timer;1"].createInstance(Ci.nsITimer);
      Cc["@mozilla.org/observer-service;1"].getService(Ci.nsIObserverService).addObserver({
        observe() {
          poll();
          timer.initWithCallback({ notify: poll }, 1000, Ci.nsITimer.TYPE_REPEATING_SLACK);
        },
      }, "final-ui-startup");
    } catch (e) {}
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
    ${lib.optionalString ui.enable ''
    cat > "${uiCssPath}.tmp" <<EOF
    @-moz-document url-prefix("moz-extension://") {
      #vomnibar, #hud-container {
        background: $(c ${ui.colors.bg}) !important;
        color: $(c ${ui.colors.text}) !important;
        border: 1px solid $(c ${ui.colors.border}) !important;
      }
      #vomnibar-search-area {
        border-bottom: 1px solid $(c ${ui.colors.border}) !important;
      }
      #vomnibar input {
        background: $(c ${ui.colors.inputBg}) !important;
        color: $(c ${ui.colors.text}) !important;
        border: none !important;
        box-shadow: none !important;
      }
      #search-area, #hud, #hud-body {
        background: transparent !important;
        color: $(c ${ui.colors.text}) !important;
        border: none !important;
      }
      #vomnibar input::selection {
        background: $(c ${ui.colors.selectedBg}) !important;
        color: $(c ${ui.colors.selectedText}) !important;
      }
      #vomnibar li {
        border-bottom: 1px solid color-mix(in srgb, $(c ${ui.colors.border}) 40%, transparent) !important;
      }
      #vomnibar li :is(.title, em) { color: $(c ${ui.colors.text}) !important; }
      #vomnibar li .url { color: $(c ${ui.colors.url}) !important; }
      #vomnibar li :is(.source, .relevancy), span#hud-match-count {
        color: $(c ${ui.colors.muted}) !important;
      }
      #vomnibar li .match { color: $(c ${ui.colors.match}) !important; }
      #vomnibar li.selected { background: $(c ${ui.colors.selectedBg}) !important; }
      #vomnibar li.selected :is(.title, em, .url, .source, .relevancy, .match) {
        color: $(c ${ui.colors.selectedText}) !important;
      }
    }
    @-moz-document regexp("moz-extension://[^/]+/pages/help_dialog_page.html.*") {
      #container {
        background: $(c ${ui.colors.bg}) !important;
        border-color: $(c ${ui.colors.border}) !important;
      }
      #dialog, h1, h2, .help-description {
        background: transparent !important;
        color: $(c ${ui.colors.text}) !important;
      }
      a, h1 .vim { color: $(c ${ui.colors.url}) !important; }
      a#close, .comma { color: $(c ${ui.colors.muted}) !important; }
      a#close:hover { color: $(c ${ui.colors.text}) !important; }
      div.divider { background-color: $(c ${ui.colors.border}) !important; }
      .key {
        background: $(c ${ui.colors.inputBg}) !important;
        color: $(c ${ui.colors.key}) !important;
        border-color: $(c ${ui.colors.border}) !important;
      }
    }
    EOF
    mv "${uiCssPath}.tmp" "${uiCssPath}"
    ''}
    ${lib.optionalString menus.enable ''
    cat > "${menuCssPath}.tmp" <<EOF
    @-moz-document url-prefix("chrome://") {
      :is(menupopup, panel) {
        --panel-background-color: $(c ${menus.colors.bg}) !important;
        --panel-text-color: $(c ${menus.colors.text}) !important;
        --panel-border-color: $(c ${menus.colors.border}) !important;
        --panel-separator-color: $(c ${menus.colors.border}) !important;
        --text-color-disabled: $(c ${menus.colors.disabled}) !important;
      }
      menupopup :is(menu, menuitem)[_moz-menuactive]:not([disabled]),
      panel .subviewbutton:not([disabled]):hover {
        color: $(c ${menus.colors.hoverText}) !important;
        background-color: $(c ${menus.colors.hoverBg}) !important;
      }
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
      description = "Theme vimium-ff link hints from wal colors, reloaded live.";
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
      description = "Hint font. Null keeps the page's system font.";
    };
    shadow = lib.mkOption { type = lib.types.bool; default = true; };
  };

  options.hydrix.graphical.firefox.vimiumUi = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Theme the vimium-ff vomnibar, HUD and help dialog from wal colors, reloaded live.";
    };
    colors = {
      bg           = strOpt "background";
      text         = strOpt "foreground";
      border       = strOpt "color8";
      inputBg      = strOpt "color0";
      selectedBg   = strOpt "color3";
      selectedText = strOpt "background";
      url          = strOpt "color4";
      match        = strOpt "color1";
      muted        = strOpt "color8";
      key          = strOpt "color3";
    };
  };

  options.hydrix.graphical.firefox.walMenus = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Theme Firefox menus and panels from wal colors, reloaded live.";
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

    (lib.mkIf config.programs.firefox.enable {
      # Sidebar launcher tools, comma-separated, in order. Built-ins: aichat,
      # syncedtabs, history, bookmarks, opentabs; extension sidebars go by
      # add-on id. Marking every selected extension as already installed stops
      # Firefox from appending its sidebar to the list on first install. Set as
      # policy user values: reapplied every startup, before add-ons load.
      programs.firefox.policies.Preferences = {
        "sidebar.main.tools" = lib.mkDefault { Value = "history"; Status = "user"; };
        "sidebar.installed.extensions" = lib.mkDefault {
          Value = lib.concatMapStringsSep "," (n: reg.${n}.id) (builtins.filter (n: reg ? ${n}) exts);
          Status = "user";
        };
      };
    })

    (lib.mkIf (config.programs.firefox.enable && walCssPaths != [ ]) {
      hydrix.graphical.firefox.package = lib.mkDefault
        (pkgs.firefox.override { extraPrefsFiles = [ walCssReload ]; });

      home-manager.users.${username} = {
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
