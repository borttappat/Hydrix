# Alacritty Terminal - User Configuration
#
# The framework handles: DPI font size, window opacity, color import,
# VM color inheritance, and keyboard bindings.
# Set cursor and selection preferences here.
#
# Framework defaults:
#   cursor.shape           = "Underline"  (Block | Underline | Beam)
#   cursor.blinking        = "Always"     (Never | Off | On | Always)
#   cursor.thickness       = 0.35
#   cursor.unfocusedHollow = false
#   cursor.blinkTimeout    = 0            (0 = never stop blinking)
#   cursor.blinkInterval   = 500
#   selection.saveToClipboard = false
#
# Opacity is set via hydrix.graphical.ui.opacity.overlay in graphical.nix.
#
# Keyboard-only navigation: vi mode (Ctrl+Shift+Space) plus hints. `:` in vi
# mode, or `vikeys` in a shell, shows the key list below (keysText).

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;

  keysText = ''
     ALACRITTY VI MODE                       Ctrl+Shift+Space  enter
     ───────────────────────────────────────────────────────────────
     move     h j k l   w b e  W B E   0 ^ $   { }   %
     screen   H M L  top/mid/bottom     g G  top/bottom of history
     scroll   Ctrl+u/d  half page       Ctrl+b/f  page   Ctrl+y/e line
     find     f F t T  char in line, ; , repeat
     search   / ?  forward/back   n N  next/prev   * #  word under cursor
     jump     s  label a line       S  label a word   (type the label)
     select   v  char   V  line   Ctrl+v  block   Alt+v  word
     copy     y  copy selection     Esc  clear selection
     leave    q   i   Ctrl+c        :  this help

     COPY HINTS (normal mode, type the label)
     ───────────────────────────────────────────────────────────────
     Ctrl+Shift+L  line        Ctrl+Shift+P  path     Ctrl+Shift+H  hash
     Ctrl+Shift+I  IP address  Ctrl+Shift+U  URL      Ctrl+Shift+O  open URL

     No counts (5j), no :42, no yy: use s to jump, / to search further up.
  '';
  keysFile = pkgs.writeText "alacritty-keys.txt" keysText;

  # One font size for every window of this machine or VM: edits font.size in the
  # writable alacritty.toml, which live reload applies to open and new windows.
  # Activation (rebuild, live switch, boot) resets it to the Nix-configured size.
  baseFontSize = config.home-manager.users.${username}.programs.alacritty.settings.font.size;
  fontSizeScript = pkgs.writeShellApplication {
    name = "alacritty-font-size";
    runtimeInputs = [ pkgs.gawk pkgs.coreutils ];
    text = ''
      file=''${ALACRITTY_FONT_FILE:-$HOME/.config/alacritty/alacritty.toml}
      [ -f "$file" ] || exit 0
      cur=$(awk '/^\[/ { f = ($0 == "[font]") } f && /^size *=/ { sub(/^size *= */, ""); print; exit }' "$file")
      case "''${1:-}" in
        up)    new=$(awk -v s="''${cur:-${toString baseFontSize}}" 'BEGIN { print s + 1 }') ;;
        down)  new=$(awk -v s="''${cur:-${toString baseFontSize}}" 'BEGIN { print (s > 5 ? s - 1 : 4) }') ;;
        reset) new=$(awk 'BEGIN { print ${toString baseFontSize} }') ;;
        *) echo "usage: alacritty-font-size up|down|reset" >&2; exit 1 ;;
      esac
      [ "$new" = "$cur" ] && exit 0
      tmp=$(mktemp "$file.XXXXXX")
      trap 'rm -f "$tmp"' EXIT
      awk -v n="$new" '
        /^\[/ { if (f && !done) { print "size = " n; done = 1 } f = ($0 == "[font]"); if (f) seen = 1 }
        f && /^size *=/ { if (!done) print "size = " n; done = 1; next }
        { print }
        END { if (!seen) printf "\n[font]\nsize = %s\n", n; else if (f && !done) print "size = " n }
      ' "$file" > "$tmp"
      chmod 644 "$tmp"
      mv "$tmp" "$file"
    '';
  };
  fontSizeBind = key: arg: {
    inherit key; mods = "Control|Shift";
    command = { program = "${fontSizeScript}/bin/alacritty-font-size"; args = [ arg ]; };
  };

  viMode = "Vi|~Search";
  # home-manager's alacritty module turns every `\\` in the generated TOML into
  # `\`, so regex backslashes are doubled to survive it.
  escape = lib.replaceStrings ["\\"] ["\\\\"];
  urlRegex = ''(https?://|ftp://|file:|mailto:|ssh:|git://)[^\s<>"{}|\\^`]+'';
  jumpHint = mods: regex: {
    regex = escape regex;
    action = "MoveViModeCursor";
    binding = { key = "S"; mode = viMode; } // lib.optionalAttrs (mods != null) { inherit mods; };
  };
  copyHint = key: regex: {
    regex = escape regex;
    action = "Copy";
    binding = { inherit key; mods = "Control|Shift"; };
  };
in {
  system.activationScripts.alacrittyFontReset = lib.mkIf config.hydrix.graphical.enable ''
    _file=${config.users.users.${username}.home}/.config/alacritty/alacritty.toml
    if [ -f "$_file" ]; then
      ${pkgs.util-linux}/bin/runuser -u ${username} -- \
        ${pkgs.coreutils}/bin/env ALACRITTY_FONT_FILE="$_file" ${fontSizeScript}/bin/alacritty-font-size reset || true
    fi
  '';

  # ── Cursor ────────────────────────────────────────────────────────────────
  hydrix.graphical.alacritty.cursor.shape         = lib.mkDefault "Underline";
  hydrix.graphical.alacritty.cursor.blinking      = lib.mkDefault "Always";
  hydrix.graphical.alacritty.cursor.thickness     = lib.mkDefault 0.35;
  hydrix.graphical.alacritty.cursor.blinkTimeout  = lib.mkDefault 0;
  hydrix.graphical.alacritty.cursor.blinkInterval = lib.mkDefault 500;

  # ── Selection ──────────────────────────────────────────────────────────────
  hydrix.graphical.alacritty.selection.saveToClipboard = lib.mkDefault false;

  # ── Vi mode and hints ─────────────────────────────────────────────────────────
  # Lists concatenate with the framework's keyboard.bindings. Setting
  # hints.enabled replaces Alacritty's default URL hint, so it is restated (O).
  home-manager.users.${username} = lib.mkIf config.hydrix.graphical.enable {
    home.packages = [ (pkgs.writeShellScriptBin "vikeys" "cat ${keysFile}") fontSizeScript ];

    programs.alacritty.settings = {
      # Ctrl+Shift+Plus/Minus/0, global font size. Alacritty matches the character the
      # key types with Shift held, so these depend on the layout: "?" "_" "=" for se,
      # "+" "_" ")" for us. `alacritty --print-events` shows it for other layouts.
      keyboard.bindings = [
        (fontSizeBind "?" "up")
        (fontSizeBind "_" "down")
        (fontSizeBind "=" "reset")
        { key = "Q"; mode = viMode; action = "ToggleViMode"; }
        {
          key = ":"; mods = "Shift"; mode = viMode;
          command = {
            program = "alacritty";
            args = [ "--class" "hypr-float" "--title" "alacritty-keys" "-e" "less" "-S" "${keysFile}" ];
          };
        }
      ];

      hints.enabled = [
        (jumpHint null ''\S.*'')
        (jumpHint "Shift" ''\S+'')
        (copyHint "L" ''\S.*'')
        (copyHint "P" ''(~|\.{1,2})?/[^\s:'"]+'')
        (copyHint "H" "[0-9a-f]{7,64}")
        (copyHint "I" ''[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+|/[0-9]{1,2})?'')
        (copyHint "U" urlRegex)
        {
          regex = escape urlRegex;
          command = "${pkgs.xdg-utils}/bin/xdg-open";
          post_processing = true;
          mouse.enabled = true;
          binding = { key = "O"; mods = "Control|Shift"; };
        }
      ];
    };
  };
}
