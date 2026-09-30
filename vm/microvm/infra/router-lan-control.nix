# Router LAN Control Service
#
# Vsock control endpoint (port 14516, host only) for letting a VM network reach
# the physical LAN the router's uplink is on, and for forwarding uplink ports
# to a VM. Driven by the host's `pentest-lan` command.
#
# The router firewall (microvm-router.nix) drops traffic from VM networks to
# private addresses on the uplink side unless the network's TAP is in the
# `lan_access` set. This service only edits that set, a policy rule that keeps
# LAN-bound traffic of tunnelled networks out of their tunnel, and DNAT rules
# in its own `ip hydrix-lan` table. Replies to DNATed connections are routed
# back via the main table by the router firewall, so forwards also work for
# tunnelled networks.
#
# Commands (one line per connection):
#   ENABLE_LAN <CID>                Allow network <CID> onto the uplink's LAN
#   DISABLE_LAN <CID>               Isolate it again
#   PORT_ADD <CID> <PORT> [<IP>]    Forward uplink TCP <PORT> to the VM (default IP <subnet>.<CID>)
#   PORT_REMOVE <CID> <PORT>        Remove that forward
#   SYNC                            Re-apply granted access after a firewall reload
#   LAN_STATUS                      Show current state
#   PING                            Health check
#
# Standing forwards (e.g. a media server for LAN devices) are declared with
# hydrix.router.lanControl.forwards and applied through the same PORT_ADD path
# once the uplink is up.
#
# CID = subnet third octet by convention, which is how networks are looked up.
{
  config,
  pkgs,
  lib,
  ...
}: let
  stateDir = "/var/lib/hydrix-router";
  netCfg = config.hydrix.networking;
  networks = let
    profile = netCfg.profileNetworks;
  in
    profile ++ lib.filter (n: !(builtins.any (p: p.routerTap == n.routerTap) profile)) netCfg.extraNetworks;
  octet = n: lib.last (lib.splitString "." n.subnet);

  lanControlBin = pkgs.writeShellScriptBin "router-lan-control" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [iproute2 nftables gawk gnugrep coreutils jq])}

    STATE_FILE="${stateDir}/lan-state.json"
    LOG_FILE="${stateDir}/lan-control.log"

    log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
    fail() { echo "ERROR: $*"; exit 1; }

    # Sets TAP and SUBNET for a CID, from the build-time network list
    lookup_net() {
      case "$1" in
        ${lib.concatMapStrings (n: ''
        ${octet n}) TAP="${n.routerTap}"; SUBNET="${n.subnet}" ;;
      '')
      networks}
        *) fail "unknown network CID '$1'" ;;
      esac
    }

    wan_iface() {
      local f=${stateDir}/wan_interface
      if [ -s "$f" ] && [ "$(cat "$f")" != none ]; then cat "$f"; return; fi
      ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'
    }

    # The uplink's own LAN prefix (e.g. 192.168.1.0/24)
    wan_lan() {
      ip -4 route show dev "$1" scope link proto kernel 2>/dev/null | awk '{print $1; exit}'
    }

    state() {
      local tmp
      tmp=$(mktemp)
      jq "$@" "$STATE_FILE" > "$tmp"
      mv "$tmp" "$STATE_FILE"
    }

    grant() { nft add element inet router lan_access "{ \"$1\" }" 2>/dev/null || true; }

    enable_lan() {
      lookup_net "$1"
      local wan lan
      wan=$(wan_iface)
      lan=$(wan_lan "$wan")
      [ -n "$lan" ] || fail "uplink $wan has no LAN address yet"
      grant "$TAP"
      # A tunnelled network's table would send LAN traffic into the tunnel
      ip rule del from "$SUBNET.0/24" to "$lan" lookup main priority 100 2>/dev/null || true
      ip rule add from "$SUBNET.0/24" to "$lan" lookup main priority 100
      state --arg cid "$1" --arg lan "$lan" \
        '.enabledVMs = ([.enabledVMs[] | select(.cid != $cid)] + [{cid: $cid, lan: $lan}])'
      log "LAN enabled: CID $1 ($TAP) -> $lan via $wan"
      echo "OK: CID $1 can reach $lan via $wan"
    }

    disable_lan() {
      lookup_net "$1"
      nft delete element inet router lan_access "{ \"$TAP\" }" 2>/dev/null || true
      local lan
      for lan in $(jq -r --arg cid "$1" '.enabledVMs[] | select(.cid == $cid) | .lan' "$STATE_FILE"); do
        ip rule del from "$SUBNET.0/24" to "$lan" lookup main priority 100 2>/dev/null || true
      done
      state --arg cid "$1" '.enabledVMs = [.enabledVMs[] | select(.cid != $cid)]'
      log "LAN disabled: CID $1 ($TAP)"
      echo "OK: CID $1 isolated from the uplink LAN"
    }

    rule_tag() { echo "hydrix-lan cid=$1 port=$2"; }

    add_port_forward() {
      lookup_net "$1"
      local port="$2" ip="''${3:-$SUBNET.$1}" wan
      [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail "invalid port '$port'"
      wan=$(wan_iface)
      [ -n "$wan" ] || fail "no uplink interface"
      remove_rules "$1" "$port"
      nft add table ip hydrix-lan
      nft add chain ip hydrix-lan prerouting '{ type nat hook prerouting priority dstnat - 1; policy accept; }'
      nft add rule ip hydrix-lan prerouting iifname "$wan" tcp dport "$port" \
        dnat to "$ip:$port" comment "\"$(rule_tag "$1" "$port")\""
      state --arg cid "$1" --arg port "$port" --arg ip "$ip" \
        '.portForwards = ([.portForwards[] | select(.cid != $cid or .port != $port)] + [{cid: $cid, port: $port, ip: $ip}])'
      log "Forward: $wan:$port -> $ip:$port (CID $1)"
      local wan_ip
      wan_ip=$(ip -4 -o addr show dev "$wan" | awk '{split($4, a, "/"); print a[1]; exit}')
      echo "OK: ''${wan_ip:-$wan}:$port -> $ip:$port"
    }

    # Delete this CID/port's DNAT rules, matched by their exact comment
    remove_rules() {
      local tag handle
      tag=$(rule_tag "$1" "$2")
      { nft -a list chain ip hydrix-lan prerouting 2>/dev/null || true; } \
        | awk -v t="comment \"$tag\"" 'index($0, t) { print $NF }' \
        | while read -r handle; do
            nft delete rule ip hydrix-lan prerouting handle "$handle"
          done
    }

    remove_port_forward() {
      remove_rules "$1" "$2"
      state --arg cid "$1" --arg port "$2" \
        '.portForwards = [.portForwards[] | select(.cid != $cid or .port != $port)]'
      log "Forward removed: port $2 (CID $1)"
      echo "OK: port $2 no longer forwarded to CID $1"
    }

    # The router firewall reload recreates lan_access with only its defaults
    sync() {
      local cid
      for cid in $(jq -r '.enabledVMs[].cid' "$STATE_FILE"); do
        (lookup_net "$cid" && grant "$TAP") || true
      done
    }

    show_status() {
      local wan
      wan=$(wan_iface)
      echo "=== LAN Access Status ==="
      echo "Uplink:      ''${wan:-none} ($(ip -4 -o addr show dev "$wan" 2>/dev/null | awk '{print $4; exit}'))"
      echo "Uplink LAN:  $(wan_lan "$wan")"
      echo ""
      echo "LAN access (CID -> LAN):"
      jq -r '.enabledVMs[] | "  " + .cid + " -> " + .lan' "$STATE_FILE"
      echo "Port forwards:"
      jq -r '.portForwards[] | "  " + .port + " -> " + .ip + " (CID " + .cid + ")"' "$STATE_FILE"
      echo ""
      echo "Firewall lan_access set:"
      nft list set inet router lan_access 2>/dev/null | awk '/elements/' | sed 's/^\s*/  /'
    }

    mkdir -p ${stateDir}
    [ -s "$STATE_FILE" ] || echo '{"enabledVMs":[],"portForwards":[]}' > "$STATE_FILE"

    read -r cmd arg1 arg2 arg3 || true
    case "''${cmd:-}" in
      ENABLE_LAN)  enable_lan "''${arg1:?CID required}" ;;
      DISABLE_LAN) disable_lan "''${arg1:?CID required}" ;;
      PORT_ADD)    add_port_forward "''${arg1:?CID required}" "''${arg2:?port required}" "''${arg3:-}" ;;
      PORT_REMOVE) lookup_net "''${arg1:?CID required}"; remove_port_forward "$arg1" "''${arg2:?port required}" ;;
      SYNC)        sync; echo "OK" ;;
      LAN_STATUS|STATUS) show_status ;;
      PING)        echo "OK" ;;
      *) echo "Unknown: ''${cmd:-}"; echo "Commands: ENABLE_LAN, DISABLE_LAN, PORT_ADD, PORT_REMOVE, SYNC, LAN_STATUS, PING" ;;
    esac
  '';
