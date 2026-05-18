# Starship Prompt — User Configuration

{ config, lib, ... }:

let
  username = config.hydrix.username;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = { ... }: {
      xdg.configFile."starship.toml".text = ''
        "$schema" = 'https://starship.rs/config-schema.json'

        format = """
        $username\
        $hostname\
        $directory\
        $git_branch\
        $git_commit\
        $git_state\
        $git_metrics\
        $git_status\
        $jobs\
        $cmd_duration\
        $time\
        $line_break\
        $character"""

        # Blank line handled by fish's __add_newline function
        add_newline = false

        [jobs]
        symbol = ""
        number_threshold = 1
        symbol_threshold = 1
        format = "[$number jobs]($style) "
        style = "bold blue"

        [username]
        format = " [$user]($style) "
        style_user = "bold yellow"
        style_root = "bold red"
        show_always = true

        [character]
        success_symbol = " [>](bold yellow)"
        error_symbol = " [X](bold yellow)"

        [hostname]
        format = "[@ $hostname]($style) in "
        style = "bold red"
        ssh_only = false
        ssh_symbol = ">>>"
        disabled = false

        [package]
        disabled = true

        [directory]
        style = "bold purple"
        truncation_length = 10
        truncate_to_repo = false
        disabled = false
        read_only = ' [R]'
        home_symbol = '~'

        [time]
        disabled = false
        format = 'at [$time]($style) '
        time_format = "%H:%M:%S"
        style = "bold cyan"

        [git_branch]
        symbol = ""
        format = "[$branch]($style) "

        [git_status]
        style = "white"
        ahead = "ahead ''${count}"
        diverged = "diverged +''${ahead_count} -''${behind_count}"
        behind = "behind ''${count}"
        deleted = "x"
        modified = "!"
        up_to_date = 'ok'

        [git_commit]
        commit_hash_length = 4
        tag_symbol = ""

        [cmd_duration]
        min_time = 2000
        format = "took [$duration]($style) "
        disabled = false

        [status]
        symbol = ""
        format = '[\[$symbol$status_common_meaning$status_signal_name$status_maybe_int\]]($style)'
        map_symbol = true
        disabled = true
        not_found_symbol = "X"

        [python]
        symbol = "PY "
        format = 'via [python (''${version} )(\(''${virtualenv}\) )]($style)'
        style = "bold yellow"
        pyenv_prefix = "venv "
        python_binary = ["./venv/bin/python", "python", "python3", "python2"]
        detect_extensions = ["py"]
        version_format = "v''${raw}"
        disabled = true

        [battery]
        disabled = false
        full_symbol = 'full '
        charging_symbol = 'charging '
        discharging_symbol = 'low '

        [direnv]
        disabled = true

        [aws]
        disabled = true
      '';
    };
  };
}
