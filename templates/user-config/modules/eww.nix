# modules/eww.nix: eww widget daemon + left-half desktop dashboard
#
# One `dashboard` window per monitor (id `dashboard-<output>`), filling the
# left half of the screen below waybar, inset by the Hyprland gap so block
# edges line up with tiled windows. Two columns of blocks, each expanding to
# share its column's height:
#
#   VMS         running/stopped VMs (parses `shard status`)
#   EXIT NODES  WireGuard exit node per running VM; click a row to route that
#               VM direct or back through its tunnel (router VPNSET command)
#   NETWORK     SSID, unsaved count, WAN + per-VM bandwidth
#   TRAFFIC     2 minute graph of combined throughput across all bridges
#   GIT         working-tree state of hydrix-config, hydrix.repos.entries and
#               dashboard.git.extraRepos (local only, fine in lockdown mode)
#   TODO        ~/.local/share/hydrix/todo.txt; click to tick, `todo` to edit
#   WEATHER     dashboard.weather.locations, fetched by the router VM since the
#               host has no internet in lockdown mode (router WEATHER command)
#   CPU         2 minute usage graph, load average
#
# TRAFFIC and CPU have the same fixed shape and close their columns, so the
# two graphs line up; the text blocks above them take the spare height.
#
# Router data comes from router-stats-server on vsock 200:14506. Colors come
# from ~/.cache/wal/colors.scss; fonts and geometry from hydrix.graphical.
#
# Optional wallpaper-layer window (hydrix.eww.wallpaperLayer): a full-monitor
# window stacked between swaybg/hyprpaper and normal apps. `image` is an
# absolute filesystem path (read at runtime, not copied into the Nix store,
# same convention as hydrix.greetd.background) to an alpha-cutout PNG:
# background erased to transparent, foreground element left in place. It's
# pinned at a fixed screen corner via `halign`/`valign`, independent of the
# backing wallpaper walrgb/randomwalrgb sets underneath.
#
# `title`/`caption` overlay two text labels on the cutout, each pinned at an
# absolute (x, y) in logical screen px from the top-left corner (`slurp -p`
# reads coordinates off the screen). The window is anchored "bottom left",
# not "top left": anchoring top would make Hyprland push it down below
# waybar's exclusive zone. screenWidth/screenHeight is the Hyprland logical
# resolution (physical size / scale), see `hyprctl layers` if unsure.
#
# eww cannot make a window click-through, so the wallpaper layer takes input
# over the whole screen. eww-dashboard-watch therefore always maps it first
# and the dashboards after it, and re-maps the dashboards whenever Hyprland
# reloads its config (which can reorder layer surfaces).
#
# Gated on hydrix.hyprland.enable: host-only, no VM usage.
#
{
  config,
  lib,
  pkgs,
  ...
}: let
  username = config.hydrix.username;
  ui = config.hydrix.graphical.ui;
  gaps = let
    v = ui.gaps or null;
  in
    if v != null
    then v
    else 10;
  fontFamily = config.hydrix.graphical.font.family or "Iosevka";
  fontSize = let
    base = config.hydrix.graphical.font.size or 10;
    relation = config.hydrix.graphical.font.relations.eww or 1.0;
  in
    builtins.floor (base * relation);

  cfg = config.hydrix.eww.wallpaperLayer;
  wlEnabled = cfg.enable && cfg.image != null;
  dash = config.hydrix.eww.dashboard;

  # Same "scale pillRadius up so it reads as visibly rounded" formula as
  # wofi's #window (theming/wm/hyprland/wofi.nix): blocks are the same kind
  # of floating rounded surface, not waybar pills.
  panelRadius = let
    pillRadius =
      if (ui.pillRadius or null) != null
      then ui.pillRadius
      else builtins.floor ((ui.cornerRadius or 2) * (ui.pillRadiusScale or 2.0));
  in
    toString (pillRadius * 2);
  panelOpacity = toString (ui.opacity.overlayOverrides.eww or ui.opacity.overlay);
  blockPadding = let
    p = ui.padding or 8;
  in "${toString (p + 6)}px ${toString (p + 10)}px";

  routerAllCache = "/tmp/hydrix-eww-router-all.json";
  vmStatusCache = "/tmp/hydrix-eww-vm-status.json";
  todoFile = "$HOME/.local/share/hydrix/todo.txt";

  # name|path per line. hydrix-config first, then extras, then declared repos.
  gitReposFile = pkgs.writeText "eww-git-repos" (lib.concatMapStrings (r: "${r.name}|${r.path}\n") (
    [
      {
        name = baseNameOf config.hydrix.paths.configDir;
        path = config.hydrix.paths.configDir;
      }
    ]
    ++ lib.mapAttrsToList (name: path: {inherit name path;}) dash.git.extraRepos
    ++ lib.optionals (config.hydrix.repos.enable or false) (lib.mapAttrsToList (_: e: {
        name = baseNameOf e.path;
        inherit (e) path;
      })
      config.hydrix.repos.entries)
  ));

  weatherLocationsFile = pkgs.writeText "eww-weather-locations" (lib.concatMapStrings (
      l: "${l.name}|${toString l.latitude}|${toString l.longitude}\n"
    )
    dash.weather.locations);

  # Single-shot fetcher: one ALL connection to router-stats-server pulls
  # wifi+net+wg+vpn together and caches the combined result, so the exit-node
  # and network widgets reuse it instead of opening their own connections.
  ewwRouterStats = pkgs.writeShellApplication {
    name = "eww-router-stats";
    runtimeInputs = [pkgs.socat pkgs.jq];
    text = ''
      all=$(printf 'ALL\n' | socat -T3 - VSOCK-CONNECT:200:14506 2>/dev/null || true)
      if [ -z "$all" ]; then
        echo '{"current":"","connections":[],"pending":0}'
        exit 0
      fi
      printf '%s' "$all" > "${routerAllCache}.tmp" && mv "${routerAllCache}.tmp" "${routerAllCache}"
      pending=$(wifi-sync count 2>/dev/null || echo 0)
      echo "$all" | jq --argjson p "$pending" '.wifi + {"pending": $p}'
    '';
  };

  # Exit nodes for running VMs: one entry per VM with a wg-<vm> tunnel on the
  # router, plus whether the VM is currently routed through it ("vpn":
  # on/off/blocked, from vpn-assign's assignments). Reuses the ALL snapshot
  # and eww-mvm-status's running-VM cache, so it opens no connection of its
  # own while those are fresh.
  ewwWgStatus = pkgs.writeShellApplication {
    name = "eww-wg-status";
    runtimeInputs = [pkgs.socat pkgs.jq pkgs.coreutils];
    text = ''
      all=""
      if [ -f "${routerAllCache}" ] && [ $(( $(date +%s) - $(stat -c %Y "${routerAllCache}") )) -lt 15 ]; then
        all=$(cat "${routerAllCache}")
      fi
      [ -n "$all" ] || all=$(printf 'ALL\n' | socat -T3 - VSOCK-CONNECT:200:14506 2>/dev/null || true)
      [ -n "$all" ] || { echo "[]"; exit 0; }

      running=$(jq -c '[.running[].name]' "${vmStatusCache}" 2>/dev/null || echo '[]')

      jq -c --argjson running "$running" '
        def bytes: if . >= 1073741824 then "\(. / 1073741824 | floor)GB"
                   elif . >= 1048576 then "\(. / 1048576 | floor)MB"
                   elif . >= 1024 then "\(. / 1024 | floor)KB" else "\(.)B" end;
        def age: if . < 0 then "no hs" elif . < 60 then "\(.)s"
                 elif . < 3600 then "\(. / 60 | floor)m" else "\(. / 3600 | floor)h" end;
        (.vpn // {}) as $vpn
        | [.wg[]? | (.iface | ltrimstr("wg-")) as $vm | select($running | index($vm))
           | ($vpn[$vm] // "") as $a
           | {vm: $vm, endpoint, location: (if (.location // "") == "" then .endpoint else .location end),
              age: (.handshake | age), rx: (.rx | bytes), tx: (.tx | bytes),
              class: (if .handshake < 0 then "dead" elif .handshake < 180 then "active" else "stale" end),
              vpn: (if $a == "" or $a == .iface then "on" elif $a == "blocked" then "blocked" else "off" end)}]
      ' <<< "$all" 2>/dev/null || echo "[]"
    '';
  };

  # Exit-node row click: routes <vm> through its wg-<vm> tunnel (on) or
  # straight out the router's WAN (off), then refreshes the router snapshot
  # and the widget without waiting for the next poll.
  ewwVpnToggle = pkgs.writeShellApplication {
    name = "eww-vpn-toggle";
    runtimeInputs = [pkgs.socat pkgs.jq pkgs.eww pkgs.libnotify ewwRouterStats ewwWgStatus];
    bashOptions = ["nounset" "pipefail"];
    text = ''
      vm="$1" action="$2"
      resp=$(printf 'VPNSET\n%s %s\n' "$action" "$vm" | socat -T20 - VSOCK-CONNECT:200:14506 2>/dev/null || true)
      if ! jq -e '.ok' <<< "$resp" >/dev/null 2>&1; then
        err=$(jq -r '.error // "no response from router"' <<< "''${resp:-null}" 2>/dev/null)
        notify-send -u critical "VPN" "Failed to turn VPN $action for $vm: $err"
      fi
      eww update router_stats="$(eww-router-stats)" wg_nodes="$(eww-wg-status)"
    '';
  };

  # Parses `shard status` (NAME STATUS CID columns) and caches the result so
  # eww-wg-status can reuse the running-VM list.
  ewwMvmStatus = pkgs.writeShellApplication {
    name = "eww-mvm-status";
    runtimeInputs = [pkgs.jq pkgs.coreutils pkgs.gnused];
    text = ''
      shard=/run/current-system/sw/bin/shard
      registry="/etc/hydrix/vm-registry.json"

      running_json="[]"
      stopped_json="[]"

      if [ ! -x "$shard" ]; then
        echo '{"running":[],"stopped":[]}'
        exit 0
      fi

      while read -r name status cid; do
        case "$name" in microvm-*) ;; *) continue ;; esac
        short=$(jq -r --arg n "$name" 'to_entries[] | select(.value.vmName == $n) | .key' "$registry" 2>/dev/null | head -1)
        [ -z "$short" ] && short="''${name#microvm-}"
        case "$status" in
          running)
            ip="192.168.$cid.2"
            entry="{\"name\":\"$short\",\"ip\":\"$ip\"}"
            running_json=$(echo "$running_json" | jq --argjson e "$entry" '. + [$e]') ;;
          stopped)
            entry="{\"name\":\"$short\"}"
            stopped_json=$(echo "$stopped_json" | jq --argjson e "$entry" '. + [$e]') ;;
        esac
      done < <("$shard" status 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
        || true)

      result="{\"running\":$running_json,\"stopped\":$stopped_json}"
      printf '%s' "$result" > "${vmStatusCache}.tmp" && mv "${vmStatusCache}.tmp" "${vmStatusCache}"
      echo "$result"
    '';
  };

  # Reads /tmp/hydrix-gc-status, refreshed every 30min by the
  # hydrix-gc-check user timer (host/microvm/default.nix); never runs
  # `nix eval` itself, matching the waybar gc-status module.
  ewwGcStatus = pkgs.writeShellApplication {
    name = "eww-gc-status";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      cache="/tmp/hydrix-gc-status"
      if [ -f "$cache" ]; then
        cat "$cache"
      else
        echo '{"count":0,"names":[]}'
      fi
    '';
  };

  # Formats router NET stats (from the ALL snapshot when fresh), direction
  # normalised to the VM's perspective (router rx/tx -> VM up/down), plus
  # "total": combined throughput of every bridge row (each VM's down + up)
  # for the traffic graph.
  ewwNetStats = pkgs.writeShellApplication {
    name = "eww-net-stats";
    runtimeInputs = [pkgs.socat pkgs.jq pkgs.coreutils];
    text = ''
      empty='{"wan":{"iface":"","down":"","up":""},"vms":[],"total":0,"total_fmt":"0B/s"}'

      raw=""
      if [ -f "${routerAllCache}" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "${routerAllCache}" 2>/dev/null || echo 0) ))
        [ "$age" -lt 15 ] && raw=$(jq -c '.net' "${routerAllCache}" 2>/dev/null || true)
      fi
      [ -n "$raw" ] || raw=$(printf 'NET\n' | socat -T4 - VSOCK-CONNECT:200:14506 2>/dev/null || true)
      [ -n "$raw" ] || { echo "$empty"; exit 0; }

      jq -c '
        def fmt:
          if . >= 1048576 then "\(. / 1048576 | floor)MB/s"
          elif . >= 1024 then "\(. / 1024 | floor)KB/s"
          else "\(.)B/s"
          end;
        ([.vms[] | .rx + .tx] | add // 0) as $total
        | {wan: {iface: .wan.iface, down: (.wan.rx | fmt), up: (.wan.tx | fmt)},
           vms: [.vms[] | {vm: .vm, down: (.tx | fmt), up: (.rx | fmt)}],
           total: $total, total_fmt: ($total | fmt)}
      ' <<< "$raw" 2>/dev/null || echo "$empty"
    '';
  };

  # Working-tree summary per repo: staged/modified/untracked/conflicted
  # counts, ahead/behind upstream, commits ahead of the default branch when
  # on another branch, stashes. Purely local (upstream counts reflect the
  # last fetch). --no-optional-locks keeps polls from contending with git
  # commands run by hand.
  ewwGitStatus = pkgs.writeShellApplication {
    name = "eww-git-status";
    runtimeInputs = [pkgs.git pkgs.jq pkgs.gawk];
    bashOptions = ["nounset" "pipefail"];
    text = ''
      git_() { git --no-optional-locks -C "$path" "$@" 2>/dev/null; }

      while IFS='|' read -r name path; do
        case "$name" in ""|"#"*) continue ;; esac
        path="''${path/#\~/$HOME}"
        if ! git_ rev-parse --git-dir >/dev/null; then
          jq -nc --arg n "$name" '{name: $n, missing: true, branch: "", state: "missing", summary: "not cloned"}'
          continue
        fi

        git_ status --porcelain=v2 --branch | awk -v name="$name" '
          /^# branch.head /     { head = $3 }
          /^# branch.upstream / { upstream = $3 }
          /^# branch.ab /       { ahead = substr($3, 2) + 0; behind = substr($4, 2) + 0 }
          /^[12] / { x = substr($2, 1, 1); y = substr($2, 2, 1)
                     if (x != ".") staged++
                     if (y != ".") modified++ }
          /^u /    { conflicts++ }
          /^\? /   { untracked++ }
          END {
            printf "%s\037%s\037%s\037%d\037%d\037%d\037%d\037%d\037%d\n", name, head, upstream,
              staged, modified, untracked, conflicts, ahead, behind
          }' | {
          IFS=$'\037' read -r n head upstream staged modified untracked conflicts ahead behind

          # Default branch: origin/HEAD if set, else whichever of main/master exists.
          def=$(git_ symbolic-ref --short refs/remotes/origin/HEAD)
          def="''${def#origin/}"
          if [ -z "$def" ]; then
            for b in main master; do
              git_ show-ref --verify --quiet "refs/heads/$b" && { def=$b; break; }
            done
          fi
          ahead_main=0
          if [ -n "$def" ] && [ "$head" != "$def" ] && [ "$head" != "(detached)" ]; then
            ahead_main=$(git_ rev-list --count "$def..HEAD" || echo 0)
          fi
          stashes=$(git_ rev-list --walk-reflogs --count refs/stash || echo 0)

          jq -nc --arg name "$n" --arg branch "$head" --arg def "$def" \
            --argjson upstream "$([ -n "$upstream" ] && echo true || echo false)" \
            --argjson staged "$staged" --argjson modified "$modified" \
            --argjson untracked "$untracked" --argjson conflicts "$conflicts" \
            --argjson ahead "$ahead" --argjson behind "$behind" \
            --argjson ahead_main "''${ahead_main:-0}" --argjson stashes "''${stashes:-0}" '
            {name: $name, missing: false, branch: $branch, default: $def, upstream: $upstream,
             staged: $staged, modified: $modified, untracked: $untracked, conflicts: $conflicts,
             ahead: $ahead, behind: $behind, ahead_main: $ahead_main, stashes: $stashes}
            | .dirty = (.staged + .modified + .untracked + .conflicts > 0)
            | .state = (if .conflicts > 0 then "conflict" elif .dirty then "dirty"
                        elif .ahead > 0 or .behind > 0 then "diverged" else "clean" end)
            | .summary = ([
                (if .conflicts > 0 then "\(.conflicts) conflicted" else empty end),
                (if .staged > 0 then "\(.staged) staged" else empty end),
                (if .modified > 0 then "\(.modified) modified" else empty end),
                (if .untracked > 0 then "\(.untracked) untracked" else empty end),
                (if .ahead > 0 then "\(.ahead) ahead" else empty end),
                (if .behind > 0 then "\(.behind) behind" else empty end),
                (if .ahead_main > 0 then "\(.ahead_main) ahead of \(.default)" else empty end),
                (if .stashes > 0 then "\(.stashes) stashed" else empty end)
              ] | if length == 0 then "clean" else join(" · ") end)'
        }
      done < ${gitReposFile} | jq -sc '.'
    '';
  };

  # Current conditions + today/next two days per location. The host has no
  # internet in lockdown mode, so the router VM fetches the forecast
  # (WEATHER command); a direct request covers fallback mode, where no router
  # runs. Cached for 15 minutes; the last good result is shown (flagged
  # stale) when neither path works.
  ewwWeather = pkgs.writeShellApplication {
    name = "eww-weather";
    runtimeInputs = [pkgs.socat pkgs.jq pkgs.curl pkgs.coreutils];
    bashOptions = ["nounset" "pipefail"];
    text = ''
      cache="''${XDG_CACHE_HOME:-$HOME/.cache}/hydrix/eww-weather-raw.json"
      mkdir -p "$(dirname "$cache")"
      ttl=900

      names=() lats=() lons=()
      while IFS='|' read -r name lat lon; do
        names+=("$name"); lats+=("$lat"); lons+=("$lon")
      done < ${weatherLocationsFile}
      [ ''${#names[@]} -gt 0 ] || { echo '{"stale":false,"locations":[]}'; exit 0; }

      join() { local IFS=,; echo "$*"; }
      query="$(join "''${lats[@]}") $(join "''${lons[@]}")"
      now=$(date +%s)

      # Envelope {query, fetched, data} as cached; empty if missing or for other coordinates.
      cached() { jq -ce --arg q "$query" 'select(.query == $q and .data != null)' "$cache" 2>/dev/null; }
      fetched_at() { local t; t=$(jq -r '.fetched // 0' <<< "$1" 2>/dev/null); echo "''${t:-0}"; }
      save() { printf '%s' "$1" > "$cache.tmp" && mv "$cache.tmp" "$cache"; }

      env=$(cached || true)
      if [ -z "$env" ] || [ $(( now - $(fetched_at "$env") )) -ge $ttl ]; then
        resp=$(printf 'WEATHER\n%s\n' "$query" | socat -T3 - VSOCK-CONNECT:200:14506 2>/dev/null || true)
        if jq -e --arg q "$query" '.query == $q and .data != null' <<< "$resp" >/dev/null 2>&1 \
           && [ "$(fetched_at "$resp")" -gt "$(fetched_at "$env")" ]; then
          save "$resp"
        else
          data=$(curl -sf -m 5 "https://api.open-meteo.com/v1/forecast?latitude=''${query% *}&longitude=''${query#* }&current=temperature_2m,weather_code,is_day&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=3&timezone=auto" || true)
          [ -n "$data" ] && save "$(jq -c --arg q "$query" --argjson t "$now" '{query: $q, fetched: $t, data: .}' <<< "$data")"
        fi
        env=$(cached || true)
      fi

      [ -n "$env" ] || { echo '{"stale":true,"locations":[]}'; exit 0; }

      jq -c --argjson names "$(printf '%s\n' "''${names[@]}" | jq -Rn '[inputs]')" --argjson now "$now" --argjson ttl "$ttl" '
        # WMO weather code -> [glyph, short text, css class]
        def wmo(day):
          if   . == 0 then [(if day then "☀" else "☾" end), "clear", (if day then "sun" else "night" end)]
          elif . == 1 then [(if day then "☀" else "☾" end), "mostly clear", (if day then "sun" else "night" end)]
          elif . == 2 then ["☁", "partly cloudy", "cloud"]
          elif . == 3 then ["☁", "overcast", "cloud"]
          elif . <= 48 then ["≋", "fog", "fog"]
          elif . <= 57 then ["☂", "drizzle", "rain"]
          elif . <= 67 then ["☂", "rain", "rain"]
          elif . <= 77 then ["❄", "snow", "snow"]
          elif . <= 82 then ["☂", "showers", "rain"]
          elif . <= 86 then ["❄", "snow showers", "snow"]
          else ["⚡", "thunder", "storm"] end;
        def deg: round | (if . == 0 then 0 else . end) | tostring + "°";
        .fetched as $t
        | (.data | if type == "array" then . else [.] end) as $all
        | {stale: (($now - $t) > 3 * $ttl),
           locations: [range(0; $all | length) as $i | $all[$i] as $l
            | ($l.current.weather_code | wmo($l.current.is_day == 1)) as $c
            | {name: $names[$i], temp: ($l.current.temperature_2m | deg),
               icon: $c[0], desc: $c[1], class: $c[2],
               days: [range(0; 3) as $d
                 | ($l.daily.weather_code[$d] | wmo(true)) as $w
                 | {day: (if $d == 0 then "today"
                          else $l.daily.time[$d] | strptime("%Y-%m-%d") | strftime("%a") | ascii_downcase end),
                    align: (["start", "center", "end"][$d]),
                    icon: $w[0], class: $w[2],
                    hi: ($l.daily.temperature_2m_max[$d] | deg),
                    lo: ($l.daily.temperature_2m_min[$d] | deg)}]}]}
      ' <<< "$env"
    '';
  };

  # Plain-text TODO list shared with the dashboard's todo block. One item
  # per line: "[ ] text" or "[x] text". Item numbers are 1-based.
  todo = pkgs.writeShellApplication {
    name = "todo";
    runtimeInputs = [pkgs.fzf pkgs.jq pkgs.gawk pkgs.coreutils pkgs.gnugrep pkgs.bash];
    excludeShellChecks = ["SC2016"];
    text = ''
      file="${todoFile}"
      mkdir -p "$(dirname "$file")"
      [ -f "$file" ] || : > "$file"
      self=$(readlink -f "$0")

      count() { grep -c "" "$file" || true; }

      valid() {
        [[ "''${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "$(count)" ] \
          || { echo "todo: no item: ''${1:-}" >&2; exit 1; }
      }

      # Rewrite through a temp file + rename so readers never see a half-written list.
      apply() {
        local tmp="$file.tmp.$$"
        awk "$@" "$file" > "$tmp" && mv "$tmp" "$file"
      }

      usage() {
        cat <<USAGE
      usage: todo                 interactive editor
             todo ls              list items
             todo add TEXT...     append an item
             todo toggle N        tick/untick item N
             todo edit N TEXT...  replace the text of item N
             todo rm N            delete item N
             todo mv N M          move item N to position M
             todo clear           delete all ticked items
             todo json            items as JSON (eww widget)
      USAGE
      }

      tui() {
        SHELL=$(command -v bash)
        export SHELL
        local help='type+enter add · enter tick · ctrl-r rename · ctrl-d delete
      shift-up/down move · ctrl-x clear done · ctrl-e $EDITOR · esc quit'
        "$self" _fzf | fzf \
          --disabled --no-sort --ansi --cycle --layout=reverse --border=rounded \
          --border-label=' todo ' --prompt='new> ' --info=hidden --pointer='>' \
          --header="$help" --header-first \
          --bind "enter:execute-silent($self _enter {q} {n})+clear-query+reload($self _fzf)" \
          --bind "ctrl-r:execute-silent([ -n {q} ] && $self edit \$(({n}+1)) {q})+clear-query+reload($self _fzf)" \
          --bind "ctrl-d:execute-silent($self rm \$(({n}+1)))+reload($self _fzf)" \
          --bind "shift-up:execute-silent($self mv \$(({n}+1)) {n})+reload($self _fzf)+up" \
          --bind "shift-down:execute-silent($self mv \$(({n}+1)) \$(({n}+2)))+reload($self _fzf)+down" \
          --bind "ctrl-x:execute-silent($self clear)+reload($self _fzf)" \
          --bind "ctrl-e:execute(\''${EDITOR:-vi} $file)+reload($self _fzf)" \
          --bind 'esc:abort,ctrl-c:abort' \
          >/dev/null || true
      }

      cmd="''${1:-}"; [ $# -gt 0 ] && shift
      case "$cmd" in
        "") tui ;;
        ls)
          awk '{ printf "%3d %s\n", NR, $0 }' "$file" ;;
        add)
          [ $# -gt 0 ] || { usage >&2; exit 1; }
          printf '[ ] %s\n' "$*" >> "$file" ;;
        toggle)
          valid "''${1:-}"
          apply -v n="$1" 'NR==n { if (sub(/^\[x\]/, "[ ]") == 0) sub(/^\[ \]/, "[x]") } 1' ;;
        edit)
          valid "''${1:-}"; n=$1; shift
          [ $# -gt 0 ] || { usage >&2; exit 1; }
          TODO_TEXT="$*" apply -v n="$n" 'NR==n { $0 = substr($0, 1, 4) ENVIRON["TODO_TEXT"] } 1' ;;
        rm)
          valid "''${1:-}"
          apply -v n="$1" 'NR!=n' ;;
        mv)
          valid "''${1:-}"; from=$1; to=''${2:-}
          [[ "$to" =~ ^[0-9]+$ ]] || exit 0
          total=$(count); [ "$to" -lt 1 ] && to=1; [ "$to" -gt "$total" ] && to=$total
          apply -v f="$from" -v t="$to" '
            { l[NR] = $0 } NR==f { m = $0 }
            END {
              j = 0
              for (i = 1; i <= NR; i++) { if (i == f) continue; o[++j] = l[i] }
              for (i = 1; i <= NR; i++) {
                if (i == t) print m
                if (i <= j) print o[i]
              }
            }' ;;
        clear)
          apply '!/^\[x\]/' ;;
        json)
          jq -Rnc '[inputs | select(length > 0)] | to_entries
            | map({i: (.key + 1), done: (.value | startswith("[x]")), text: .value[4:]})' < "$file" ;;
        _enter)
          # fzf enter: add the typed query if there is one, else tick the cursor item.
          if [ -n "''${1:-}" ]; then "$self" add "$1"
          elif [ -n "''${2:-}" ]; then "$self" toggle "$(( $2 + 1 ))"
          fi ;;
        _fzf)
          awk '{
            done = ($0 ~ /^\[x\]/); t = substr($0, 5)
            if (done) printf "\033[2m[x] %s\033[0m\n", t
            else      printf "[ ] %s\n", t
          }' "$file" ;;
        -h|--help|help) usage ;;
        *) usage >&2; exit 1 ;;
      esac
    '';
  };

  # deflisten source for the todo block: emits the list as JSON on start and
  # whenever the todo file is written or replaced (todo, the TUI, editors).
  ewwTodoListen = pkgs.writeShellApplication {
    name = "eww-todo-listen";
    runtimeInputs = [pkgs.inotify-tools pkgs.coreutils todo];
    text = ''
      file="${todoFile}"
      dir=$(dirname "$file")
      mkdir -p "$dir"
      todo json
      inotifywait -m -q -e close_write,moved_to,create,delete --format '%f' "$dir" \
        | while IFS= read -r f; do
            [ "$f" = "$(basename "$file")" ] && { todo json 2>/dev/null || echo '[]'; }
          done
    '';
  };

  # Opens the wallpaper layer (if enabled) and then one dashboard per
  # monitor (or per internal panel, see dashboard.monitors), sized to the
  # left half of that monitor below its reserved zones. Re-syncs on monitor hotplug and re-maps the dashboards on
  # Hyprland config reloads so they stay above the wallpaper layer (see top).
  # Debounced like waybarMonitorWatch in modules/hyprland.nix.
  ewwDashboardWatch = pkgs.writeShellApplication {
    name = "eww-dashboard-watch";
    runtimeInputs = [pkgs.eww pkgs.hyprland pkgs.jq pkgs.socat pkgs.gnugrep pkgs.coreutils];
    text = ''
      sync_dashboards() {
        mons=$(hyprctl monitors -j)
        eww active-windows 2>/dev/null | grep '^dashboard-' | while IFS=: read -r wid _; do
          eww close "$wid" 2>/dev/null || true
        done || true
        jq -r '.[] ${lib.optionalString (dash.monitors == "internal") "| select(.name | test(\"^(eDP|LVDS|DSI)-\")) "}| "\(.name) \(.width / .scale | floor) \(.height / .scale | floor) \(.reserved[1]) \(.reserved[3])"' <<< "$mons" \
          | while read -r mon w h top bottom; do
              eww open dashboard --id "dashboard-$mon" --screen "$mon" \
                --arg width="$(( w / 2 - 2 * ${toString gaps} ))" \
                --arg height="$(( h - top - bottom - ${toString gaps} ))" 2>/dev/null || true
            done
      }

      sleep 3
      eww close-all 2>/dev/null || true
      ${lib.optionalString wlEnabled ''eww open wallpaper-layer 2>/dev/null || true''}
      sync_dashboards

      _sock="''${XDG_RUNTIME_DIR}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
      [ -S "$_sock" ] || exit 1
      _seq="''${XDG_RUNTIME_DIR}/eww-dashboard-watch-seq"
      echo 0 > "$_seq"
      socat -u "UNIX-CONNECT:$_sock" - | while IFS= read -r line; do
        case "$line" in
          monitoradded*|monitorremoved*|configreloaded*)
            _n=$(( $(cat "$_seq") + 1 ))
            echo "$_n" > "$_seq"
            _my=$_n
            ( sleep 1
              [ "$(cat "$_seq" 2>/dev/null)" = "$_my" ] || exit 0
              sync_dashboards
            ) &
            ;;
        esac
      done
    '';
  };

  ewwYuck =
    ''
      (defpoll wg_nodes
        :interval "10s"
        :initial "[]"
        `eww-wg-status`)

      (defpoll vm_status
        :interval "10s"
        :initial "{\"running\":[],\"stopped\":[]}"
        `eww-mvm-status`)

      (defpoll router_stats
        :interval "10s"
        :initial "{\"current\":\"\",\"connections\":[],\"pending\":0}"
        `eww-router-stats`)

      (defpoll net_stats
        :interval "10s"
        :initial "{\"wan\":{\"iface\":\"\",\"down\":\"\",\"up\":\"\"},\"vms\":[],\"total\":0,\"total_fmt\":\"0B/s\"}"
        `eww-net-stats`)

      (defpoll gc_status
        :interval "10s"
        :initial "{\"count\":0,\"names\":[]}"
        `eww-gc-status`)

      (defpoll loadavg
        :interval "5s"
        :initial "0.00 0.00 0.00"
        `cut -d' ' -f1-3 /proc/loadavg`)

      (deflisten todos
        :initial "[]"
        `eww-todo-listen`)

      (defpoll git_repos
        :interval "30s"
        :initial "[]"
        `eww-git-status`)

      (defpoll weather
        :interval "60s"
        :initial "{\"stale\":false,\"locations\":[]}"
        `eww-weather`)

      ;; Sized per monitor by eww-dashboard-watch (left half, below waybar).
      (defwindow dashboard [width height]
        :monitor 0
        :geometry (geometry
          :x "${toString gaps}px"
          :y "0px"
          :width "''${width}px"
          :height "''${height}px"
          :anchor "top left")
        :exclusive false
        :stacking "bottom"
        :focusable false
        (dashboard))

      (defwidget dashboard []
        (box
          :orientation "h"
          :space-evenly true
          :spacing ${toString gaps}
          (dash-column (vm-status-widget) (exit-nodes-widget) (router-widget) (traffic-widget))
          (dash-column (git-widget) (todo-widget) (weather-widget) (cpu-widget))))

      (defwidget dash-column []
        (box
          :orientation "v"
          :space-evenly false
          :spacing ${toString gaps}
          (children)))

      (defwidget block-title [text ?aside]
        (box
          :orientation "h"
          :space-evenly false
          (label
            :class "title"
            :text text
            :hexpand true
            :halign "start")
          (label
            :class "title-aside"
            :visible {aside != ""}
            :text {aside ?: ""})))

      (defwidget vm-status-widget []
        (box
          :class "block"
          :vexpand true
          :orientation "v"
          :space-evenly false
          :visible {arraylength(vm_status.running) > 0 || gc_status.count > 0}
          (block-title :text "VMS")
          (label
            :class {gc_status.count > 0 ? "vs-pending unsaved" : "vs-pending"}
            :visible {gc_status.count > 0}
            :text {"+" + gc_status.count + " orphaned (shard gc)"}
            :halign "start")
          (for vm in {vm_status.running}
            (vm-row-running :vm vm))
          (for vm in {vm_status.stopped}
            (vm-row-stopped :vm vm))))

      (defwidget vm-row-running [vm]
        (box
          :class "vm-row"
          :orientation "h"
          :space-evenly false
          :spacing 6
          (label
            :class "vm-dot running"
            :text "●")
          (label
            :class "vm-name"
            :text {vm.name}
            :hexpand true
            :halign "start")
          (label
            :class "vm-ip"
            :text {vm.ip})))

      (defwidget vm-row-stopped [vm]
        (box
          :class "vm-row stopped"
          :orientation "h"
          :space-evenly false
          :spacing 6
          (label
            :class "vm-dot stopped"
            :text "○")
          (label
            :class "vm-name stopped"
            :text {vm.name}
            :hexpand true
            :halign "start")))

      (defwidget exit-nodes-widget []
        (box
          :class "block"
          :vexpand true
          :orientation "v"
          :space-evenly false
          :visible {router_stats.current != "" || arraylength(vm_status.running) > 0 || gc_status.count > 0}
          (block-title :text "EXIT NODES")
          (label
            :class "node-meta"
            :visible {arraylength(wg_nodes) == 0}
            :text "none active"
            :halign "start")
          (for node in wg_nodes
            (node-row :node node))))

      ;; Click toggles the VM between its exit node and direct WAN routing.
      (defwidget node-row [node]
        (eventbox
          :class "node-row"
          :cursor "pointer"
          :tooltip {node.vpn == "on" ? "click: route ''${node.vm} direct (VPN off)" : "click: route ''${node.vm} through its exit node"}
          :onclick "eww-vpn-toggle ''${node.vm} ''${node.vpn == 'on' ? 'off' : 'on'} &"
          (box
            :orientation "v"
            :space-evenly false
            (box
              :orientation "h"
              :space-evenly false
              :spacing 6
              (label
                :class "node-dot ''${node.vpn == 'on' ? node.class : node.vpn}"
                :text {node.vpn == "on" && node.class == "active" ? "●" : "○"})
              (label
                :class "node-vm ''${node.vpn}"
                :text {node.vm}
                :hexpand true
                :halign "start")
              (label
                :class "node-ep ''${node.vpn == 'on' ? node.class : node.vpn}"
                :text {node.vpn == "on" ? node.location : node.vpn == "blocked" ? "blocked" : "vpn off · direct"}))
            (label
              :class "node-meta"
              :text {(node.location == node.endpoint ? "" : node.endpoint + "   ") + node.age + "   " + node.rx + "↓  " + node.tx + "↑  total"}
              :halign "start"))))

      (defwidget router-widget []
        (box
          :class "block"
          :vexpand true
          :orientation "v"
          :space-evenly false
          :visible {router_stats.current != ""}
          (block-title
            :text "NETWORK"
            :aside {router_stats.current})
          (label
            :class {router_stats.pending > 0 ? "rs-pending unsaved" : "rs-pending"}
            :visible {router_stats.pending > 0}
            :text {"+" + router_stats.pending + " unsaved"}
            :halign "start")
          (net-wan-row :stats {net_stats.wan})
          (for vm in {net_stats.vms}
            (net-vm-row :vm vm))))

      (defwidget net-wan-row [stats]
        (box
          :class "net-row wan-row"
          :orientation "h"
          :space-evenly false
          :spacing 6
          (label
            :class "net-iface"
            :text {stats.iface}
            :hexpand true
            :halign "start")
          (label
            :class "net-down"
            :text {stats.down + "↓"})
          (label
            :class "net-up"
            :text {stats.up + "↑"})))

      (defwidget net-vm-row [vm]
        (box
          :class "net-row"
          :orientation "h"
          :space-evenly false
          :spacing 6
          (label
            :class "net-vm"
            :text {vm.vm}
            :hexpand true
            :halign "start")
          (label
            :class "net-down"
            :text {vm.down + "↓"})
          (label
            :class "net-up"
            :text {vm.up + "↑"})))

      ;; Combined throughput of every bridge in the NETWORK block, auto-scaled
      ;; to its own recent peak. Same shape as cpu-widget so the graphs line up.
      (defwidget traffic-widget []
        (box
          :class "block"
          :orientation "v"
          :space-evenly false
          :visible {net_stats.wan.iface != ""}
          (block-title
            :text "TRAFFIC"
            :aside {"all " + arraylength(net_stats.vms) + " bridges, down + up · " + net_stats.total_fmt})
          (graph
            :class "graph net-graph"
            :height 90
            :value {net_stats.total}
            :min 0
            :dynamic true
            :time-range "120s"
            :thickness 1.5
            :line-style "round")))

      (defwidget cpu-widget []
        (box
          :class "block"
          :orientation "v"
          :space-evenly false
          (block-title
            :text "CPU"
            :aside {"load " + loadavg + " · " + arraylength(EWW_CPU.cores) + " threads · " + round(EWW_CPU.avg, 0) + "%"})
          (graph
            :class "graph cpu-graph"
            :height 90
            :value {EWW_CPU.avg}
            :min 0
            :max 100
            :dynamic false
            :time-range "120s"
            :thickness 1.5
            :line-style "round")))

      (defwidget git-widget []
        (box
          :class "block"
          :vexpand true
          :orientation "v"
          :space-evenly false
          :visible {arraylength(git_repos) > 0}
          (block-title
            :text "GIT"
            :aside {jq(git_repos, "map(select(.state != \"clean\")) | length") + " need attention"})
          (for repo in git_repos
            (box
              :class "git-repo"
              :orientation "v"
              :space-evenly false
              (box
                :orientation "h"
                :space-evenly false
                :spacing 6
                (label
                  :class "git-dot ''${repo.state}"
                  :text {repo.state == "clean" ? "●" : repo.state == "missing" ? "○" : "◆"})
                (label
                  :class "git-name ''${repo.state}"
                  :text {repo.name}
                  :hexpand true
                  :halign "start")
                (label
                  :class "git-branch"
                  :text {repo.branch}))
              (label
                :class "git-summary ''${repo.state}"
                :halign "start"
                :xalign 0
                :wrap true
                :text {repo.summary})))))

      (defwidget todo-widget []
        (box
          :class "block"
          :vexpand true
          :orientation "v"
          :space-evenly false
          (block-title
            :text "TODO"
            :aside {arraylength(todos) == 0 ? "" : jq(todos, "map(select(.done | not)) | length") + " open"})
          (label
            :class "todo-empty"
            :visible {arraylength(todos) == 0}
            :halign "start"
            :text "nothing to do")
          (for item in todos
            (eventbox
              :class "todo-item"
              :cursor "pointer"
              :onclick "todo toggle ''${item.i}"
              (box
                :orientation "h"
                :space-evenly false
                :spacing 6
                (label
                  :class "todo-box ''${item.done ? 'done' : '''}"
                  :valign "start"
                  :text {item.done ? "●" : "○"})
                (label
                  :class "todo-text ''${item.done ? 'done' : '''}"
                  :halign "start"
                  :hexpand true
                  :xalign 0
                  :wrap true
                  :text {item.text}))))))

      (defwidget weather-widget []
        (box
          :class "block"
          :vexpand true
          :orientation "v"
          :space-evenly false
          :visible {arraylength(weather.locations) > 0}
          (block-title
            :text "WEATHER"
            :aside {weather.stale ? "offline" : ""})
          (for loc in {weather.locations}
            (box
              :class "wx-loc"
              :orientation "v"
              :space-evenly false
              (box
                :orientation "h"
                :space-evenly false
                :spacing 6
                (label
                  :class "wx-name"
                  :text {loc.name}
                  :hexpand true
                  :halign "start")
                (label
                  :class "wx-desc"
                  :text {loc.desc})
                (label
                  :class "wx-icon ''${loc.class}"
                  :text {loc.icon})
                (label
                  :class "wx-temp"
                  :text {loc.temp}))
              (box
                :class "wx-days"
                :orientation "h"
                :space-evenly true
                (for day in {loc.days}
                  (box
                    :orientation "v"
                    :space-evenly false
                    :halign {day.align}
                    (label
                      :class "wx-day"
                      :halign {day.align}
                      :text {day.day})
                    (box
                      :orientation "h"
                      :space-evenly false
                      :halign {day.align}
                      :spacing 4
                      (label
                        :class "wx-icon ''${day.class}"
                        :text {day.icon})
                      (label
                        :class "wx-range"
                        :text {day.hi + "/" + day.lo})))))))))
    ''
    + lib.optionalString wlEnabled ''

      (defwindow wallpaper-layer
        :monitor 0
        :geometry (geometry
          :x "0px"
          :y "0px"
          :width "${toString cfg.screenWidth}px"
          :height "${toString cfg.screenHeight}px"
          :anchor "bottom left")
        :exclusive false
        :stacking "bottom"
        :focusable false
        (wallpaper-layer-content))

      (defwidget wallpaper-layer-content []
        (overlay
          (image
            :path "${cfg.image}"
            :image-width ${toString cfg.imageWidth}
            :image-height ${toString cfg.imageHeight}
            :halign "${cfg.halign}"
            :valign "${cfg.valign}")
    ''
    + lib.optionalString (wlEnabled && cfg.title.text != "") ''
      (label
        :class "wl-title"
        :halign "start"
        :valign "start"
        :text "${cfg.title.text}")
    ''
    + lib.optionalString (wlEnabled && cfg.caption.text != "") ''
      (label
        :class "wl-caption"
        :halign "start"
        :valign "start"
        :justify "left"
        :text "${cfg.caption.text}")
    ''
    + lib.optionalString wlEnabled ''
      ))
    '';

  ewwScss =
    ''
      @import "/home/${username}/.cache/wal/colors.scss";

      window {
        background-color: transparent;
      }

      * {
        font-family: "${fontFamily}", monospace;
        font-size: ${toString fontSize}pt;
        color: $foreground;
        background-color: transparent;
      }

      .block {
        background-color: rgba($color0, ${panelOpacity});
        border-radius: ${panelRadius}px;
        padding: ${blockPadding};
      }

      .title {
        font-weight: bold;
        color: $color4;
        letter-spacing: 0.06em;
        margin-bottom: 4px;
      }

      .title-aside {
        font-weight: bold;
        color: $foreground;
        margin-bottom: 4px;
      }

      /* vms */

      .vs-pending.unsaved {
        color: $color1;
      }

      .vm-row {
        margin-top: 3px;
      }

      .vm-dot {
        min-width: 14px;
      }
      .vm-dot.running { color: $color2; }
      .vm-dot.stopped { color: $color8; }

      .vm-name {
        font-weight: bold;
        color: $foreground;
      }
      .vm-name.stopped {
        color: $color8;
        font-weight: normal;
      }

      .vm-ip {
        color: $color8;
      }

      /* exit nodes */

      .node-row {
        margin-top: 4px;
      }

      .node-dot {
        min-width: 14px;
      }
      .node-dot.active,
      .node-ep.active    { color: $color2; }
      .node-dot.stale,
      .node-ep.stale     { color: $color3; }
      .node-dot.dead,
      .node-ep.dead      { color: $color1; }
      .node-dot.off,
      .node-ep.off       { color: $color8; }
      .node-dot.blocked,
      .node-ep.blocked   { color: $color1; }

      .node-vm {
        font-weight: bold;
        color: $foreground;
      }
      .node-vm.off {
        color: $color8;
      }
      .node-row:hover .node-vm {
        color: $color4;
      }

      .node-meta {
        color: $color8;
        margin-top: 1px;
      }

      /* network */

      .rs-pending.unsaved {
        color: $color1;
      }

      .net-row {
        margin-top: 3px;
      }

      .wan-row {
        margin-top: 4px;
      }

      .net-iface {
        font-weight: bold;
        color: $foreground;
      }

      .net-vm {
        color: $foreground;
      }

      .net-down {
        color: $color8;
        min-width: 70px;
      }

      .net-up {
        color: $color8;
      }

      /* cpu + traffic graphs */

      .graph {
        margin-top: 4px;
      }
      .cpu-graph,
      .net-graph {
        color: $color4;
        background-color: rgba($color4, 0.12);
      }


      /* git */

      .git-repo {
        margin-top: 4px;
      }
      .git-dot {
        min-width: 14px;
      }
      .git-dot.clean    { color: $color2; }
      .git-dot.diverged { color: $color4; }
      .git-dot.dirty    { color: $color3; }
      .git-dot.conflict { color: $color1; }
      .git-dot.missing  { color: $color8; }
      .git-name {
        font-weight: bold;
      }
      .git-name.missing {
        font-weight: normal;
        color: $color8;
      }
      .git-branch,
      .git-summary {
        color: $color8;
      }
      .git-summary {
        margin-left: 20px;
      }
      .git-summary.conflict {
        color: $color1;
      }

      /* todo */

      .todo-item {
        margin-top: 3px;
      }
      .todo-box {
        min-width: 14px;
        color: $color4;
      }
      .todo-box.done {
        color: $color8;
      }
      .todo-text.done {
        color: $color8;
        text-decoration-line: line-through;
      }
      .todo-item:hover .todo-text {
        color: $color4;
      }
      .todo-empty {
        color: $color8;
      }

      /* weather */

      .wx-loc {
        margin-top: 6px;
      }
      .wx-name {
        font-weight: bold;
      }
      .wx-desc,
      .wx-day,
      .wx-range {
        color: $color8;
      }
      .wx-temp {
        font-weight: bold;
      }
      .wx-days {
        margin-top: 2px;
      }
      .wx-icon.sun   { color: $color3; }
      .wx-icon.night { color: $color7; }
      .wx-icon.cloud { color: $foreground; }
      .wx-icon.fog   { color: $color8; }
      .wx-icon.rain  { color: $color4; }
      .wx-icon.snow  { color: $color7; }
      .wx-icon.storm { color: $color5; }
    ''
    + lib.optionalString wlEnabled ''

      .wl-title {
        font-family: "Iosevka Thin Extended";
        font-size: ${toString (fontSize * 4.4)}pt;
        color: $color4;
        letter-spacing: 0.06em;
        margin-left: ${toString cfg.title.x}px;
        margin-top: ${toString cfg.title.y}px;
      }

      .wl-caption {
        font-size: ${toString fontSize}pt;
        color: $foreground;
        margin-left: ${toString cfg.caption.x}px;
        margin-top: ${toString cfg.caption.y}px;
      }
    '';

  ewwYuckFile = pkgs.writeText "eww.yuck" ewwYuck;
  ewwScssFile = pkgs.writeText "eww.scss" ewwScss;