in {
  options.hydrix.router.lanControl.forwards = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        cid = lib.mkOption {
          type = lib.types.int;
          description = "Network of the target VM (CID = subnet third octet).";
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "Uplink TCP port, forwarded to the same port on the VM.";
        };
        ip = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Target address; null means the VM's static <subnet>.<cid>.";
        };
      };
    });
    default = [];
    example = [
      {
        cid = 107;
        port = 8096;
      }
    ];
    description = ''
      Uplink TCP ports forwarded to VMs from boot, so devices on the router
      uplink's LAN can reach a service in a VM (e.g. a media server). Same
      mechanism as `pentest-lan forward add`; replies route back via the main
      table, so the target may be VPN-routed.
    '';
  };

  config = {
    environment.systemPackages = [lanControlBin];

    # Re-grant LAN access whenever the router firewall (re)loads its table
    systemd.services.router-lan-control = {
      description = "Restore LAN access grants after a router firewall load";
      wantedBy = ["multi-user.target" "router-firewall.service"];
      after = ["router-firewall.service"];
      partOf = ["router-firewall.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "echo SYNC | ${lanControlBin}/bin/router-lan-control";
    };

    # Vsock server on port 14516
    systemd.services.lan-control-server = {
      description = "LAN control vsock server (port 14516)";
      wantedBy = ["multi-user.target"];
      after = ["router-lan-control.service"];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:${toString config.hydrix.networking.vsockPorts.lanControl},reuseaddr,fork EXEC:${lanControlBin}/bin/router-lan-control";
        Restart = "always";
      };
    };

    systemd.services.router-lan-forwards = lib.mkIf (config.hydrix.router.lanControl.forwards != []) {
      description = "Apply declared uplink port forwards";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target" "router-lan-control.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # PORT_ADD needs the uplink; WiFi may still be associating after boot
      script =
        lib.concatMapStrings (f: ''
          for _ in $(seq 60); do
            echo "PORT_ADD ${toString f.cid} ${toString f.port} ${lib.optionalString (f.ip != null) f.ip}" \
              | ${lanControlBin}/bin/router-lan-control | tee /dev/stderr | grep -q '^OK' && break
            sleep 2
          done
        '')
        config.hydrix.router.lanControl.forwards;
    };
  };
}
