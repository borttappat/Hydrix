# i3 Keybindings — User Configuration
#
# VM-first design: app launches default to ws-app (routes to VM on pinned workspaces).
# Host-only tools (hydrix-tui, hydrix-float-terminal, display-setup, lock) use direct exec.
#
# Customize these keybindings for your workflow.
# This file is imported by flake.nix into all machine configs.
#
{ config, lib, pkgs, ... }:
let
  username = config.hydrix.username;
  mod = "Mod4";  # Host uses Super
in {
  home-manager.users.${username} = { lib, ... }: {
    xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault {
      # === Terminal ===
      "${mod}+Return" = "exec --no-startup-id ws-app alacritty";
      "${mod}+Shift+Return" = "exec alacritty-dpi";          # Host terminal
      "${mod}+s" = "exec hydrix-float-terminal";

      # === Launcher ===
      "${mod}+q" = "kill";
      "${mod}+d" = "exec --no-startup-id host-rofi";
      "${mod}+Shift+d" = "exec --no-startup-id vm-launch";

      # === Browser (via VM) ===
      "${mod}+b" = "exec --no-startup-id ws-app firefox";
      # Add your bookmarks:
      # "${mod}+a" = "exec --no-startup-id ws-app firefox https://example.com";

      # === Applications ===
      "${mod}+m" = "exec alacritty-dpi --class floating -e hydrix-tui";
      "${mod}+Shift+m" = "exec microvm-rofi";
      # "${mod}+o" = "exec --no-startup-id ws-app obsidian";
      # "${mod}+z" = "exec --no-startup-id ws-app zathura";

      # === Volume ===
      "${mod}+F1" = "exec amixer set Master 0%";
      "${mod}+F2" = "exec amixer set Master 5%-";
      "${mod}+F3" = "exec amixer set Master 5%+";

      # === Screenshot ===
      "${mod}+F12" = "exec flameshot gui";

      # === Brightness / Vibrancy / Blugon ===
      "${mod}+F7" = "exec hydrix-brightness -";
      "${mod}+F8" = "exec hydrix-brightness +";
      "${mod}+Shift+F7" = "exec hydrix-vibrancy -";
      "${mod}+Shift+F8" = "exec hydrix-vibrancy +";
      "${mod}+F5" = "exec blugon-set -";
      "${mod}+F6" = "exec blugon-set +";
      "${mod}+Shift+F6" = "exec blugon-set reset";

      # === Display ===
      "${mod}+Shift+v" = "exec display-setup";
      "${mod}+Shift+F5" = "exec --no-startup-id display-recover";

      # === System monitors ===
      "${mod}+Shift+u" = "exec alacritty-dpi -e htop";
      "${mod}+Shift+b" = "exec alacritty-dpi -e btm";

      # === Config editing ===
      "${mod}+Shift+i" = "exec alacritty-dpi -e vim ~/.config/i3/config";
      "${mod}+Shift+p" = "exec alacritty-dpi -e vim ~/.config/polybar/config.ini";
      "${mod}+Shift+n" = "exec alacritty-dpi -e vim ${config.hydrix.paths.configDir}/flake.nix";
      "${mod}+Shift+comma" = "exec alacritty-dpi -e vim ${config.hydrix.paths.configDir}/machines/${config.hydrix.hostname}.nix";

      # === File manager (via VM) ===
      "${mod}+Shift+f" = "exec --no-startup-id ws-app alacritty -e joshuto";

      # === Git status ===
      "${mod}+Shift+g" = "exec alacritty-dpi -e /bin/sh -c 'clear && cd ${config.hydrix.paths.configDir} && git status && exec fish'";

      # === Wallpaper ===
      "${mod}+w" = "exec randomwalrgb";
      # "${mod}+Shift+w" = "exec feh --bg-fill ~/wallpapers/Black.jpg";

      # === Lock / Suspend ===
      "${mod}+Shift+e" = "exec --no-startup-id lock";
      "${mod}+Shift+s" = "exec systemctl suspend";

      # === Navigation ===
      "${mod}+h" = "focus left";
      "${mod}+j" = "focus down";
      "${mod}+k" = "focus up";
      "${mod}+l" = "focus right";
      "${mod}+Left" = "focus left";
      "${mod}+Down" = "focus down";
      "${mod}+Up" = "focus up";
      "${mod}+Right" = "focus right";

      # === Move windows ===
      "${mod}+Shift+h" = "move left";
      "${mod}+Shift+j" = "move down";
      "${mod}+Shift+k" = "move up";
      "${mod}+Shift+l" = "move right";

      # === Layout ===
      "${mod}+c" = "split v";
      "${mod}+v" = "split h";
      "${mod}+f" = "fullscreen toggle";
      "${mod}+Shift+space" = "floating toggle";
      "${mod}+space" = "focus mode_toggle";
      "${mod}+r" = "mode resize";

      # === Quick resize ===
      "${mod}+ctrl+h" = "resize shrink width 5 ppt";
      "${mod}+ctrl+j" = "resize grow height 5 ppt";
      "${mod}+ctrl+k" = "resize shrink height 5 ppt";
      "${mod}+ctrl+l" = "resize grow width 5 ppt";

      # === Gaps ===
      "${mod}+Shift+Up" = "gaps inner current plus 5";
      "${mod}+Shift+Down" = "gaps inner current minus 5";
      "${mod}+Shift+Right" = "gaps outer current plus 5";
      "${mod}+Shift+Left" = "gaps outer current minus 5";

      # === Misc ===
      "${mod}+Shift+r" = "exec display-setup";
      "${mod}+p" = "exec polybar-msg cmd restart";
      "${mod}+Shift+minus" = "move scratchpad";
      "${mod}+minus" = "scratchpad show";

      # === Workspaces ===
      "${mod}+1" = "workspace 1";
      "${mod}+2" = "workspace 2";
      "${mod}+3" = "workspace 3";
      "${mod}+4" = "workspace 4";
      "${mod}+5" = "workspace 5";
      "${mod}+6" = "workspace 6";
      "${mod}+7" = "workspace 7";
      "${mod}+8" = "workspace 8";
      "${mod}+9" = "workspace 9";
      "${mod}+0" = "workspace 10";
      "${mod}+Shift+1" = "move container to workspace 1";
      "${mod}+Shift+2" = "move container to workspace 2";
      "${mod}+Shift+3" = "move container to workspace 3";
      "${mod}+Shift+4" = "move container to workspace 4";
      "${mod}+Shift+5" = "move container to workspace 5";
      "${mod}+Shift+6" = "move container to workspace 6";
      "${mod}+Shift+7" = "move container to workspace 7";
      "${mod}+Shift+8" = "move container to workspace 8";
      "${mod}+Shift+9" = "move container to workspace 9";
      "${mod}+Shift+0" = "move container to workspace 10";
    };

    # Workspace output pinning (uncomment for multi-monitor)
    # xsession.windowManager.i3.config.workspaceOutputAssign = [
    #   { workspace = "1"; output = "eDP-1"; }
    # ];
  };
}
