# Firefox Browser Configuration
#
# Home Manager module for Firefox.
# Policies and extensions installed via HM, colors via Stylix targets.
# Firefox is wrapped to auto-run pywalfox update on launch.
#
# Extension management:
# - All available extensions defined in `allExtensions` registry
# - Per-profile extension sets defined in `profileExtensions`
# - Extensions selected based on hydrix.vmType
# - Use `firefox-extension-add <slug>` to add new extensions

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;

  # Lock helpers for policies
  lock-false = {
    Value = false;
    Status = "locked";
  };
  lock-true = {
    Value = true;
    Status = "locked";
  };

  # Extension registry — defined in options.nix, extensible from hydrix-config
  allExtensions = ffCfg.extensionRegistry;
  currentExtensions = ffCfg.extensions;

  # Build ExtensionSettings from extension list
  buildExtensionSettings = extNames:
    builtins.listToAttrs (map (name:
      let ext = allExtensions.${name};
      in {
        name = ext.id;
        value = {
          install_url = ext.url;
          installation_mode = "force_installed";
        };
      }
    ) extNames);

  # Get font configuration from unified options
  fontCfg = config.hydrix.graphical.font;
  fontName = fontCfg.family;
  # Use override if set, otherwise scale base size by firefox relation
  fontSize = fontCfg.overrides.firefox or (builtins.floor (fontCfg.size * (fontCfg.relations.firefox or 1.5)));
  headerFontSize = fontCfg.overrides.firefoxHeader or (builtins.floor (fontCfg.size * 1.9));
  scalingFactor = config.hydrix.graphical.scaling.computed.factor;

  # DPI-aware Firefox launcher - reads scale factor from scaling.json at runtime
  # Similar to alacritty-dpi, this ensures Firefox uses the host's dynamic DPI
  # Parameterized so it can wrap any Firefox derivation (needed for HM .override support)
  mkFirefoxDpi = firefoxPkg: pkgs.writeShellScriptBin "firefox-dpi" ''
    SCALING_JSON="$HOME/.config/hydrix/scaling.json"
    SCALING_JSON_VM="/mnt/hydrix-config/scaling.json"
    FF_PROFILE="$HOME/.mozilla/firefox/default"
    FF_USER_JS="$FF_PROFILE/user.js"
    FF_DPI_MARKER="$FF_PROFILE/.dpi-scale"

    # Find scaling.json (host or VM mount)
    json_path=""
    if [ -f "$SCALING_JSON" ]; then
        json_path="$SCALING_JSON"
    elif [ -f "$SCALING_JSON_VM" ]; then
        json_path="$SCALING_JSON_VM"
    fi

    if [ -n "$json_path" ] && [ -d "$FF_PROFILE" ]; then
        # Priority: HYDRIX_FF_SCALE env (set by host when launching in VM) >
        #           HYPRLAND_INSTANCE_SIGNATURE (native Hyprland session) >
        #           scaling.json (X11/xrandr path)
        if [ -n "''${HYDRIX_FF_SCALE:-}" ]; then
            scale_factor="$HYDRIX_FF_SCALE"
        elif [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
            # Running directly under Hyprland — read scale from compositor
            scale_factor=$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null \
                | ${pkgs.jq}/bin/jq -r '[.[] | select(.focused)][0].scale // .[0].scale // 1.0' \
                2>/dev/null || echo "1.0")
        else
            # X11 or VM without HYDRIX_FF_SCALE — use scaling.json
            scale_factor=$(${pkgs.jq}/bin/jq -r '.scale_factor // 1.0' "$json_path" 2>/dev/null)
        fi

        # Check if scale factor changed (avoid unnecessary writes)
        current_scale=""
        [ -f "$FF_DPI_MARKER" ] && current_scale=$(cat "$FF_DPI_MARKER" 2>/dev/null)

        if [ "$scale_factor" != "$current_scale" ]; then
            # Handle Home Manager symlink: user.js may be a symlink to read-only Nix store
            if [ -L "$FF_USER_JS" ]; then
                # Copy contents and replace symlink with writable file
                symlink_target=$(readlink "$FF_USER_JS")
                rm "$FF_USER_JS"
                if [ -f "$symlink_target" ]; then
                    cp "$symlink_target" "$FF_USER_JS"
                    chmod u+w "$FF_USER_JS"
                else
                    touch "$FF_USER_JS"
                fi
            # Also fix permissions if file exists but is read-only
            elif [ -f "$FF_USER_JS" ] && [ ! -w "$FF_USER_JS" ]; then
                chmod u+w "$FF_USER_JS"
            fi

            # Update user.js with new scale factor
            # Remove any existing devPixelsPerPx line and append new one
            if [ -f "$FF_USER_JS" ]; then
                ${pkgs.gnused}/bin/sed -i '/layout\.css\.devPixelsPerPx/d' "$FF_USER_JS"
            fi
            echo "user_pref(\"layout.css.devPixelsPerPx\", \"$scale_factor\");" >> "$FF_USER_JS"
            echo "$scale_factor" > "$FF_DPI_MARKER"
        fi
    fi

    # Launch Firefox in background, then run pywalfox update in parallel
    ${firefoxPkg}/bin/firefox "$@" &
    FF_PID=$!

    # Wait for Firefox to be ready, then apply pywal colors
    if [ -f "$HOME/.cache/wal/colors.json" ]; then
      while kill -0 "$FF_PID" 2>/dev/null; do
        ${pkgs.pywalfox-native}/bin/pywalfox update 2>/dev/null && break
        sleep 1
      done
    fi

    wait "$FF_PID"
  '';

  firefoxDpi = mkFirefoxDpi pkgs.firefox;

  # Wrapped Firefox with DPI/pywalfox wrapper as the default firefox command
  # Supports .override for Home Manager compatibility (HM injects policies/PKCS11)
  mkFirefoxWrapped = firefoxPkg: let
    dpiWrapper = mkFirefoxDpi firefoxPkg;
    base = pkgs.symlinkJoin {
      name = "firefox-dpi";
      paths = [ firefoxPkg ];
      postBuild = ''
        rm $out/bin/firefox
        ln -s ${dpiWrapper}/bin/firefox-dpi $out/bin/firefox
      '';
    };
  in base // {
    override = f: mkFirefoxWrapped (firefoxPkg.override f);
  };

  firefoxWrapped = mkFirefoxWrapped pkgs.firefox;

  # Helper script to add new Firefox extensions from AMO
  # Usage: firefox-extension-add <slug>
  # The slug is the last part of the AMO URL: addons.mozilla.org/firefox/addon/<slug>
  firefoxExtensionAdd = pkgs.writeShellScriptBin "firefox-extension-add" ''
    set -euo pipefail

    FIREFOX_NIX="$HOME/hydrix-config/shared/firefox.nix"

    usage() {
      echo "Usage: firefox-extension-add <slug> [profile1,profile2,...]"
      echo ""
      echo "Fetch extension info from AMO and output Nix entry for firefox.nix"
      echo ""
      echo "Arguments:"
      echo "  slug      The addon slug from AMO URL (e.g., 'darkreader' from"
      echo "            https://addons.mozilla.org/firefox/addon/darkreader/)"
      echo "  profiles  Optional: comma-separated profiles to add to"
      echo "            (pentest, browsing, comms, dev, lurking, host)"
      echo ""
      echo "Examples:"
      echo "  firefox-extension-add darkreader"
      echo "  firefox-extension-add privacy-badger browsing,comms"
      echo ""
      echo "The command outputs the Nix entry to add to firefox.extensionRegistry in:"
      echo "  $FIREFOX_NIX"
      exit 1
    }

    if [ $# -lt 1 ]; then
      usage
    fi

    SLUG="$1"
    PROFILES="''${2:-}"

    echo "Fetching extension info for: $SLUG"
    echo ""

    # Fetch from AMO API
    API_URL="https://addons.mozilla.org/api/v5/addons/addon/$SLUG/"
    RESPONSE=$(${pkgs.curl}/bin/curl -s "$API_URL")

    # Check if addon exists
    if echo "$RESPONSE" | ${pkgs.jq}/bin/jq -e '.detail' >/dev/null 2>&1; then
      echo "Error: Addon '$SLUG' not found on AMO"
      exit 1
    fi

    # Extract info
    NAME=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.name."en-US" // .name | if type == "object" then .[] else . end')
    GUID=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.guid')
    SUMMARY=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.summary."en-US" // .summary | if type == "object" then .[] else . end' | head -c 60)

    # Normalize slug for Nix attribute name (replace special chars with dashes)
    NIX_NAME=$(echo "$SLUG" | ${pkgs.gnused}/bin/sed 's/[^a-zA-Z0-9]/-/g' | ${pkgs.gnused}/bin/sed 's/--*/-/g' | ${pkgs.gnused}/bin/sed 's/^-//;s/-$//')

    echo "Extension found:"
    echo "  Name: $NAME"
    echo "  ID:   $GUID"
    echo "  Desc: $SUMMARY..."
    echo ""
    echo "Add this to firefox.extensionRegistry in $FIREFOX_NIX:"
    echo ""
    echo "    $NIX_NAME = {"
    echo "      id = \"$GUID\";"
    echo "      url = \"https://addons.mozilla.org/firefox/downloads/latest/$SLUG/latest.xpi\";"
    echo "      description = \"$SUMMARY\";"
    echo "    };"
    echo ""

    if [ -n "$PROFILES" ]; then
      echo "Then add \"$NIX_NAME\" to these profile lists:"
      IFS=',' read -ra PROFILE_ARRAY <<< "$PROFILES"
      for profile in "''${PROFILE_ARRAY[@]}"; do
        echo "  - $profile"
      done
    else
      echo "Then add \"$NIX_NAME\" to the desired profile extension lists."
    fi
    echo ""
    echo "After editing, rebuild the affected VMs:"
    echo "  microvm build microvm-<profile>"
  '';

  # User-agent presets — named shortcuts to realistic UA strings
  uaPresets = {
    edge-windows    = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0";
    chrome-windows  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    chrome-mac      = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
    safari-mac      = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_2_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15";
    firefox-windows = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0";
  };

  ffCfg = config.hydrix.graphical.firefox;

  uaRaw = ffCfg.userAgent;
  resolvedUA = if uaRaw == null then null else uaPresets.${uaRaw} or uaRaw;

  # On hosts, Firefox is only included when hostEnable is true.
  # VMs always get Firefox when graphical is enabled.
  isHost = vmType == "host" || vmType == null;
  firefoxEnabled = config.hydrix.graphical.enable
    && (!isHost || ffCfg.hostEnable);

in {
  config = lib.mkIf firefoxEnabled {
    # System-level Firefox with policies (works better than HM for policies)
    programs.firefox = {
      enable = true;
      languagePacks = [ "en-US" ];

      policies = {
        DisableTelemetry = true;
        DisableFirefoxStudies = true;
        EnableTrackingProtection = {
          Value = true;
          Locked = true;
          Cryptomining = true;
          Fingerprinting = true;
        };
        DisablePocket = true;
        DisableFirefoxAccounts = true;
        DisableAccounts = true;
        DisableFirefoxScreenshots = true;
        OverrideFirstRunPage = "";
        OverridePostUpdatePage = "";
        DontCheckDefaultBrowser = true;
        DisplayBookmarksToolbar = "never";
        DisplayMenuBar = "default-off";
        SearchBar = "unified";

        # Force-install extensions based on profile
        # Extensions defined in allExtensions registry, selected per vmType
        ExtensionSettings = buildExtensionSettings currentExtensions;

        # Locked preferences
        Preferences = {
          "browser.contentblocking.category" = { Value = "strict"; Status = "locked"; };
          "extensions.pocket.enabled" = lock-false;
          "extensions.screenshots.disabled" = lock-true;
          # Suppress extension popups and welcome pages
          "extensions.getAddons.showPane" = { Value = false; Status = "default"; };
          "extensions.htmlaboutaddons.recommendations.enabled" = { Value = false; Status = "default"; };
          "browser.messaging-system.whatsNewPanel.enabled" = lock-false;
          "browser.uitour.enabled" = lock-false;
          "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons" = lock-false;
          "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features" = lock-false;
          # Prevent extension update notifications
          "extensions.update.notifyUser" = lock-false;
          "browser.topsites.contile.enabled" = lock-false;
          "browser.formfill.enable" = lock-false;
          "browser.search.suggest.enabled" = lock-false;
          "browser.search.suggest.enabled.private" = lock-false;
          "browser.urlbar.suggest.searches" = lock-false;
          "browser.urlbar.showSearchSuggestionsFirst" = lock-false;
          "browser.newtabpage.activity-stream.feeds.section.topstories" = lock-false;
          "browser.newtabpage.activity-stream.feeds.snippets" = lock-false;
          "browser.newtabpage.activity-stream.section.highlights.includePocket" = lock-false;
          "browser.newtabpage.activity-stream.section.highlights.includeBookmarks" = lock-false;
          "browser.newtabpage.activity-stream.section.highlights.includeDownloads" = lock-false;
          "browser.newtabpage.activity-stream.section.highlights.includeVisited" = lock-false;
          "browser.newtabpage.activity-stream.showSponsored" = lock-false;
          "browser.newtabpage.activity-stream.system.showSponsored" = lock-false;
          "browser.newtabpage.activity-stream.showSponsoredTopSites" = lock-false;
        } // lib.optionalAttrs ffCfg.verticalTabs {
          "sidebar.revamp" = lock-true;
          "sidebar.verticalTabs" = lock-true;
          "sidebar.visibility" = { Value = "hide-sidebar"; Status = "locked"; };
          "sidebar.position_start" = lock-true;
        } // lib.optionalAttrs (resolvedUA != null) {
          "general.useragent.override" = { Value = resolvedUA; Status = "locked"; };
        };
      };
    };

    # Home Manager Firefox profile configuration
    home-manager.users.${username} = { pkgs, config, ... }: {
      programs.firefox = {
        enable = true;
        package = firefoxWrapped;  # Use DPI/pywalfox wrapper instead of raw firefox

        profiles.default = {
          id = 0;
          name = "default";
          isDefault = true;

          search = {
            default = ffCfg.search.default;
          };

          settings = {
            # Enable userChrome.css
            "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

            # Privacy
            "privacy.trackingprotection.enabled" = true;
            "privacy.donottrackheader.enabled" = true;

            # Disable various telemetry
            "datareporting.healthreport.uploadEnabled" = false;
            "toolkit.telemetry.enabled" = false;
            "toolkit.telemetry.unified" = false;

            # UI customization
            "browser.uidensity" = ffCfg.uidensity;
            # Dark base theme so startup flash is dark (pywalfox overrides dynamically)
            "extensions.activeThemeID" = "firefox-compact-dark@mozilla.org";
            "browser.tabs.inTitlebar" = 1;

            # Ctrl+Tab cycles through tabs in recently used order
            "browser.ctrlTab.recentlyUsedOrder" = true;

            # Suppress extension welcome pages and popups
            "extensions.webextensions.restrictedDomains" = "";
            "browser.messaging-system.whatsNewPanel.enabled" = false;
            "browser.uitour.enabled" = false;
            "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons" = false;
            "browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features" = false;

            # Font/UI scaling for HiDPI displays
            # NOTE: layout.css.devPixelsPerPx is managed dynamically by firefox-dpi wrapper
            # It reads scale_factor from ~/.config/hydrix/scaling.json at runtime

            # Force system font on web content
            "browser.display.use_document_fonts" = 0;  # 0 = use user fonts, 1 = allow web fonts
            "font.name.monospace.x-western" = lib.mkForce fontName;
            "font.name.sans-serif.x-western" = lib.mkForce fontName;
            "font.name.serif.x-western" = lib.mkForce fontName;
            "font.size.variable.x-western" = lib.mkForce fontSize;
            "font.size.monospace.x-western" = lib.mkForce fontSize;
          } // lib.optionalAttrs ffCfg.verticalTabs {
            # Native Vertical Tabs - start collapsed, expand on hover
            "sidebar.revamp" = true;
            "sidebar.verticalTabs" = true;
            "sidebar.expandOnHover" = true;
            "sidebar.visibility" = "hide-sidebar";  # Start collapsed
            "sidebar.position_start" = true;  # Sidebar on left
          };

          # Custom CSS for Firefox UI
          userChrome = ''
            /* Firefox UI styling with system font */

            /* Apply system font to all UI elements */
            * {
              font-family: "${fontName}", monospace !important;
            }

            /* Tab bar */
            .tabbrowser-tab {
              min-height: 28px !important;
              font-size: ${toString fontSize}px !important;
            }

            /* URL bar */
            #urlbar {
              font-family: "${fontName}", monospace !important;
              font-size: ${toString fontSize}px !important;
            }

            #urlbar-input {
              font-family: "${fontName}", monospace !important;
              font-size: ${toString fontSize}px !important;
            }

            /* Navigation bar */
            #nav-bar {
              padding: 0 !important;
              font-size: ${toString fontSize}px !important;
            }

            /* Bookmarks bar */
            #PlacesToolbarItems {
              font-size: ${toString fontSize}px !important;
            }

            /* Menu items */
            menuitem, menu {
              font-size: ${toString fontSize}px !important;
            }

            /* Sidebar */
            #sidebar-box {
              font-size: ${toString fontSize}px !important;
            }

            ${lib.optionalString ffCfg.verticalTabs ''
            /* Hide horizontal tabs for Vertical Tabs mode */
            #TabsToolbar {
              visibility: collapse !important;
            }

            /* Collapse vertical tabs sidebar to icon strip, expand on hover */
            #sidebar-main {
              min-width: 0px !important;
              max-width: 40px !important;
              overflow: hidden !important;
              transition: max-width 0.2s ease !important;
            }
            #sidebar-main:hover {
              max-width: 300px !important;
            }
            ''}
          '';

          userContent = ''
            /* Content styling with system font */

            /* Force system font on ALL web content */
            @-moz-document regexp(".*") {
              * {
                font-family: "${fontName}", monospace !important;
              }
            }

            /* Apply to internal pages (about:*, etc.) */
            @-moz-document url-prefix("about:") {
              body {
                font-size: ${toString fontSize}px !important;
              }
              h1, h2, h3 {
                font-size: ${toString headerFontSize}px !important;
              }
            }
          '';
        };
      };
    };

    # Pywalfox native messaging host installation
    systemd.services.pywalfox-install = {
      description = "Install pywalfox native messaging host";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      unitConfig = {
        ConditionPathExists = "!/home/${username}/.mozilla/native-messaging-hosts/pywalfox.json";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = username;
      };

      script = ''
        ${pkgs.pywalfox-native}/bin/pywalfox install --browser firefox
      '';
    };

    # Pre-clean Firefox search config to prevent HM failures
    # Firefox sometimes recreates search.json.mozlz4 as a real file, blocking HM activation
    systemd.services."home-manager-${username}".preStart = lib.mkAfter ''
      # Backup Firefox search.json.mozlz4 if it's not a symlink
      FF_DIR="/home/${username}/.mozilla/firefox/default"
      if [ -f "$FF_DIR/search.json.mozlz4" ] && [ ! -L "$FF_DIR/search.json.mozlz4" ]; then
        echo "Backing up conflicting Firefox search configuration..."
        mv "$FF_DIR/search.json.mozlz4" "$FF_DIR/search.json.mozlz4.backup-$(date +%s)"
      fi
    '';

    # Add wrapped Firefox with higher priority so it takes precedence
    # This ensures pywalfox update runs automatically on every Firefox launch
    environment.systemPackages = [
      (lib.hiPrio firefoxWrapped)
      firefoxExtensionAdd
    ];
  };
}
