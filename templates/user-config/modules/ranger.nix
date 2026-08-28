# Ranger File Manager — User Configuration
#
# Full ranger configuration. Settings, mappings, and rifle rules are all
# defined here. Override per-machine in machines/*.nix.
#
# programs.ranger normally symlinks rc.conf/rifle.conf into the read-only nix
# store. That placement is disabled below and the same generated content is
# copied into plain writable files instead, editable between rebuilds, like
# hyprland/waybar/eww. Rebuild restores them to the settings/mappings/rifle
# below.

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { lib, pkgs, ... } @ hmArgs: {
      programs.ranger = {
        enable = lib.mkDefault true;

        settings = lib.mkDefault {
          # Preview
          preview_images = true;
          preview_images_method = "kitty";
          preview_files = true;
          preview_directories = true;
          collapse_preview = true;

          # Display
          draw_borders = "both";
          column_ratios = "1,3,4";
          hidden_filter = "^\\.|\\.pyc$|~$";
          show_hidden = false;
          confirm_on_delete = "multiple";

          # Behavior
          autosave_bookmarks = true;
          save_console_history = true;
          mouse_enabled = true;
          tilde_in_titlebar = true;

          # Sorting
          sort = "natural";
          sort_case_insensitive = true;
          sort_directories_first = true;

          # VCS
          vcs_aware = true;
          vcs_backend_git = "enabled";
        };

        mappings = lib.mkDefault {
          # Quick navigation
          gh = "cd ~";
          gH = "cd ${config.hydrix.paths.configDir}";
          gd = "cd ~/Downloads";
          gD = "cd ~/Documents";
          gp = "cd ~/Pictures";
          gv = "cd ~/Videos";
          gc = "cd ~/.config";
          gn = "cd /nix/store";

          # Operations
          DD = "shell mv %s ~/.local/share/Trash/files/";
          X = "shell extract %s";
          Z = "shell tar -cvzf %f.tar.gz %s";

          # Toggle settings
          zh = "set show_hidden!";
          zp = "set preview_files!";
          zi = "set preview_images!";
        };

        rifle = lib.mkDefault [
          # Web
          { condition = "ext x?html?, has firefox, X, flag f"; command = "firefox -- \"$@\""; }

          # Text
          { condition = "mime ^text, label editor"; command = "\${VISUAL:-$EDITOR} -- \"$@\""; }
          { condition = "ext py, label editor"; command = "\${VISUAL:-$EDITOR} -- \"$@\""; }
          { condition = "ext nix, label editor"; command = "\${VISUAL:-$EDITOR} -- \"$@\""; }

          # Images
          { condition = "mime ^image, has feh, X, flag f"; command = "feh -- \"$@\""; }
          { condition = "mime ^image, has sxiv, X, flag f"; command = "sxiv -- \"$@\""; }

          # Video/Audio
          { condition = "mime ^video, has mpv, X, flag f"; command = "mpv -- \"$@\""; }
          { condition = "mime ^audio, has mpv, X, flag f"; command = "mpv -- \"$@\""; }

          # PDF
          { condition = "ext pdf, has zathura, X, flag f"; command = "zathura -- \"$@\""; }

          # Archives
          { condition = "ext tar|gz|bz2|xz|zip|rar|7z"; command = "extract \"$@\""; }

          # Fallback
          { condition = "mime ^text, label pager"; command = "\${PAGER:-less} -- \"$@\""; }
        ];
      };

      # Joshuto as alternative file manager
      home.packages = [ pkgs.joshuto ];

      xdg.configFile."ranger/rc.conf".enable = lib.mkForce false;
      xdg.configFile."ranger/rifle.conf".enable = lib.mkForce false;

      home.activation.rangerConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _dir="$HOME/.config/ranger"
        mkdir -p "$_dir"
        [ -L "$_dir/rc.conf" ] && rm -f "$_dir/rc.conf"
        [ -L "$_dir/rifle.conf" ] && rm -f "$_dir/rifle.conf"
        cat ${hmArgs.config.xdg.configFile."ranger/rc.conf".source} > "$_dir/rc.conf"
        cat ${hmArgs.config.xdg.configFile."ranger/rifle.conf".source} > "$_dir/rifle.conf"
      '';
    };
  };
}
