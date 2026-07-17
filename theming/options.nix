# Hydrix Theming Options
#
# Graphical environment, window managers (i3, Hyprland, Sway), fonts, scaling.
# Imported for any system with a graphical environment.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix;
in {
  options.hydrix.graphical = {
    enable = lib.mkEnableOption "Hydrix graphical environment";

    walrgbExtraCommands = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra shell commands appended to walrgb after the core theming steps.
        Runs as arbitrary bash after wal has populated ~/.cache/wal/.

        Available variables:
          HEX_CODE   — accent color (color2 from wal palette), no leading #
          file_path  — path to the wallpaper that was applied

        Full wal palette (all 16 colors, background, foreground, special colors)
        is accessible at ~/.cache/wal/colors.json. Use jq to extract any entry
        and convert to any format your program needs — RGB, HSL, decimal, etc.

        Example — OpenRGB keyboard with a specific palette color:
          hydrix.graphical.walrgbExtraCommands = '''
            COLOR=$(jq -r '.colors.color4' ~/.cache/wal/colors.json | sed 's/#//')
            if command -v openrgb >/dev/null 2>&1; then
              openrgb --device 0 --mode static --color "$COLOR"
            fi
          ''';

        Example — convert to decimal RGB for a custom tool:
          hydrix.graphical.walrgbExtraCommands = '''
            C=$(jq -r '.colors.color2' ~/.cache/wal/colors.json | sed 's/#//')
            R=$((16#''${C:0:2})); G=$((16#''${C:2:2})); B=$((16#''${C:4:2}))
            my-rgb-tool --color "$R,$G,$B"
          ''';
      '';
    };

    firefox.hostEnable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install Firefox on the host system. Default false since browsing
        typically happens inside VMs. Set to true in administrative mode
        or wherever host-level Firefox is needed.
      '';
    };

    firefox.userAgent = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Firefox user-agent string, set as a locked policy preference.
        Accepts a named preset or a raw UA string. null = Firefox real UA.
        Presets: "edge-windows", "chrome-windows", "chrome-mac",
                 "safari-mac", "firefox-windows"
      '';
      example = "edge-windows";
    };

    firefox.extensionRegistry = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          id          = lib.mkOption { type = lib.types.str; };
          url         = lib.mkOption { type = lib.types.str; };
          description = lib.mkOption { type = lib.types.str; default = ""; };
        };
      });
      default = {
        ublock-origin = {
          id = "uBlock0@raymondhill.net";
          url = "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi";
          description = "Ad and tracker blocking";
        };
        pywalfox = {
          id = "pywalfox@frewacom.org";
          url = "https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi";
          description = "Colorscheme sync with pywal";
        };
        vimium-ff = {
          id = "{d7742d87-e61d-4b78-b8a1-b469842139fa}";
          url = "https://addons.mozilla.org/firefox/downloads/latest/vimium-ff/latest.xpi";
          description = "Vim-like keyboard navigation";
        };
        detach-tab = {
          id = "claymont@mail.com_detach-tab";
          url = "https://addons.mozilla.org/firefox/downloads/latest/detach-tab/latest.xpi";
          description = "Detach tabs to new windows";
        };
        bitwarden = {
          id = "{446900e4-71c2-419f-a6a7-df9c091e268b}";
          url = "https://addons.mozilla.org/firefox/downloads/latest/bitwarden-password-manager/latest.xpi";
          description = "Password manager";
        };
        foxyproxy = {
          id = "foxyproxy@eric.h.jung";
          url = "https://addons.mozilla.org/firefox/downloads/latest/foxyproxy-standard/latest.xpi";
          description = "Proxy management for pentesting";
        };
        wappalyzer = {
          id = "wappalyzer@crunchlabz.com";
          url = "https://addons.mozilla.org/firefox/downloads/latest/wappalyzer/latest.xpi";
          description = "Technology stack detection";
        };
        singlefile = {
          id = "{531906d3-e22f-4a6c-a102-8057b88a1a63}";
          url = "https://addons.mozilla.org/firefox/downloads/latest/single-file/latest.xpi";
          description = "Save complete web pages";
        };
        darkreader = {
          id = "addon@darkreader.org";
          url = "https://addons.mozilla.org/firefox/downloads/latest/darkreader/latest.xpi";
          description = "Dark mode for all websites";
        };
        styl-us = {
          id = "{7a7a4a92-a2a0-41d1-9fd7-1e92480d612d}";
          url = "https://addons.mozilla.org/firefox/downloads/latest/styl-us/latest.xpi";
          description = "User styles manager for custom website themes";
        };
      };
      description = ''
        Registry of available Firefox extensions. Merge additional entries here
        in hydrix-config/shared/firefox.nix to make custom extensions available
        for selection via firefox.extensions.
      '';
    };

    firefox.extensions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Firefox extensions to force-install, by name from firefox.extensionRegistry.
        Set per-profile in profiles/<name>/default.nix.
      '';
      example = ["ublock-origin" "pywalfox" "bitwarden" "darkreader"];
    };

    firefox.search.default = lib.mkOption {
      type = lib.types.str;
      default = "ddg";
      description = "Default search engine for Firefox. Use the engine short name (ddg, google, etc.).";
    };

    firefox.verticalTabs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable vertical tabs sidebar. The horizontal tab bar is hidden and the
        sidebar collapses to an icon strip, expanding on hover.
      '';
    };

    firefox.uidensity = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Firefox UI density: 0 = normal, 1 = compact, 2 = touch.";
    };

    firefox.homepage = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        URL to use as Firefox's startup homepage. null = Firefox default (about:home).
        Applied as browser.startup.homepage with startup page set to show homepage.
      '';
      example = "https://example.com";
    };

    firefox.newTab = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Controls the new tab page. null = Firefox default (activity stream).
        Set to "about:blank" for a blank new tab, or any URL to open that page
        on new tabs (requires the New Tab Override extension for custom URLs).
      '';
      example = "about:blank";
    };

    zathura.recolor = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable document recoloring (dark mode).";
    };

    zathura.recolorReverseVideo = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Recolor images that use reverse video.";
    };

    zathura.recolorKeepHue = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Preserve original hue when recoloring.";
    };

    zathura.selectionClipboard = lib.mkOption {
      type = lib.types.str;
      default = "clipboard";
      description = "Clipboard target for text selection: clipboard or primary.";
    };

    zathura.scrollPageAware = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Stop scrolling at page boundaries.";
    };

    zathura.scrollFullOverlap = lib.mkOption {
      type = lib.types.str;
      default = "0.01";
      description = "Overlap fraction kept visible when scrolling a full page.";
    };

    zathura.scrollStep = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Scroll step size in pixels.";
    };

    zathura.zoomMin = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Minimum zoom level (percent).";
    };

    zathura.zoomMax = lib.mkOption {
      type = lib.types.int;
      default = 400;
      description = "Maximum zoom level (percent).";
    };

    zathura.zoomStep = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Zoom step size (percent).";
    };

    zathura.incrementalSearch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Highlight matches while typing the search query.";
    };

    zathura.sandbox = lib.mkOption {
      type = lib.types.str;
      default = "none";
      description = "Sandbox level: none, normal, or strict.";
    };

    zathura.mappings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        D = "toggle_page_mode";
        r = "reload";
        R = "rotate";
        K = "zoom in";
        J = "zoom out";
        i = "recolor";
        p = "print";
      };
      description = "Key mappings — attrset of key → command.";
    };

    zathura.extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional lines appended to zathurarc verbatim.";
    };

    alacritty.cursor.shape = lib.mkOption {
      type = lib.types.str;
      default = "Underline";
      description = "Cursor shape: Block, Underline, or Beam.";
    };

    alacritty.cursor.blinking = lib.mkOption {
      type = lib.types.str;
      default = "Always";
      description = "Cursor blinking mode: Never, Off, On, Always.";
    };

    alacritty.cursor.thickness = lib.mkOption {
      type = lib.types.float;
      default = 0.35;
      description = "Cursor thickness (0.0–1.0). Applies to Underline and Beam styles.";
    };

    alacritty.cursor.unfocusedHollow = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Show a hollow cursor when the window is unfocused.";
    };

    alacritty.cursor.blinkTimeout = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Seconds of inactivity after which blinking stops. 0 = never stop.";
    };

    alacritty.cursor.blinkInterval = lib.mkOption {
      type = lib.types.int;
      default = 500;
      description = "Cursor blink interval in milliseconds.";
    };

    alacritty.selection.saveToClipboard = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Copy selected text to the system clipboard automatically.";
    };

    ranger.extraMappings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Extra ranger key mappings merged on top of the framework defaults.
        Use this to add or override individual bindings from hydrix-config.
        Example: hydrix.graphical.ranger.extraMappings = { gm = "cd ~/Music"; };
      '';
    };

    ranger.extraRifle = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          condition = lib.mkOption { type = lib.types.str; };
          command   = lib.mkOption { type = lib.types.str; };
        };
      });
      default = [];
      description = ''
        Extra rifle file-handler rules appended after the framework defaults.
        Use this to add handlers for file types not covered by the defaults.
        Example:
          hydrix.graphical.ranger.extraRifle = [
            { condition = "ext epub, has foliate, X, flag f"; command = "foliate -- \"$@\""; }
          ];
      '';
    };

    fish.viKeyBindings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable vi key bindings in fish shell.";
    };

    obsidian.hostEnable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install Obsidian on the host system. Default false to keep the
        lockdown closure small. Set to true in administrative mode.
      '';
    };

    obsidian.vaultPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Paths to Obsidian vault directories (relative to home, e.g. "hack_the_world").
        CSS snippets and appearance settings are deployed to each vault's .obsidian/ dir.
      '';
      example = ["hack_the_world" "notes"];
    };

    standalone = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable standalone graphical environment for libvirt VMs.
        When true, the VM gets a full i3/polybar environment for use with
        virt-manager or similar. When false (default), apps are forwarded
        to the host via xpra (headless mode).
      '';
    };

    # Theme
    colorscheme = lib.mkOption {
      type = lib.types.str;
      default = cfg.colorscheme;
      description = "Graphical colorscheme (defaults to hydrix.colorscheme)";
    };

    wallpaper = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Wallpaper image path";
    };

    polarity = lib.mkOption {
      type = lib.types.enum ["dark" "light"];
      default = "dark";
      description = "Color scheme polarity";
    };

    # Font
    font = {
      family = lib.mkOption {
        type = lib.types.str;
        default = "Iosevka";
        description = "System font family";
      };

      size = lib.mkOption {
        type = lib.types.number;
        default = 10;
        description = "Base font size at 96 DPI. Supports decimals (e.g., 10.5).";
      };

      relations = lib.mkOption {
        type = lib.types.attrsOf lib.types.float;
        default = {
          alacritty = 1.0;
          polybar = 1.0;
          rofi = 1.0;
          dunst = 1.0;
          firefox = 1.2;
          gtk = 1.0;
        };
        description = ''
          Per-app font size multipliers. Final size = base × scale_factor × relation.
          Used when external monitor is connected.
        '';
      };

      # Standalone-specific relations (override when no external monitor)
      standaloneRelations = lib.mkOption {
        type = lib.types.attrsOf lib.types.float;
        default = {};
        example = {alacritty = 1.05;};
        description = ''
          Per-app font size multipliers for standalone mode (no external monitor).
          Apps not listed here fall back to the regular 'relations' values.
          Set in machines/<serial>.nix for machine-specific tuning.
        '';
      };

      familySizes = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = {};
        description = "Base size per font family (profiles set defaults via mkDefault)";
      };

      overrides = lib.mkOption {
        type = lib.types.attrsOf lib.types.number;
        default = {};
        example = {alacritty = 10.5;};
        description = ''
          Direct font size overrides per app. Bypasses DPI scaling and relations.
          Supports decimals for apps like alacritty that use 0.5 increments.
        '';
      };

      maxSizes = lib.mkOption {
        type = lib.types.attrsOf lib.types.number;
        default = {};
        example = {
          alacritty = 10.5;
          polybar = 13;
        };
        description = ''
          Per-app maximum font size caps. Calculated sizes are clamped
          to these values after DPI scaling. Useful for bitmap fonts
          that only render well up to specific sizes.
        '';
      };

      familyOverrides = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Font family overrides per app";
      };

      polybarFontFlags = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Extra XFT font flags appended after the font name in polybar font declarations.
          Used by font profiles to encode rendering requirements (e.g. Tamzen needs
          ":fontformat=truetype:antialias=false"). Empty string for smooth fonts like Iosevka.
        '';
      };

      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Font packages to install on the host graphical environment";
      };

      packageMap = lib.mkOption {
        type = lib.types.attrsOf lib.types.package;
        default = {};
        description = "Map font family names to nix packages (used by Stylix)";
      };

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Additional font packages always installed (emoji, serif fallbacks)";
      };

      vmPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Font packages to install in microVMs";
      };

      profileMap = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Map font family names to profile names for auto-detection";
      };
    };

    # Keyboard
    keyboard = {
      xmodmap = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Freeform Xmodmap content. When non-empty, deployed as ~/.Xmodmap.
          Used for key remapping (e.g., CapsLock to Ctrl).
        '';
        example = ''
          clear lock
          clear control
          keycode 66 = Control_L
          add control = Control_L Control_R
        '';
      };

      layout = lib.mkOption {
        type = lib.types.str;
        default = "us";
        description = "XKB keyboard layout for Wayland compositors (Hyprland, Sway). E.g. 'us', 'se', 'de'.";
        example = "se";
      };

      variant = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "XKB keyboard variant. Leave empty for the default variant.";
        example = "dvorak";
      };

      xkbOptions = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "XKB options string for Wayland compositors (e.g. 'caps:ctrl_modifier'). Comma-separated.";
        example = "caps:ctrl_modifier";
      };

      xkbFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Custom XKB keymap file for Wayland compositors. When set, takes precedence
          over layout, variant, and xkbOptions. Use pkgs.writeText to generate from
          inline content in your machine config:

            hydrix.graphical.keyboard.xkbFile = pkgs.writeText "my-keymap" '''
              xkb_keymap { xkb_symbols { include "pc+se+inet(evdev)" ... }; };
            ''';
        '';
      };

    };

    # UI
    ui = {
      gaps = lib.mkOption {
        type = lib.types.int;
        default = 15;
        description = "i3 inner gaps";
      };

      gapsStandaloneRelation = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Gap multiplier in standalone mode";
      };

      border = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Window border width";
      };

      pillRadius = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Border radius for waybar island pills (px). null = derive from cornerRadius * pillRadiusScale";
      };

      pillRadiusScale = lib.mkOption {
        type = lib.types.float;
        default = 2.0;
        description = "Multiplier applied to cornerRadius to get waybar pill radius when pillRadius is null";
      };

      barHeight = lib.mkOption {
        type = lib.types.int;
        default = 23;
        description = "Polybar height";
      };

      barHeightRelation = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Polybar height multiplier";
      };

      barHeightFamilyRelations = lib.mkOption {
        type = lib.types.attrsOf lib.types.float;
        default = {};
        description = "Per-font bar height multipliers (profiles set defaults via mkDefault)";
      };

      polybarFontOffset = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Polybar font vertical offset (adjusts text centering in bar)";
      };

      barPadding = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Polybar internal padding";
      };

      barGaps = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Polybar floating margins (null = gaps/2)";
      };

      barEdgeGapsFactor = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Factor for bar-to-screen-edge gaps (0.0-1.0)";
      };

      outerGapsMatchBar = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "i3 outer gaps match barGaps";
      };

      floatingBar = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable floating polybar";
      };

      bottomBar = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable bottom polybar with VM metrics";
      };

      polybarStyle = lib.mkOption {
        type = lib.types.enum ["unibar" "modular" "pills"];
        default = "modular";
        description = "Polybar visual style";
      };

      padding = lib.mkOption {
        type = lib.types.int;
        default = 8;
        description = "General padding";
      };

      paddingSmall = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Small padding";
      };

      cornerRadius = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Picom corner radius";
      };

      workspaceLabels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "1" = "I";
          "2" = "II";
          "3" = "III";
          "4" = "IV";
          "5" = "V";
          "6" = "VI";
          "7" = "VII";
          "8" = "VIII";
          "9" = "IX";
          "10" = "X";
        };
        description = "Workspace display labels";
      };

      workspaceDescriptions = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Per-workspace descriptions";
      };

      shadowRadius = lib.mkOption {
        type = lib.types.int;
        default = 18;
        description = "Picom shadow radius";
      };

      shadowOffset = lib.mkOption {
        type = lib.types.int;
        default = 17;
        description = "Picom shadow offset";
      };

      opacity = {
        active = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
          description = "Active window opacity (1.0 = no transparency)";
        };

        inactive = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
          description = "Inactive window opacity (1.0 = no transparency)";
        };

        exclude = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["Alacritty" "feh" "Feh" "firefox" "Firefox" "mpv" "vlc"];
          description = "Windows excluded from opacity rules";
        };

        alacritty = lib.mkOption {
          type = lib.types.float;
          default = 0.85;
          description = "Alacritty terminal opacity (deprecated: use overlay)";
        };

        overlay = lib.mkOption {
          type = lib.types.float;
          default = 0.85;
          description = "Unified opacity for transparent UI elements (terminals, overlays)";
        };

        overlayOverrides = lib.mkOption {
          type = lib.types.attrsOf lib.types.float;
          default = {alacritty = 0.95;};
          description = "Per-app overrides for overlay opacity";
        };

        rules = lib.mkOption {
          type = lib.types.attrsOf lib.types.int;
          default = {"Polybar" = 95;};
          description = "Custom opacity rules per window class";
        };
      };

      rofiWidth = lib.mkOption {
        type = lib.types.int;
        default = 800;
        description = "Rofi window width";
      };

      rofiHeight = lib.mkOption {
        type = lib.types.int;
        default = 400;
        description = "Rofi window height";
      };

      dunstWidth = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Dunst notification width";
      };

      dunstOffset = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Dunst offset from screen edge";
      };

      dunstEnablePopup = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable dunst notification popups (set false to use polybar module only)";
      };

      dunstSound = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Notification sound for dunst. Set to a sound file path (e.g., "bell.wav") to enable.
          Empty string or null disables sound.
        '';
        example = "bell.wav";
      };

      dunstBrowser = lib.mkOption {
        type = lib.types.str;
        default = "firefox";
        description = "Browser command dunst uses to open URLs from notifications.";
      };

      dunstUrgencyTimeout = {
        low = lib.mkOption {
          type = lib.types.int;
          default = 5;
          description = "Seconds before low-urgency notifications expire. 0 = never.";
        };
        normal = lib.mkOption {
          type = lib.types.int;
          default = 10;
          description = "Seconds before normal-urgency notifications expire. 0 = never.";
        };
        critical = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "Seconds before critical-urgency notifications expire. 0 = never.";
        };
      };

      # Compositor settings
      compositor = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable compositor (picom) for shadows, rounded corners, and animations.";
        };

        animations = lib.mkOption {
          type = lib.types.enum ["none" "modern"];
          default = "modern";
          description = ''
            Picom animation mode:
            - none: Standard picom with fading only (xrender, no blur)
            - modern: Picom v12 with bouncy animations (xrender, overshoot curves)
          '';
        };
      };

      # Bar module layout overrides
      bar = {
        top = {
          left = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Top bar left modules. null = style default (workspaces + focus).";
            example = "xworkspaces focus-dynamic";
          };
          center = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Top bar center modules. null = style default (empty).";
          };
          right = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Top bar right modules. null = style default (metrics + date).";
            example = "volume-dynamic cpu-dynamic date-dynamic";
          };
        };
        bottom = {
          left = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Bottom bar left modules. null = style default (power + battery + host metrics).";
          };
          center = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Bottom bar center modules. null = style default (empty).";
          };
          right = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Bottom bar right modules. null = style default (VM metrics).";
          };
        };
      };
    };

    # Blue light filter (blugon)
    bluelight = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable blue light filter (blugon) for reducing eye strain";
      };

      defaultTemp = lib.mkOption {
        type = lib.types.int;
        default = 4500;
        description = ''
          Default color temperature in Kelvin.
          Lower = warmer (more red), higher = cooler (more blue).
          Typical range: 2500K (very warm) to 6500K (daylight).
        '';
      };

      minTemp = lib.mkOption {
        type = lib.types.int;
        default = 2500;
        description = "Minimum temperature (warmest/most red).";
      };

      maxTemp = lib.mkOption {
        type = lib.types.int;
        default = 6500;
        description = "Maximum temperature (coolest/most blue).";
      };

      step = lib.mkOption {
        type = lib.types.int;
        default = 200;
        description = "Temperature adjustment step for keybindings/clicks.";
      };

      autoRestart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically restart blugon service on failure. When false, blugon only starts on boot.";
      };

      # Time-based schedule for auto mode
      schedule = {
        dayTemp = lib.mkOption {
          type = lib.types.int;
          default = 6500;
          description = "Color temperature during daytime (cooler/bluer).";
        };

        nightTemp = lib.mkOption {
          type = lib.types.int;
          default = 3500;
          description = "Color temperature at night (warmer/redder).";
        };

        dayStart = lib.mkOption {
          type = lib.types.int;
          default = 7;
          description = "Hour when daytime begins (0-23).";
        };

        nightStart = lib.mkOption {
          type = lib.types.int;
          default = 20;
          description = "Hour when nighttime begins (0-23).";
        };
      };
    };

    # Scaling
    scaling = {
      auto = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable automatic DPI detection";
      };

      applyOnLogin = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Apply xrandr changes on login";
      };

      referenceDpi = lib.mkOption {
        type = lib.types.int;
        default = 96;
        description = "Reference DPI for base values";
      };

      internalResolution = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "1920x1200";
        description = "Preferred internal display resolution (i3/xrandr)";
      };

      swayInternalOutput = lib.mkOption {
        type = lib.types.str;
        default = "eDP-1";
        description = "Name of the internal display output in sway (from `swaymsg -t get_outputs`).";
      };

      swayInternalScale = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        example = 1.25;
        description = ''
          Scale factor for the internal display only (does not affect external monitors).
          Wayland equivalent of internalResolution. Higher values → fewer logical pixels.
          1.25 on 1920×1200 → 1536×960 logical. 1.5 → 1280×800 logical.
          Takes priority over swayInternalMode when both are set.
        '';
      };

      swayInternalMode = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "1280x800";
        description = ''
          Hardware resolution mode for the internal display only (does not affect external monitors).
          Sets the actual pixel mode via `output <name> mode <WxH>`.
          The display must support the requested mode.
        '';
      };

      hyprInternalOutput = lib.mkOption {
        type = lib.types.str;
        default = "eDP-1";
        description = "Name of the internal display output in Hyprland (from `hyprctl monitors`).";
      };

      hyprInternalScale = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        example = 1.25;
        description = ''
          Scale factor for the internal display under Hyprland.
          Higher values → fewer logical pixels; everything appears larger.
          1.25 on 1920×1200 → 1536×960 logical. 1.5 → 1280×800 logical.
          Only the named output (hyprInternalOutput) is affected; external
          monitors fall back to scale 1 via the catch-all monitor rule.
        '';
      };

      standaloneScaleFactor = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Scale multiplier for standalone mode";
      };
    };

    # VM Bar (bottom bar with resource metrics inside VMs)
    vmBar = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable bottom polybar inside VMs showing resource usage";
      };

      position = lib.mkOption {
        type = lib.types.enum ["bottom"];
        default = "bottom";
        description = "Position of the VM resource bar";
      };
    };

    # Lockscreen
    lockscreen = {
      idleTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = 300;
        description = "Seconds before auto-lock (null to disable)";
      };

      font = lib.mkOption {
        type = lib.types.str;
        default = "CozetteVector";
        description = "Lockscreen font (defaults to CozetteVector for crisp text on blurred backgrounds)";
      };

      fontSize = lib.mkOption {
        type = lib.types.int;
        default = 143;
        description = "Lockscreen main text size";
      };

      clockSize = lib.mkOption {
        type = lib.types.int;
        default = 104;
        description = "Lockscreen clock size";
      };

      text = lib.mkOption {
        type = lib.types.str;
        default = "Locked";
        description = "Lockscreen prompt text";
      };

      wrongText = lib.mkOption {
        type = lib.types.str;
        default = "Wrong password";
        description = "Wrong password text";
      };

      verifyText = lib.mkOption {
        type = lib.types.str;
        default = "Verifying...";
        description = "Verification text";
      };

      blur = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Apply blur effect";
      };
    };

    # Splash
    splash = {
      enable = lib.mkEnableOption "splash screen during startup";

      title = lib.mkOption {
        type = lib.types.str;
        default = "HYDRIX";
        description = "Splash title";
      };

      text = lib.mkOption {
        type = lib.types.str;
        default = "initializing...";
        description = "Splash subtitle";
      };

      maxTimeout = lib.mkOption {
        type = lib.types.int;
        default = 15;
        description = "Safety timeout in seconds";
      };

      font = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Splash font (null = CozetteVector)";
      };
    };
  };

  # =========================================================================
  # WINDOW MANAGER OPTIONS
  # =========================================================================

  options.hydrix.i3 = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the i3/X11 window manager stack.
        Activates: i3, polybar, rofi, picom, xsession, display-setup, focus-mode.
        Set true in shared/graphical.nix to preserve the current X11 setup.
        Set false (with hydrix.hyprland.enable = true) to switch to Wayland.
      '';
    };
  };

  options.hydrix.hyprland = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the Hyprland/Wayland window manager stack.
        Activates: Hyprland, Waybar, wofi, hypridle, hyprlock, hypr-focus-daemon.
        Can be true alongside hydrix.i3.enable during transition testing.
      '';
    };

    workspaceColors = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "1" = "7aa2f7ff";
        "2" = "ff749fff";
        "3" = "98c379ff";
      };
      description = ''
        Per-workspace active border color overrides for Hyprland windowrule.
        Keys are workspace numbers (as strings), values are RGBA hex color strings
        (8 characters, e.g. "7aa2f7ff"). When empty (the default), no workspace
        color rules are generated. Set in your hydrix-config to taste.
      '';
    };

    xwayland = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable optimizations for graphical apps that work better under XWayland
          (e.g. Steam, native Linux games, older toolkits). Adds to hydrix-generated.conf:
          - xwayland.force_zero_scaling = true: XWayland apps render at the physical display
            resolution instead of the lower logical resolution under fractional scaling.
            On a 1.5× scaled 1920×1200 display, this keeps XWayland apps at 1920×1200
            rather than the 1280×800 logical resolution.
          - Window rules that disable blur and restore opacity=1.0 for Steam game windows
            and fullscreen windows, letting the compositor skip unnecessary rendering
            overhead for those surfaces.
          Enable only in specialisations where such apps are available
          (e.g. administrative).
        '';
      };
    };

    extraBinds = lib.mkOption {
      type    = lib.types.lines;
      default = "";
      description = ''
        Machine-specific Hyprland bind lines appended after the shared config.
        Set in your machine config for hardware-specific binds (e.g. volume keys,
        brightness, special function keys).
      '';
    };
  };

  options.hydrix.sway = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the Sway/Wayland window manager stack.
        Compositor-agnostic: waypipe VM forwarding works identically with Sway and Hyprland.
        Do not enable alongside hydrix.hyprland.enable — they compete for seat0.
      '';
    };
  };
}
