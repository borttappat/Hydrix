#     ___ __       __
#   .'  _|__.-----|  |--.
#   |   _|  |__ --|     |
#   |__| |__|_____|__|__|
#

# Disable fish greeting
set -g fish_greeting

# === INTERACTIVE BLOCK ===
if status is-interactive
    # Apply pywal colors (sequences now managed by home-manager/Nix)
    # The sequences file is generated with proper escape codes
    if test -f ~/.cache/wal/sequences
        cat ~/.cache/wal/sequences
    end

    fish_vi_key_bindings
    
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
end

# === CURSOR SETTINGS ===
set fish_cursor_default underscore blink
set fish_cursor_insert underscore blink
set fish_cursor_replace_one underscore blink
set fish_cursor_visual underscore blink

# === INITS ===
# Starship
starship init fish | source

# Zoxide
zoxide init fish | source

# Save current directory whenever PWD changes
function __save_last_dir --on-variable PWD
    echo $PWD > /tmp/last_fish_dir
end

# === DIRECTORY-MEMORY ===
# Restore last directory on shell startup
if status is-interactive
    and test -f /tmp/last_fish_dir
    set -l last_dir (cat /tmp/last_fish_dir)
    if test -d "$last_dir"
        cd "$last_dir"
    end
end

# === MKCD ===
function mkcd
    mkdir -p $argv[1] && cd $argv[1]
end


# === VIM MODE ===
function toggle_vim_mode
    if test "$fish_key_bindings" = "fish_vi_key_bindings"
        fish_default_key_bindings
        echo "Switched to default (emacs) key bindings"
    else
        fish_vi_key_bindings
        echo "Switched to vi key bindings"
    end
end

function sudo_last_command
    commandline -r "sudo $history[1]"
end

bind \e\e sudo_last_command
bind -M insert \e\e sudo_last_command

# === NIX SHELL ===
abbr -a nsp 'nix-shell --run fish -p'

# === SYSTEM ===
abbr -a reboot 'systemctl reboot'
abbr -a rb 'systemctl reboot'
abbr -a shutdown 'shutdown -h now'
abbr -a sd 'shutdown -h now'
abbr -a suspend 'systemctl suspend'
abbr -a ncg 'sudo nix-collect-garbage -d'

# === EDITORS ===
abbr -a v 'vim'
abbr -a nano 'vim'
abbr -a vn 'vim notes.txt'

# === NAVIGATION ===
abbr -a ... 'cd ../..'
abbr -a j 'joshuto'
abbr -a r 'ranger'
abbr -a wp 'cd ~/Wallpapers && ranger'
abbr -a hyd 'cd ~/Hydrix && git status'

function c
    cd $argv && ls
end

function mkcd
    mkdir -p $argv && cd $argv
end

# === FILE SORTING ===
function filesort
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
end

# === FILE LISTING ===
abbr -a ls 'eza -A --color=always --group-directories-first'
abbr -a l 'eza -Al --color=always --group-directories-first'
abbr -a lt 'eza -AT --color=always --group-directories-first'

function sls
    ls | grep -i $argv
end

function sl
    eza -Al --color=always --group-directories-first | grep -i $argv
end

# === GREP ===
abbr -a grep 'ugrep --color=auto'
abbr -a egrep 'ugrep -E --color=auto'
abbr -a fgrep 'ugrep -F --color=auto'

# === GIT ===
abbr -a gs 'git status'
abbr -a ga 'git add'
abbr -a gd 'git diff'
abbr -a gc 'git commit -m'
abbr -a gp 'git push -uf origin main'
abbr -a gur 'git add -A && git commit -m "updates" && git push -uf origin main'
abbr -a gu 'git add -u && git commit -m "updates" && git push -uf origin main'
abbr -a gl 'git log --oneline --graph --decorate -20'

# === UTILITIES ===
abbr -a h 'htop'
abbr -a ka 'killall'
abbr -a bat 'bat --theme=ansi'
abbr -a cb 'cbonsai -l -t 1'
abbr -a g 'glances'
abbr -a cm 'cmatrix -u 10'
abbr -a p 'pipes-rs -f 25 -p 7 -r 1.0'
abbr -a bw 'sudo bandwhich'
abbr -a md 'mkdir -p'
abbr -a ip 'ip -color'
abbr -a cf 'clear && fastfetch'
abbr -a reload 'source ~/.config/fish/config.fish'

