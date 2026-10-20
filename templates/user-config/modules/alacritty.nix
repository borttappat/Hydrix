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
#   selection.saveToClipboard = true
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
  # ── Cursor ────────────────────────────────────────────────────────────────
  hydrix.graphical.alacritty.cursor.shape         = lib.mkDefault "Underline";
  hydrix.graphical.alacritty.cursor.blinking      = lib.mkDefault "Always";
  hydrix.graphical.alacritty.cursor.thickness     = lib.mkDefault 0.35;
  hydrix.graphical.alacritty.cursor.blinkTimeout  = lib.mkDefault 0;
  hydrix.graphical.alacritty.cursor.blinkInterval = lib.mkDefault 500;

  # ── Selection ──────────────────────────────────────────────────────────────
  hydrix.graphical.alacritty.selection.saveToClipboard = lib.mkDefault true;

  # ── Vi mode and hints ─────────────────────────────────────────────────────────
  # Lists concatenate with the framework's keyboard.bindings. Setting
  # hints.enabled replaces Alacritty's default URL hint, so it is restated (O).
  home-manager.users.${username} = lib.mkIf config.hydrix.graphical.enable {
    home.packages = [ (pkgs.writeShellScriptBin "vikeys" "cat ${keysFile}") ];

    programs.alacritty.settings = {
      keyboard.bindings = [
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
          command = "xdg-open";
          post_processing = true;
          mouse.enabled = true;
          binding = { key = "O"; mods = "Control|Shift"; };
        }
      ];
    };
  };
}
