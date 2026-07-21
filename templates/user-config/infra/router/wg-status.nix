# WireGuard status vsock endpoint (port 14515)
#
# Two-service design (mirrors net-stats.nix):
#   wg-status-poller — background loop, samples `wg show all dump` + geo
#                       lookups every SAMPLE_INTERVAL seconds, writes JSON
#                       to /tmp/wg-status.json
#   wg-status-vsock   — socat VSOCK-LISTEN, handler just cats that file
#                       (instant)
#
# Location lookup order:
#   1. Mullvad relay list (api.mullvad.net) — accurate for all Mullvad IPs
#   2. ipinfo.io — fallback for non-Mullvad IPs
# Relay list cached in /tmp for 1 hour; per-IP results cached until reboot.
#
# Location lookup runs on the router, which always has internet — so the host
# eww exit-nodes widget can display city/country even in lockdown mode.
#
# To disable (suppresses outbound requests and the vsock listener):
#   services.wgStatusVsock.enable = false;

{ config, lib, pkgs, ... }:
let
  cfg = config.services.wgStatusVsock;

  wgStatusPoller = pkgs.writeShellApplication {
    name = "wg-status-poller";
    runtimeInputs = [ pkgs.wireguard-tools pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      # Matches the 10s cadence eww's wg_nodes defpoll actually reads at —
      # sampling faster just burns CPU on wg/geo lookups for no one.
      SAMPLE_INTERVAL=10

      relay_cache="/tmp/wg-mullvad-relays.json"

      refresh_relay_cache() {
        local now relay_age
        now=$(date +%s)
        relay_age=0
        [ -f "$relay_cache" ] && relay_age=$(( now - $(stat -c %Y "$relay_cache" 2>/dev/null || echo 0) ))
        if [ ! -f "$relay_cache" ] || [ "$relay_age" -gt 3600 ]; then
          curl -sf --max-time 15 "https://api.mullvad.net/www/relays/all/" 2>/dev/null \
            > "$relay_cache.tmp" && mv "$relay_cache.tmp" "$relay_cache" || true
        fi
      }

      lookup_location() {
        local ip="$1" cache loc city country result
        cache="/tmp/wg-loc-''${ip}"
        [ -f "$cache" ] && { cat "$cache"; return; }

        city=""; country=""

        # Try Mullvad relay list first
        if [ -f "$relay_cache" ]; then
          city=$(jq -r --arg ip "$ip" \
            '.[] | select(.ipv4_addr_in == $ip) | .city_name // empty' \
            "$relay_cache" 2>/dev/null | head -1 || true)
          country=$(jq -r --arg ip "$ip" \
            '.[] | select(.ipv4_addr_in == $ip) | .country_code // empty' \
            "$relay_cache" 2>/dev/null | head -1 | tr '[:lower:]' '[:upper:]' || true)
        fi

        # Fall back to ipinfo.io
        if [ -z "$city" ] || [ -z "$country" ]; then
          result=$(curl -sf --max-time 10 "https://ipinfo.io/''${ip}/json" 2>/dev/null || true)
          city=$(echo    "$result" | jq -r '.city    // empty' 2>/dev/null || true)
          country=$(echo "$result" | jq -r '.country // empty' 2>/dev/null || true)
        fi

        if [ -n "$city" ] && [ -n "$country" ]; then
          loc="''${city}, ''${country}"
          echo "$loc" > "$cache"
        else
          loc="$ip"
        fi
        echo "$loc"
      }

      sample_wg() {
        local now result sep iface ep_ip hs rx tx age server line
        now=$(date +%s)
        result="["; sep=""

        # wg show all dump peer lines (9 fields, tab-separated):
        #   iface  pubkey  preshared  endpoint  allowed-ips  handshake  rx  tx  keepalive
        # Interface lines have 5 fields; skip them by checking f6 is non-empty.
        while IFS=$'\t' read -r f1 _ _ f4 _ f6 f7 f8 _; do
          [ -n "$f6" ] || continue
          iface="$f1"; ep_ip="''${f4%%:*}"
          hs=''${f6:-0}; rx=''${f7:-0}; tx=''${f8:-0}
          age=$(( hs > 0 ? now - hs : -1 ))

          server="$ep_ip"
          if [ -f "/etc/wireguard/''${iface}.conf" ]; then
            while IFS= read -r line; do
              case "$line" in "# Server: "*) server="''${line#\# Server: }"; break ;; esac
            done < "/etc/wireguard/''${iface}.conf"
          fi

          location=$(lookup_location "$ep_ip")

          result+="''${sep}{\"iface\":\"''${iface}\",\"endpoint\":\"''${ep_ip}\",\"handshake\":''${age},\"rx\":''${rx},\"tx\":''${tx},\"server\":\"''${server}\",\"location\":\"''${location}\"}"
          sep=","
        done < <(wg show all dump 2>/dev/null)

        echo "''${result}]"
      }

      while true; do
        refresh_relay_cache
        sample_wg > /tmp/wg-status.json.tmp \
          && mv /tmp/wg-status.json.tmp /tmp/wg-status.json
        sleep "$SAMPLE_INTERVAL"
      done
    '';
  };

  wgStatusHandler = pkgs.writeShellApplication {
    name = "wg-status-handler";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      cat /tmp/wg-status.json 2>/dev/null || echo '[]'
    '';
  };
in {
  options.services.wgStatusVsock.enable = lib.mkOption {
    type        = lib.types.bool;
    default     = true;
    description = "WireGuard status vsock endpoint (port 14515) for host eww exit-nodes widget.";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.wg-status-poller = {
      description = "WireGuard status background poller (writes /tmp/wg-status.json every 5s)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" ];
      serviceConfig = {
        Type       = "simple";
        ExecStart  = "${wgStatusPoller}/bin/wg-status-poller";
        Restart    = "always";
        RestartSec = 5;
      };
    };

    systemd.services.wg-status-vsock = {
      description = "WireGuard status vsock endpoint (port 14515)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "wg-status-poller.service" ];
      serviceConfig = {
        Type       = "simple";
        ExecStart  = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14515,reuseaddr,fork EXEC:${wgStatusHandler}/bin/wg-status-handler";
        Restart    = "always";
        RestartSec = 5;
      };
    };
  };
}
