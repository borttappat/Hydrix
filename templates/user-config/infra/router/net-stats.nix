# Network stats vsock endpoint (port 14517)
#
# Two-service design:
#   net-stats-poller  — background loop, samples /proc/net/dev every 1s,
#                       writes delta JSON to /tmp/net-stats.json
#   net-stats-vsock   — socat VSOCK-LISTEN, handler just cats that file (instant)
#
# Response format:
#   {"wan":{"iface":"wlan0","rx":N,"tx":N},"vms":[{"vm":"brow","rx":N,"tx":N},...]}
#
# rx/tx are bytes/second. VMs appear only when their mv-router-* TAP is live.

{ config, lib, pkgs, ... }:
let
  cfg = config.services.netStatsVsock;

  netStatsPoller = pkgs.writeShellApplication {
    name = "net-stats-poller";
    runtimeInputs = [ pkgs.gawk pkgs.iproute2 pkgs.coreutils ];
    text = ''
      sample_dev() {
        awk -F: 'NR>2 {
          gsub(/^[[:space:]]+/, "", $1)
          n = split($2, f, " ")
          if (n >= 9) print $1, f[1], f[9]
        }' /proc/net/dev
      }

      clamp() { local v=$(( $1 - $2 )); [ "$v" -lt 0 ] && echo 0 || echo "$v"; }

      while true; do
        declare -A rx1 tx1
        while read -r iface rx tx; do
          rx1["$iface"]=$rx; tx1["$iface"]=$tx
        done < <(sample_dev)

        sleep 1

        declare -A rx2 tx2
        while read -r iface rx tx; do
          rx2["$iface"]=$rx; tx2["$iface"]=$tx
        done < <(sample_dev)

        wan=$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}' || true)
        wan_rx=$(clamp "''${rx2[$wan]:-0}" "''${rx1[$wan]:-0}")
        wan_tx=$(clamp "''${tx2[$wan]:-0}" "''${tx1[$wan]:-0}")

        result="{\"wan\":{\"iface\":\"''${wan}\",\"rx\":''${wan_rx},\"tx\":''${wan_tx}},\"vms\":["
        sep=""

        for iface in "''${!rx2[@]}"; do
          case "$iface" in mv-router-*) ;; *) continue ;; esac
          vm="''${iface#mv-router-}"
          rx=$(clamp "''${rx2[$iface]:-0}" "''${rx1[$iface]:-0}")
          tx=$(clamp "''${tx2[$iface]:-0}" "''${tx1[$iface]:-0}")
          result+="''${sep}{\"vm\":\"''${vm}\",\"rx\":''${rx},\"tx\":''${tx}}"
          sep=","
        done

        result+="]}"
        printf '%s\n' "''${result}" > /tmp/net-stats.json.tmp \
          && mv /tmp/net-stats.json.tmp /tmp/net-stats.json

        unset rx1 tx1 rx2 tx2
      done
    '';
  };

  netStatsHandler = pkgs.writeShellApplication {
    name = "net-stats-handler";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      cat /tmp/net-stats.json 2>/dev/null \
        || echo '{"wan":{"iface":"","rx":0,"tx":0},"vms":[]}'
    '';
  };
in {
  options.services.netStatsVsock.enable = lib.mkOption {
    type        = lib.types.bool;
    default     = true;
    description = "Network stats vsock endpoint (port 14517) for host eww net-overlay widget.";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.net-stats-poller = {
      description = "Network stats background poller (writes /tmp/net-stats.json every 1s)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" ];
      serviceConfig = {
        Type       = "simple";
        ExecStart  = "${netStatsPoller}/bin/net-stats-poller";
        Restart    = "always";
        RestartSec = 5;
      };
    };

    systemd.services.net-stats-vsock = {
      description = "Network stats vsock endpoint (port 14517)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "net-stats-poller.service" ];
      serviceConfig = {
        Type       = "simple";
        ExecStart  = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14517,reuseaddr,fork EXEC:${netStatsHandler}/bin/net-stats-handler";
        Restart    = "always";
        RestartSec = 5;
      };
    };
  };
}
