# Fish Shell Configuration
#
# Home Manager module for Fish shell.
# Includes all abbreviations, functions, and starship prompt.
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
    home-manager.users.${username} = {pkgs, ...}: {
      programs.fish = {
        enable = true;

        shellInit = ''
          # Disable greeting
          set -g fish_greeting

          ${lib.optionalString (!isVM) ''
            # Apply pywal colors to terminal (host only)
            # VMs use alacritty's live_config_reload via colors-runtime.toml instead
            if test -f ~/.cache/wal/sequences
              cat ~/.cache/wal/sequences
            end
          ''}
        '';

        interactiveShellInit = ''
          # Add blank line between prompts (but not before first prompt)
          function __add_newline --on-event fish_prompt
            if set -q __first_prompt_done
              echo
            else
              set -g __first_prompt_done 1
            end
          end

          # Note: Auto-start X disabled - xpra handles graphical apps in VMs

          # Set fzf colors from pywal (transparent bg, uses terminal palette)
          # Optimized: single read instead of 8 sed calls
          if test -f ~/.cache/wal/colors
            set -l colors (head -9 ~/.cache/wal/colors)
            # colors[1-9] = c0-c8 (fish is 1-indexed)
            set -gx FZF_DEFAULT_OPTS "--color=fg:$colors[8],bg:-1,hl:$colors[5],fg+:$colors[8],bg+:$colors[9],hl+:$colors[5],info:$colors[7],prompt:$colors[5],pointer:$colors[6],marker:$colors[4],spinner:$colors[7],header:$colors[9]"
          end

          # Register directory save event handler (autoload doesn't register event handlers)
          functions -q __save_last_dir; or source ~/.config/fish/functions/__save_last_dir.fish

          # Fish colors - restore legacy settings (no backgrounds on commands)
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

          # Vi key bindings
          fish_vi_key_bindings

          # Explicitly source fzf bindings to ensure they are loaded
          # This fixes issues where Home Manager might source them too late
          if test -f ${pkgs.fzf}/share/fish/vendor_functions.d/fzf_key_bindings.fish
            source ${pkgs.fzf}/share/fish/vendor_functions.d/fzf_key_bindings.fish
          end

          # Bind Ctrl+R in vi modes
          bind -M insert \cr fzf-history-widget
          bind -M default \cr fzf-history-widget

          # Cursor settings
          set fish_cursor_default underscore blink
          set fish_cursor_insert underscore blink
          set fish_cursor_replace_one underscore blink
          set fish_cursor_visual underscore blink

          # Ctrl+Z to foreground
          bind \cz 'fg 2>/dev/null; commandline -f repaint'

          # Double-Escape for sudo last command
          bind \e\e sudo_last_command
          bind -M insert \e\e sudo_last_command

          # Directory memory - restore last directory
          if test -f /tmp/last_fish_dir
            read -l last_dir < /tmp/last_fish_dir
            test -d "$last_dir"; and cd "$last_dir"
          end

          # Auto-start recording if flag exists
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

          ${lib.optionalString (!isVM) ''
            # Lockdown-aware git wrapper (host only)
            # Intercepts push/pull/fetch in lockdown mode and delegates to git-sync VM
            function git --wraps git
              if contains -- $argv[1] push pull fetch
                if test -f /etc/HYDRIX_MODE
                  and grep -q "MODE=lockdown" /etc/HYDRIX_MODE
                  set -l toplevel (command git rev-parse --show-toplevel 2>/dev/null)
                  if test -n "$toplevel"
                    set -l repo_name (basename $toplevel)
                    echo -e "\033[33m::\033[0m Lockdown mode — routing through git-sync VM."
                    read -P "Use git-sync VM for $argv[1] $repo_name? [Y/n] " confirm
                    if test -z "$confirm" -o "$confirm" = Y -o "$confirm" = y
                      microvm git $argv[1] $repo_name
                      return $status
                    else
                      echo "Cancelled."
                      return 1
                    end
                  end
                end
              end
              command git $argv
            end
          ''}
        '';

        # Fish abbreviations (expand on space)
        shellAbbrs =
          {
            # Nix shell
            nsp = "nix-shell --run fish -p";

            # Nix flake update
            nfu = "nix flake update"

            # System
            reboot = "systemctl reboot";
            shutdown = "shutdown -h now";
            sd = "shutdown -h now";
            ncg = "sudo nix-collect-garbage -d";

            # Editors
            v = "vim";
            nano = "vim";
            vn = "vim notes.txt";

            # Navigation
            "..." = "cd ../..";
            j = "joshuto";
            r = "ranger";
            wp = "cd ~/wallpapers && joshuto";
            # User's config directory (source of truth)
            hyd = "cd ${config.hydrix.paths.configDir} && git status";
            hydrix = "cd ${config.hydrix.paths.configDir}";

            # File listing (eza)
            ls = "eza -A --color=always --group-directories-first";
            l = "eza -Al --color=always --group-directories-first";
            lt = "eza -AT --color=always --group-directories-first";

            # Grep (ugrep)
            grep = "ugrep --color=auto";
            egrep = "ugrep -E --color=auto";
            fgrep = "ugrep -F --color=auto";

            # Git
            gs = "git status";
            ga = "git add";
            gd = "git diff";
            gc = "git commit -m";
            gp = "git push -uf origin main";
            gur = "git add -A && git commit -m 'updates' && git push -uf origin main";
            gu = "git add -u && git commit -m 'updates' && git push -uf origin main";
            gl = "git log --oneline --graph --decorate -20";

            # Utilities
            h = "htop";
            ka = "killall";
            bat = "bat --theme=ansi";
            cb = "cbonsai -l -t 1";
            g = "glances";
            cm = "cmatrix -u 10";
            p = "pipes-rs -f 25 -p 7 -r 1.0";
            bw = "sudo bandwhich";
            md = "mkdir -p";
            ip = "ip -color";
            cf = "clear && fastfetch";

            # Multi-VM commands - expands to "microvm", allows multi-VM commands
            mvm = "microvm";

            # Config files - user's hydrix-config (what you edit day-to-day)
            f = "vim ~/.config/fish/config.fish";
            flake = "vim ${config.hydrix.paths.configDir}/flake.nix";

            # Pentesting
            msf = "figlet -f cricket 'msf' && sudo msfconsole -q";
            sesp = "searchsploit";
            ptime = "sudo pentest-time -r Europe/Stockholm";
            pyserver = "sudo python -m http.server 8002";

            # Applications
            zath = "zathura --fork=false";
            zathura = "zathura --fork=false";
            ai = "aichat -H --save-session -s";
            nf = "nix search nixpkgs";
          }
          // lib.optionalAttrs (!isVM) {
            # Host-only abbreviations (hardware, host commands)
            suspend = "systemctl suspend";
            x = "startx";
            rb = "rebuild";
            machine = "vim ${config.hydrix.paths.configDir}/machines/${config.hydrix.hostname}.nix";

            # Display switching (host hardware)
            xrandrwide = "xrandr --output HDMI-1 --mode 3440x1440 --output eDP-1 --off && wal -R && killall polybar && polybar -q &";
            xrandrrestore = "xrandr --output eDP-1 --mode 1920x1200 --output HDMI-1 --off && wal -R && killall polybar && polybar -q &";

          };

        functions =
          {
            # Quick directory navigation
            mkcd = "mkdir -p $argv[1] && cd $argv[1]";

            # cd and ls
            c = "cd $argv && ls";

            # Save directory on PWD change
            __save_last_dir = {
              body = "echo $PWD > /tmp/last_fish_dir";
              onVariable = "PWD";
            };

            # Sudo last command
            sudo_last_command = "commandline -r \"sudo $history[1]\"";

            # Toggle vim mode
            toggle_vim_mode = ''
              if test "$fish_key_bindings" = "fish_vi_key_bindings"
                fish_default_key_bindings
                echo "Switched to default (emacs) key bindings"
              else
                fish_vi_key_bindings
                echo "Switched to vi key bindings"
              end
            '';

            # File sorting by extension
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

            # Filtered ls
            sls = "ls | grep -i $argv";
            sl = "eza -Al --color=always --group-directories-first | grep -i $argv";

            # Python environment
            pyenv = "pyenvshell $argv";

            # Start recording
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
                  case '*.tar.bz2'
                    tar xjf $argv[1]
                  case '*.tar.gz'
                    tar xzf $argv[1]
                  case '*.tar.xz'
                    tar xJf $argv[1]
                  case '*.bz2'
                    bunzip2 $argv[1]
                  case '*.gz'
                    gunzip $argv[1]
                  case '*.tar'
                    tar xf $argv[1]
                  case '*.tbz2'
                    tar xjf $argv[1]
                  case '*.tgz'
                    tar xzf $argv[1]
                  case '*.zip'
                    unzip $argv[1]
                  case '*.Z'
                    uncompress $argv[1]
                  case '*.7z'
                    7z x $argv[1]
                  case '*'
                    echo "Cannot extract '$argv[1]'"
                end
              else
                echo "'$argv[1]' is not a valid file"
              end
            '';
          }
          // lib.optionalAttrs (!isVM) {
            # Host-only functions (hardware, host commands)

            # Start X session
            x = "startx";

            # Smart router console
            rc = ''
              if systemctl is-active --quiet microvm@microvm-router.service
                echo "Connecting to microvm-router (Ctrl+] to disconnect)..."
                sudo socat -,rawer,escape=0x1d unix-connect:/var/lib/microvms/microvm-router/console.sock
              else if sudo virsh domstate router-vm 2>/dev/null | grep -q running
                echo "Connecting to router-vm via Spice..."
                virt-viewer --connect qemu:///system router-vm
              else
                echo "No router running. Start with:"
                echo "  microvm: sudo systemctl start microvm@microvm-router"
                echo "  libvirt: sudo virsh start router-vm"
              end
            '';

          };
      };

      # Zoxide (smart cd)
      programs.zoxide = {
        enable = true;
        enableFishIntegration = true;
      };

      # FZF (fuzzy finder) - restores Ctrl+R history search
      # Colors are set dynamically from pywal in interactiveShellInit
      programs.fzf = {
        enable = true;
        enableFishIntegration = true;
      };
    };
  };
}
