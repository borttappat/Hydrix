# Fish Shell — User Configuration
#
# Framework provides: pywal color sequences, fzf/zoxide integration, Ctrl+R,
# vi key bindings (hydrix.graphical.fish.viKeyBindings), lockdown git wrapper.
#
# This file sets: abbreviations, fish colors, cursor, key bindings, functions.
{
  config,
  lib,
  pkgs,
  ...
}: let
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    # vi key bindings on (framework default)
    hydrix.graphical.fish.viKeyBindings = lib.mkDefault true;

    home-manager.users.${username} = {pkgs, ...}: {
      programs.fish = {

        interactiveShellInit = ''
          # Fish syntax colors
          set -g fish_color_autosuggestion 555 brblack
          set -g fish_color_cancel -r
          set -g fish_color_command blue
          set -g fish_color_comment red
          set -g fish_color_cwd green
          set -g fish_color_cwd_root red
          set -g fish_color_end green
          set -g fish_color_error brred
          set -g fish_color_escape brcyan
          set -g fish_color_history_current --bold
          set -g fish_color_host normal
          set -g fish_color_host_remote yellow
          set -g fish_color_normal normal
          set -g fish_color_operator brcyan
          set -g fish_color_param cyan
          set -g fish_color_quote yellow
          set -g fish_color_redirection cyan --bold
          set -g fish_color_search_match --background=111
          set -g fish_color_selection white --bold --background=brblack
          set -g fish_color_status red
          set -g fish_color_user brgreen
          set -g fish_color_valid_path --underline
          set -g fish_pager_color_completion normal
          set -g fish_pager_color_description B3A06D yellow -i
          set -g fish_pager_color_prefix cyan --bold --underline
          set -g fish_pager_color_progress brwhite --background=cyan
          set -g fish_pager_color_selected_background -r

          # Vi mode cursor shapes
          set fish_cursor_default     underscore blink
          set fish_cursor_insert      underscore blink
          set fish_cursor_replace_one underscore blink
          set fish_cursor_visual      underscore blink

          # Ctrl+Z — bring last job to foreground
          bind \cz 'fg 2>/dev/null; commandline -f repaint'

          # Double-Escape — prepend sudo to last command
          bind \e\e sudo_last_command
          bind -M insert \e\e sudo_last_command

          # Directory memory — restore last working directory
          if test -f /tmp/last_fish_dir
            read -l last_dir < /tmp/last_fish_dir
            test -d "$last_dir"; and cd "$last_dir"
          end

          # Auto-resume recording if flag file exists
          if test -f ~/.recording_active
            and not set -q RECORDING_ACTIVE
            set -l log_dir (cat ~/.recording_active)
            set -l timestamp (date +%Y%m%d_%H%M%S)
            set -gx RECORDING_FILE "$log_dir/session_$timestamp.cast"
            set -gx RECORDING_ACTIVE 1
            echo "[!] Recording to: $RECORDING_FILE"
            asciinema rec "$RECORDING_FILE"
            set -e RECORDING_ACTIVE
            set -e RECORDING_FILE
          end
        '';

        shellAbbrs =
          {
            # Nix
            nsp  = "nix-shell --run fish -p";
            nfu  = "nix flake update --flake ${config.hydrix.paths.configDir}";
            nfuh = "nix flake update --flake ${config.hydrix.paths.configDir} hydrix";

            # System
            reboot   = "systemctl reboot";
            shutdown = "shutdown -h now";
            sd       = "shutdown -h now";
            ncg      = "sudo nix-collect-garbage -d";

            # Editors
            v    = "vim";
            nano = "vim";
            vn   = "vim notes.txt";

            # Navigation
            "..." = "cd ../..";
            j     = "joshuto";
            r     = "ranger";
            wp    = "cd ~/wallpapers && joshuto";
            hyd   = "cd ${config.hydrix.paths.configDir} && git status";
            hydrix = "cd ${config.hydrix.paths.configDir}";

            # File listing (eza)
            ls = "eza -A --color=always --group-directories-first";
            l  = "eza -Al --color=always --group-directories-first";
            lt = "eza -AT --color=always --group-directories-first";

            # Grep (ugrep)
            grep  = "ugrep --color=auto";
            egrep = "ugrep -E --color=auto";
            fgrep = "ugrep -F --color=auto";

            # Git
            gs  = "git status";
            ga  = "git add";
            gd  = "git diff";
            gc  = "git commit -m";
            gp  = "git push -uf origin main";
            gur = "git add -A && git commit -m 'updates' && git push -uf origin main";
            gu  = "git add -u && git commit -m 'updates' && git push -uf origin main";
            gl  = "git log --oneline --graph --decorate -20";

            # Utilities
            h   = "htop";
            ka  = "killall";
            bat = "bat --theme=ansi";
            cb  = "cbonsai -l -t 1";
            g   = "glances";
            cm  = "cmatrix -u 10";
            p   = "pipes-rs -f 25 -p 7 -r 1.0";
            bw  = "sudo bandwhich";
            md  = "mkdir -p";
            ip  = "ip -color";
            cf  = "clear && fastfetch";

            # Multi-VM commands
            mvm = "microvm";

            # Config files
            f     = "vim ~/.config/fish/config.fish";
            flake = "vim ${config.hydrix.paths.configDir}/flake.nix";

            # Pentesting
            msf      = "figlet -f cricket 'msf' && sudo msfconsole -q";
            sesp     = "searchsploit";
            ptime    = "sudo pentest-time -r ${if config.time.timeZone == null then "UTC" else config.time.timeZone}";
            pyserver = "sudo python -m http.server 8002";

            # Applications
            zath    = "zathura --fork=false";
            zathura = "zathura --fork=false";
            ai      = "aichat -H --save-session -s";
            nf      = "nix search nixpkgs";
          }
          // lib.optionalAttrs (!isVM) {
            suspend = "systemctl suspend";
            x       = "startx";
            w       = "hyprland-launch";
            rb      = "rebuild";
            machine = "vim ${config.hydrix.paths.configDir}/machines/${config.hydrix.hostname}.nix";
          };

        functions =
          {
            # cd and ls
            mkcd = "mkdir -p $argv[1] && cd $argv[1]";
            c    = "cd $argv && ls";

            # Filtered listing
            sls = "ls | grep -i $argv";
            sl  = "eza -Al --color=always --group-directories-first | grep -i $argv";

            # Python environment
            pyenv = "pyenvshell $argv";

            # Toggle vi/emacs mode
            toggle_vim_mode = ''
              if test "$fish_key_bindings" = "fish_vi_key_bindings"
                fish_default_key_bindings
                echo "Switched to default (emacs) key bindings"
              else
                fish_vi_key_bindings
                echo "Switched to vi key bindings"
              end
            '';

            # Sort files by extension into subdirs
            filesort = ''
              set -l target_dir $argv[1]
              if test -z "$target_dir"
                set target_dir .
              end
              if not test -d "$target_dir"
                echo "Error: $target_dir is not a directory"
                return 1
              end
              for file in $target_dir/*
                if not test -f "$file"
                  continue
                end
                set -l basename (basename $file)
                set -l ext (string match -r '\.[^.]+$' $basename | string sub -s 2)
                if test -n "$ext"
                  mkdir -p "$target_dir/$ext"
                  mv "$file" "$target_dir/$ext/"
                else
                  mkdir -p "$target_dir/no_extension"
                  mv "$file" "$target_dir/no_extension/"
                end
              end
              echo "Files sorted by extension in $target_dir"
            '';

            # Start asciinema recording
            start_recording = ''
              set -l log_dir $argv[1]
              if test -z "$log_dir"
                set log_dir ~/terminal_logs
              end
              mkdir -p $log_dir
              echo "$log_dir" > ~/.recording_active
              set -l timestamp (date +%Y%m%d_%H%M%S)
              set -gx RECORDING_FILE "$log_dir/session_$timestamp.cast"
              set -gx RECORDING_ACTIVE 1
              echo "[!] Recording enabled - all new terminals will record"
              echo "[!] Recording to: $RECORDING_FILE"
              asciinema rec "$RECORDING_FILE"
              set -e RECORDING_ACTIVE
              set -e RECORDING_FILE
            '';

            # Stop recording
            stop_recording = ''
              if set -q RECORDING_ACTIVE
                echo "[!] Stopping recording..."
                echo "   Press Ctrl+D or type 'exit' to finish this session"
                if test -f ~/.recording_active
                  rm ~/.recording_active
                end
                exit
              else if test -f ~/.recording_active
                rm ~/.recording_active
                echo "[!] Recording disabled for new terminals"
              else
                echo "[!] Recording was not active"
              end
            '';

            # Extract various archive formats
            extract = ''
              if test -f $argv[1]
                switch $argv[1]
                  case '*.tar.bz2' ; tar xjf $argv[1]
                  case '*.tar.gz'  ; tar xzf $argv[1]
                  case '*.tar.xz'  ; tar xJf $argv[1]
                  case '*.bz2'     ; bunzip2 $argv[1]
                  case '*.gz'      ; gunzip $argv[1]
                  case '*.tar'     ; tar xf $argv[1]
                  case '*.tbz2'    ; tar xjf $argv[1]
                  case '*.tgz'     ; tar xzf $argv[1]
                  case '*.zip'     ; unzip $argv[1]
                  case '*.Z'       ; uncompress $argv[1]
                  case '*.7z'      ; 7z x $argv[1]
                  case '*'         ; echo "Cannot extract '$argv[1]'"
                end
              else
                echo "'$argv[1]' is not a valid file"
              end
            '';
          }
          // lib.optionalAttrs (!isVM) {
            # Start X session
            x = "startx";
            # Start Hyprland
            w = "hyprland-launch";
          };
      };
    };
  };
}