# === CONFIG FILES ===
abbr -a f 'vim ~/.config/fish/config.fish'
abbr -a fishconf 'vim ~/.config/fish/config.fish'
abbr -a flake 'vim ~/Hydrix/flake.nix'
abbr -a nixconf 'vim ~/Hydrix/modules/base/configuration.nix'
abbr -a npp 'vim ~/Hydrix/modules/pentesting/pentesting.nix'
abbr -a nixsrv 'vim ~/Hydrix/modules/base/services.nix'
abbr -a hosts 'vim ~/Hydrix/modules/pentesting/hosts.nix'
abbr -a asusconf 'vim ~/Hydrix/modules/base/hardware/asus.nix'
abbr -a ac 'vim ~/Hydrix/configs/alacritty/alacritty.toml.template'
abbr -a alacrittyconf 'vim ~/Hydrix/configs/alacritty/alacritty.toml.template'
abbr -a pc 'vim ~/Hydrix/configs/picom/picom.conf'
abbr -a picomconf 'vim ~/Hydrix/configs/picom/picom.conf'
abbr -a poc 'vim ~/Hydrix/configs/polybar/config.ini.template'
abbr -a polyconf 'vim ~/Hydrix/configs/polybar/config.ini.template'
abbr -a zathconf 'vim ~/Hydrix/configs/zathura/zathurarc'

# === PENTESTING ===
abbr -a msf 'figlet -f cricket "msf" && sudo msfconsole -q'
abbr -a sesp 'searchsploit'
abbr -a ptime 'sudo pentest-time -r Europe/Stockholm'
abbr -a htblabs 'sudo openvpn ~/Downloads/lab_griefhoundTCP.ovpn'
abbr -a pyserver 'sudo python -m http.server 8002'

# === DEV ENVIRONMENTS ===
abbr -a bloodhound 'nix develop ~/Hydrix#bloodhound'

function pyenv
    ~/Hydrix/scripts/pyenvshell.sh $argv
end

# === APPLICATIONS ===
abbr -a zath 'zathura --fork=false'
abbr -a zathura 'zathura --fork=false'
abbr -a ai 'aichat -H --save-session -s'
abbr -a x 'startx'
abbr -a nf 'nix search nixpkgs'

# === AUDIO ===
function zenaudio
    sh ~/Hydrix/scripts/zenaudio.sh $argv
end

abbr -a za 'zenaudio'
abbr -a zah 'zenaudio headphones && zenaudio volume 75'
abbr -a zas 'zenaudio speakers && zenaudio volume 75'
abbr -a zab 'zenaudio bluetooth && zenaudio volume 75'

# === VISUALS ===
# walrgb is in PATH via Hydrix theming/dynamic.nix - call directly

function rgb
    openrgb --device 0 --mode static --color $argv
end

# === XRANDR ===
abbr -a xrandrwide 'xrandr --output HDMI-1 --mode 3440x1440 --output eDP-1 --off && wal -R && killall polybar && polybar -q &'
abbr -a xrandrrestore 'xrandr --output eDP-1 --mode 1920x1200 --output HDMI-1 --off && wal -R && killall polybar && polybar -q &'

# === NETWORK ===
abbr -a nwshow 'nmcli dev wifi show'
abbr -a nwconnect 'nmcli --ask dev wifi connect'

# wifirestore script - add to Hydrix scripts/ if needed

# === TAILSCALE ===
abbr -a tds 'sudo tailscale file cp'
abbr -a tdr 'sudo tailscale file get'

# === VM/ROUTER ===
abbr -a rc 'sudo virsh console router-vm-passthrough'
abbr -a tui 'sh ~/splix/scripts/router-tui.sh'

# === SCRIPTS ===
function nixbuild
    sh ~/Hydrix/scripts/nixbuild.sh $argv
end

abbr -a nb 'nixbuild'