in {
  options.hydrix.eww = {
    dashboard = {
      weather.locations = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Label shown in the weather block.";
            };
            latitude = lib.mkOption {
              type = lib.types.float;
              description = "Latitude in decimal degrees.";
            };
            longitude = lib.mkOption {
              type = lib.types.float;
              description = "Longitude in decimal degrees.";
            };
          };
        });
        default = [];
        example = [
          {
            name = "Stockholm";
            latitude = 59.33;
            longitude = 18.07;
          }
        ];
        description = ''
          Locations for the dashboard's weather block (Open-Meteo, fetched
          through the router VM so it works in lockdown mode). The block is
          hidden when empty. Keep it to about ten locations: the router caps
          the coordinate list it accepts at 255 characters.
        '';
      };
      monitors = lib.mkOption {
        type = lib.types.enum ["all" "internal"];
        default = "internal";
        description = ''
          Which monitors get a dashboard: every connected output, or only
          internal panels (outputs named eDP-*, LVDS-* or DSI-*).
        '';
      };
      git.extraRepos = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = {Hydrix = "/home/user/Hydrix";};
        description = ''
          Extra repositories (label -> absolute path) for the dashboard's git
          block, on top of hydrix.paths.configDir and hydrix.repos.entries.
        '';
      };
    };

    wallpaperLayer = {
      enable = lib.mkEnableOption "wallpaper foreground-cutout overlay in eww";
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Absolute filesystem path to an alpha-cutout PNG (background erased
          to transparent), read at runtime, not copied into the Nix store, so
          replacing the file doesn't require a rebuild. Same convention as
          hydrix.greetd.background.
        '';
      };
      halign = lib.mkOption {
        type = lib.types.enum ["start" "center" "end" "fill"];
        default = "end";
        description = "Horizontal anchor for the cutout within the monitor.";
      };
      valign = lib.mkOption {
        type = lib.types.enum ["start" "center" "end" "fill"];
        default = "end";
        description = "Vertical anchor for the cutout within the monitor.";
      };
      screenWidth = lib.mkOption {
        type = lib.types.int;
        default = 1920;
        description = "Hyprland logical screen width (physical panel width / hyprInternalScale).";
      };
      screenHeight = lib.mkOption {
        type = lib.types.int;
        default = 1200;
        description = "Hyprland logical screen height (physical panel height / hyprInternalScale).";
      };
      imageWidth = lib.mkOption {
        type = lib.types.int;
        default = 1697;
        description = "Rendered width of the cutout in logical px (keep the source PNG's aspect ratio).";
      };
      imageHeight = lib.mkOption {
        type = lib.types.int;
        default = 1200;
        description = "Rendered height of the cutout in logical px (keep the source PNG's aspect ratio).";
      };
      title = {
        text = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Large bold title label overlaid on the cutout (empty disables it). Rendered at 4x the base font size.";
        };
        x = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "Horizontal position in logical px from the window's left edge (use `slurp -p` to pick a point).";
        };
        y = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "Vertical position in logical px from the window's top edge (use `slurp -p` to pick a point).";
        };
      };
      caption = {
        text = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Secondary caption label overlaid on the cutout (empty disables it). Rendered at the base font size.";
        };
        x = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "Horizontal position in logical px from the window's left edge (use `slurp -p` to pick a point).";
        };
        y = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "Vertical position in logical px from the window's top edge (use `slurp -p` to pick a point).";
        };
      };
    };
  };

  config = lib.mkIf config.hydrix.hyprland.enable {
    home-manager.users.${username} = {lib, ...}: {
      home.packages = [
        pkgs.eww
        ewwRouterStats
        ewwWgStatus
        ewwVpnToggle
        ewwMvmStatus
        ewwGcStatus
        ewwNetStats
        ewwGitStatus
        ewwWeather
        todo
        ewwTodoListen
        ewwDashboardWatch
      ];

      home.activation.ewwConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
        _dir="$HOME/.config/eww"
        mkdir -p "$_dir"
        [ -L "$_dir/eww.yuck" ] && rm "$_dir/eww.yuck" || true
        [ -L "$_dir/eww.scss" ] && rm "$_dir/eww.scss" || true
        cp ${ewwYuckFile} "$_dir/eww.yuck" && chmod 644 "$_dir/eww.yuck"
        cp ${ewwScssFile} "$_dir/eww.scss" && chmod 644 "$_dir/eww.scss"
      '';

      systemd.user.paths.eww-colors = {
        Unit.Description = "Watch pywal SCSS for eww color reload";
        Path.PathChanged = "%h/.cache/wal/colors.scss";
        Install.WantedBy = ["hyprland-session.target"];
      };

      systemd.user.services.eww-colors = {
        Unit = {
          Description = "Reload eww on pywal color change";
          After = ["hyprland-session.target"];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.eww}/bin/eww reload";
        };
      };

      systemd.user.services.eww-dashboard-watch = {
        Unit = {
          Description = "eww dashboard watcher";
          After = ["hyprland-session.target"];
          PartOf = ["hyprland-session.target"];
        };
        Service = {
          Type = "simple";
          ExecStart = "${ewwDashboardWatch}/bin/eww-dashboard-watch";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = ["hyprland-session.target"];
      };
    };
  };
}
