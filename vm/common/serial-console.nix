# Serial console window sizing
#
# A serial line carries no window-size signal, so a shell on ttyS0 stays at the
# kernel default of 80x24 regardless of the attached terminal. Before each
# prompt, query the host terminal for its size (park the cursor at the far
# corner, read back the DSR cursor-position report) and apply it with stty,
# so `shard console` output follows the host window as it is resized.
{pkgs, ...}: let
  serialResize = pkgs.writeShellScript "serial-resize" ''
    saved=$(stty -g) || exit 0
    stty raw -echo
    printf '\0337\033[r\033[999;999H\033[6n\0338' > /dev/tty
    IFS='[;' read -r -t 0.3 -d R _ rows cols < /dev/tty
    stty "$saved"
    [[ $rows =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] && stty rows "$rows" cols "$cols"
  '';
in {
  programs.bash.interactiveShellInit = ''
    case "$(tty)" in
      /dev/ttyS*)
        # Preserve $? for later PROMPT_COMMAND entries (e.g. prompt status).
        __serial_resize() { local s=$?; ${serialResize}; return $s; }
        PROMPT_COMMAND="__serial_resize''${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        ;;
    esac
  '';

  programs.fish.interactiveShellInit = ''
    if string match -q '/dev/ttyS*' (tty)
      function __serial_resize --on-event fish_prompt
        ${serialResize}
        kill -WINCH $fish_pid
      end
    end
  '';
}
