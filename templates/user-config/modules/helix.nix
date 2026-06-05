# Helix Editor — User Configuration
#
# Config is written as a plain writable file via home.activation.
# Edit ~/.config/helix/config.toml freely between rebuilds.
# Rebuild overwrites it with the values defined here.
#
# Theme: base16_default reads colors dynamically from xrdb (pywal/wal cache).
{
  config,
  lib,
  pkgs,
  ...
}: let
  username = config.hydrix.username;

  helixConfig = pkgs.writeText "helix-config.toml"
    /*
    TOML
    */
    ''
      theme = "base16_default"

      [editor]
      mouse = true
      auto-save = true
      #rulers = [80, 120]
      line-number = "relative"
      cursorline = true
      cursorcolumn = true
      bufferline = "always"

      [editor.cursor-shape]
      insert = "bar"
      normal = "block"
      select = "underline"

      # https://docs.helix-editor.com/master/configuration.html#editorsoft-wrap-section
      [editor.soft-wrap]
      enable = true
      # wrap-at-text-width = true
      wrap-indicator = "↩ "

      ### https://docs.helix-editor.com/master/configuration.html#editorwhitespace-section
      [editor.whitespace.render]
      space = "all"
      tab = "all"
      newline = "none"

      [editor.whitespace.characters]
      space = " "
      nbsp = " "    # Non Breaking SPace
      tab = "→"
      newline = " "
      #tabpad = "·"  # Tabs will look like "→···" (depending on tab width)
      ###

      [editor.statusline]
      left = [ "mode", "spinner", "diagnostics" ]
      center = [ "file-name", "separator", "version-control", "separator" ]
      right = [ "position", "position-percentage", "total-line-numbers" ]
      separator = "│"
      mode.normal = "NORMAL"
      mode.insert = "INSERT"
      mode.select = "SELECT"

      [editor.lsp]
      display-inlay-hints = true

      [editor.indent-guides]
      render = true
      character = "╎" # Some characters that work well: "▏", "┆", "┊", "⸽"
      skip-levels = 1

      [editor.file-picker]
      hidden = false

      [keys.normal]
      # https://www.root.cz/clanky/textovy-editor-helix-ve-funkci-vyvojoveho-prostredi-2-cast/#k11
      ins = "insert_mode"
      esc = ["collapse_selection", "keep_primary_selection"]
      # C-tab = ":buffer-previous"
      # C-S-tab = ":buffer-next"
      # A-w = ":buffer-close"

      # https://github.com/helix-editor/helix/discussions/7898
      space.c = "toggle_comments"

      # Use system clipboard
      p = "paste_clipboard_before"
      y = "yank_main_selection_to_clipboard"

      # https://github.com/helix-editor/helix/discussions/7908
      space.x = ":toggle whitespace.render all none"

      # Mark line and move with them up/down
      # https://github.com/helix-editor/helix/discussions/5764#discussioncomment-4840408
      C-j = ["extend_to_line_bounds", "delete_selection", "paste_after"]
      C-k = ["extend_to_line_bounds", "delete_selection", "move_line_up", "paste_before"]

      # Duplicate lines up/down
      # https://github.com/helix-editor/helix/issues/3680#issuecomment-1399443274
      S-A-down = ["normal_mode", "extend_to_line_bounds", "yank", "open_below", "replace_with_yanked", "collapse_selection"]
      S-A-up = ["normal_mode", "extend_to_line_bounds", "yank", "open_above", "replace_with_yanked", "collapse_selection"]

      S-space = ["half_page_up"]

      space."." = "file_picker_in_current_buffer_directory"

      [keys.insert]
      ins = "normal_mode"

      # Duplicate lines up/down
      # https://github.com/helix-editor/helix/issues/3680#issuecomment-1399443274
      S-A-down = ["normal_mode", "extend_to_line_bounds", "yank", "open_below", "replace_with_yanked", "collapse_selection"]
      S-A-up = ["normal_mode", "extend_to_line_bounds", "yank", "open_above", "replace_with_yanked", "collapse_selection"]
    '';
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    environment.systemPackages = [ pkgs.helix ];

    home-manager.users.${username} = { lib, ... }: {
      home.activation.helixConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _dir="$HOME/.config/helix"
        mkdir -p "$_dir"
        [ -L "$_dir/config.toml" ] && rm -f "$_dir/config.toml"
        cat ${helixConfig} > "$_dir/config.toml"
      '';
    };
  };
}
