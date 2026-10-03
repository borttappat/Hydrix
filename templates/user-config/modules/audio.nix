# Audio control: one `audio` CLI on every machine, used by the waybar audio
# and volume pills and the volume keybinds.
#
#   audio speakers|headphones|bluetooth   switch output
#   audio toggle                          next available output
#   audio volume [+|-|N]                  step 5%, set N%, or print
#   audio mute|unmute                     default sink
#   audio status                          output and volume, human readable
#   audio output                          "AUD SPKR|HP|BT|OUT" (waybar)
#   audio level                           "VOL N%|VOL MUTED" (waybar)
#
# The default works on plain PipeWire: outputs are picked by sink and port
# names. A machine whose hardware needs its own handling sets
# hydrix.audio.cli to a package providing the same `audio` interface (see
# custom/zenaudio.nix).
{
  config,
  lib,
  pkgs,
  ...
}: let
  pactl = "${pkgs.pulseaudio}/bin/pactl";
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  jq = "${pkgs.jq}/bin/jq";

  genericAudio = pkgs.writeShellScriptBin "audio" ''
    set -u
    export PATH=${lib.makeBinPath [pkgs.coreutils pkgs.gnugrep]}:$PATH

    # One "kind<TAB>sink<TAB>port" line per selectable output. Bluetooth sinks
    # are one output each; other sinks contribute each available port, or the
    # sink itself when it has no ports.
    outputs() {
      ${pactl} -f json list sinks 2>/dev/null | ${jq} -r '
        def kind: ascii_downcase
          | if test("bluez|bluetooth") then "bluetooth"
            elif test("headphone|headset") then "headphones"
            elif test("speaker") then "speakers"
            else "other" end;
        .[] | . as $s
        | if (.name | test("bluez")) then ["bluetooth", .name, ""]
          elif ((.ports // []) | length) > 0 then
            .ports[] | select(.availability != "not available")
            | [((.name + " " + .description) | kind), $s.name, .name]
          else [((.name + " " + .description) | kind), .name, ""] end
        | @tsv'
    }

    current() {
      local def
      def=$(${pactl} get-default-sink 2>/dev/null) || return
      ${pactl} -f json list sinks 2>/dev/null | ${jq} -r --arg d "$def" '
        .[] | select(.name == $d)
        | (.name + " " + .description + " " + (.active_port // "")) | ascii_downcase
        | if test("bluez|bluetooth") then "bluetooth"
          elif test("headphone|headset") then "headphones"
          elif test("speaker") then "speakers"
          else "other" end'
    }

    switch_to() {
      local want=$1 kind sink port
      while IFS=$'\t' read -r kind sink port; do
        [ "$kind" = "$want" ] || continue
        [ -n "$port" ] && ${pactl} set-sink-port "$sink" "$port"
        ${pactl} set-default-sink "$sink"
        echo "Switched to $want"
        return 0
      done < <(outputs)
      echo "No $want output available" >&2
      return 1
    }

    toggle() {
      local cur avail=() k next=""
      cur=$(current)
      for k in speakers headphones bluetooth; do
        outputs | cut -f1 | grep -qx "$k" && avail+=("$k")
      done
      [ ''${#avail[@]} -gt 0 ] || { echo "No switchable outputs" >&2; return 1; }
      for i in "''${!avail[@]}"; do
        if [ "''${avail[$i]}" = "$cur" ]; then
          next=''${avail[$(( (i + 1) % ''${#avail[@]} ))]}
        fi
      done
      switch_to "''${next:-''${avail[0]}}"
    }

    level() {
      local vol mute
      vol=$(${pactl} get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+(?=%)' | head -1)
      [ -n "$vol" ] || { echo; return; }
      mute=$(${pactl} get-sink-mute @DEFAULT_SINK@ 2>/dev/null)
      case "$mute" in *yes*) echo "VOL MUTED" ;; *) echo "VOL $vol%" ;; esac
    }

    output() {
      case "$(current)" in
        speakers) echo "AUD SPKR" ;;
        headphones) echo "AUD HP" ;;
        bluetooth) echo "AUD BT" ;;
        other) echo "AUD OUT" ;;
        *) echo ;;
      esac
    }

    case "''${1:-}" in
      speakers | headphones | bluetooth) switch_to "$1" ;;
      toggle) toggle ;;
      volume)
        case "''${2:-}" in
          +) ${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ ;;
          -) ${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
          "") level ;;
          *) ${wpctl} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ "''${2%\%}%" ;;
        esac
        ;;
      mute) ${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
      unmute) ${wpctl} set-mute @DEFAULT_AUDIO_SINK@ 0 ;;
      status) echo "Output: $(current)"; level ;;
      output) output ;;
      level) level ;;
      *)
        echo "usage: audio speakers|headphones|bluetooth|toggle|volume [+|-|N]|mute|unmute|status" >&2
        exit 1
        ;;
    esac
  '';
in {
  options.hydrix.audio.cli = lib.mkOption {
    type = lib.types.package;
    default = genericAudio;
    description = ''
      Package providing the `audio` command (see the header of this file for
      its interface). Replace it on machines whose audio hardware needs its
      own handling; waybar and the volume keybinds only ever call `audio`.
    '';
  };

  config.environment.systemPackages = [config.hydrix.audio.cli];
}
