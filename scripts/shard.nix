{
  pkgs,
  lib,
}: let
  shardApp = pkgs.writeShellApplication {
    name = "shard";
    runtimeInputs = with pkgs; [
      age
      jq
      nix-output-monitor
      socat
      openssl
      python3
      util-linux
    ];
    text = ''
      # shard - Simple microVM management with timing
      #
      # Every command below works as either a word or a same-letter flag; flags
      # combine and run in the order given (see: shard -h).
      #
      # Usage:
      #   shard -b|build <name>      Build microVM image
      #   shard -s|start <name>      Start microVM (waits until ready)
      #   shard -S|stop <name>       Stop microVM
      #   shard -R|restart <name>    Restart microVM
      #   shard -r|rebuild <name>    Build + live switch (no restart)
      #   shard -w|switch <name>     Live switch to (already-)built config
      #   shard -W|switch-status <name>  Show live vs built configuration paths
      #   shard -a|app <name> <cmd>  Launch app in microVM
      #   shard -c|console <name>    Attach to serial console (headless VMs)
      #   shard -i|status [name]     Show status of microVM(s)
      #   shard -l|logs <name>       View microVM logs (follow)
      #   shard -p|purge <name>      Delete all persistent data (fresh start)
      #   shard -t|test <name>       Full workflow test with timing
      #   shard list                 List all declared microVMs
      #
      # Examples:
      #   shard -bs browsing         Build then start, one VM
      #   shard -bs browsing lurking Build both, then start both (flag-major order)
      #   shard build browsing       Word form, equivalent to -b
      #
      # Shebang and set -euo pipefail are provided by writeShellApplication's
      # generated preamble (scripts/shard.nix), not repeated here.

      SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
      readonly SCRIPT_DIR

      # Auto-detect flake directory (supports both architectures)
      # Priority: HYDRIX_FLAKE_DIR env > ~/hydrix-config > ~/Hydrix > script location
      detect_flake_dir() {
          local username="''${SUDO_USER:-$USER}"
          local home_dir="/home/$username"

          # Environment variable override (highest priority)
          if [[ -n "''${HYDRIX_FLAKE_DIR:-}" ]] && [[ -f "''${HYDRIX_FLAKE_DIR}/flake.nix" ]]; then
              echo "$HYDRIX_FLAKE_DIR"
              return
          fi

          # User mode: ~/hydrix-config (imports Hydrix from GitHub)
          if [[ -f "$home_dir/hydrix-config/flake.nix" ]]; then
              echo "$home_dir/hydrix-config"
              return
          fi

          # Fallback to script location (for direct execution)
          dirname "$SCRIPT_DIR"
      }

      FLAKE_DIR="$(detect_flake_dir)"
      readonly FLAKE_DIR

      # Load a vsock port from /etc/hydrix/ports.json, falling back to the default.
      # Fallbacks match the hydrix.networking.vsockPorts option defaults.
      PORTS_JSON="/etc/hydrix/ports.json"
      load_port() {
          local key="$1" default="$2"
          if [[ -f "$PORTS_JSON" ]]; then
              local val
              val=$(jq -r --arg k "$key" '.[$k] // empty' "$PORTS_JSON" 2>/dev/null)
              echo "''${val:-$default}"
          else
              echo "$default"
          fi
      }

      SWITCH_PORT=$(load_port switch 14504)
      DISPLAY_MODE_PORT=$(load_port displayMode 14509)
      WAYPIPE_LAUNCH_PORT=$(load_port waypipeLaunch 14508)
      readonly BUILDER_NAME="microvm-builder"
      BUILDER_BUILD_PORT=$(load_port builderBuild 14510)
      BUILDER_STATUS_PORT=$(load_port builderStatus 14511)
      readonly GITSYNC_NAME="microvm-gitsync"

      # Router VM names, read from host-config.json so per-machine names work.
      # Falls back to the default names for fresh installs / pre-activation.
      ROUTER_NAME=$(jq -r '.routerVmName // "microvm-router"' /etc/hydrix/host-config.json 2>/dev/null || echo "microvm-router")
      STABLE_ROUTER_NAME=$(jq -r '.stableRouterVmName // "microvm-router-stable"' /etc/hydrix/host-config.json 2>/dev/null || echo "microvm-router-stable")
      # Generations each VM keeps, current included (hydrix.microvmHost.keepGenerations; 0: all)
      KEEP_GENERATIONS=$(jq -r '.keepGenerations // 10' /etc/hydrix/host-config.json 2>/dev/null || echo 10)
      [[ "$KEEP_GENERATIONS" =~ ^[0-9]+$ ]] || KEEP_GENERATIONS=10
      GITSYNC_GIT_PORT=$(load_port gitsyncGit 14512)
      # Reserved for parity with the documented vsock port table (gitsync-status);
      # not queried directly by this script.
      GITSYNC_STATUS_PORT=$(load_port gitsyncStatus 14513)
      readonly SWITCH_PORT DISPLAY_MODE_PORT WAYPIPE_LAUNCH_PORT BUILDER_BUILD_PORT \
          BUILDER_STATUS_PORT ROUTER_NAME STABLE_ROUTER_NAME GITSYNC_GIT_PORT
      # shellcheck disable=SC2034
      readonly GITSYNC_STATUS_PORT

      # Colors
      readonly RED=$'\e[31m'
      readonly GREEN=$'\e[32m'
      readonly YELLOW=$'\e[33m'
      readonly CYAN=$'\e[36m'
      readonly MAGENTA=$'\e[35m'
      readonly BOLD=$'\e[1m'
      readonly DIM=$'\e[2m'
      readonly NC=$'\e[0m'

      # Timing helpers (LC_ALL=C for consistent decimal handling)
      timer_start() { date +%s; }
      timer_end() {
          local start="$1"
          local end
          end=$(date +%s)
          echo "$(( end - start ))"
      }

      log() { echo -e "''${CYAN}::''${NC} $*"; }
      log_success() { echo -e "''${GREEN}::''${NC} $*"; }
      log_warn() { echo -e "''${YELLOW}::''${NC} $*"; }
      log_error() { echo -e "''${RED}::''${NC} $*" >&2; }
      log_time() { echo -e "''${MAGENTA}::''${NC} ''${DIM}$*''${NC}"; }

      # Detect current specialisation (lockdown, administrative, fallback)
      detect_current_specialisation() {
          # Method 1: Read from /run/current-system/configuration-name
          if [[ -f /run/current-system/configuration-name ]]; then
              local name
              name=$(cat /run/current-system/configuration-name 2>/dev/null || true)
              if [[ "$name" == "lockdown" || "$name" == "administrative" || "$name" == "fallback" ]]; then
                  echo "$name"
                  return
              fi
          fi

          # Method 2: Check /etc/HYDRIX_MODE
          if [[ -f /etc/HYDRIX_MODE ]]; then
              local mode
              mode=$(grep "^MODE=" /etc/HYDRIX_MODE 2>/dev/null | cut -d= -f2 || true)
              if [[ "$mode" == "lockdown" || "$mode" == "administrative" || "$mode" == "fallback" ]]; then
                  echo "$mode"
                  return
              fi
          fi

          # Method 3: Infer from running services
          if systemctl is-active --quiet "microvm@''${ROUTER_NAME}.service" 2>/dev/null; then
              echo "administrative"
              return
          fi

          # Default to lockdown (safest assumption)
          echo "lockdown"
      }

      # Registry file: generated at activation from infra/*/meta.nix and profiles/*/meta.nix
      # All VMs declared in hydrix-config appear here, no hardcoded CID tables needed.
      VM_REGISTRY="/etc/hydrix/vm-registry.json"

      # Resolve a registry key (e.g. "browsing", "pentest-task1") to its real
      # per-machine vmName from vm-registry.json. Falls back to "microvm-<key>"
      # for pre-activation/fresh-install cases where the registry doesn't exist yet.
      registry_vm_name() {
          local key="$1"
          local name=""
          [[ -f "$VM_REGISTRY" ]] && name=$(jq -r --arg k "$key" '.[$k].vmName // empty' "$VM_REGISTRY" 2>/dev/null)
          echo "''${name:-microvm-$key}"
      }

      # Get vsock CID for a VM.
      # Priority: registry file → nix eval fallback (for VMs not yet activated)
      get_cid() {
          local vm_name="$1"

          # Registry lookup, covers all VMs declared in infra/*/meta.nix or profiles/*/meta.nix.
          # The registry is a static file on disk, readable even when nix-daemon is stopped.
          if [[ -f "$VM_REGISTRY" ]]; then
              local cid
              # Try vmName field match first (e.g. "microvm-router-user")
              cid=$(jq -r --arg v "$vm_name" \
                  'to_entries[] | select(.value.vmName == $v) | .value.cid' \
                  "$VM_REGISTRY" 2>/dev/null | head -1)
              if [[ -z "$cid" ]]; then
                  # Fallback: profile key match (strip "microvm-" prefix)
                  local profile="''${vm_name#microvm-}"
                  cid=$(jq -r --arg p "$profile" '.[$p].cid // empty' "$VM_REGISTRY" 2>/dev/null || echo "")
              fi
              if [[ -n "$cid" ]]; then
                  echo "$cid"
                  return
              fi
          fi

          # Nix eval fallback: for VMs not yet in the registry (e.g. task VMs, pre-activation)
          local cid
          cid=$(nix eval --json "$FLAKE_DIR#nixosConfigurations.''${vm_name}.config.hydrix.microvm.vsockCid" 2>/dev/null || echo "")
          if [[ -z "$cid" || "$cid" == "null" ]]; then
              cid=$(nix eval --json "$FLAKE_DIR#nixosConfigurations.''${vm_name}.config.microvm.vsock.cid" 2>/dev/null || echo "")
          fi
          echo "$cid"
      }

      # Infra VM CIDs, resolved from registry (infra/*/meta.nix in hydrix-config).
      # Fallback to reserved defaults for pre-activation / fresh installs.
      BUILDER_CID=$(get_cid "$BUILDER_NAME" 2>/dev/null || true); BUILDER_CID="''${BUILDER_CID:-210}"
      GITSYNC_CID=$(get_cid "$GITSYNC_NAME" 2>/dev/null || true); GITSYNC_CID="''${GITSYNC_CID:-211}"

      # Get static IP for a VM (subnet.<own CID>, matches hydrix.microvm.staticIp's
      # default derivation in microvm-profile-base.nix). Using the VM's own CID as the
      # last octet keeps VMs that share a subnet (pentest + its task slots) from
      # colliding on the same address.
      # Derived from vm-registry.json (e.g. subnet "192.168.102" + cid 116 → "192.168.102.116")
      get_vm_ip() {
          local vm_name="$1"

          if [[ -f "$VM_REGISTRY" ]]; then
              local key
              # Try vmName field match first (handles per-machine suffixed names, e.g.
              # "microvm-browsing-<serial>"); falls back to treating the stripped name
              # as the registry key directly (unsuffixed infra VMs, pre-registry VMs).
              key=$(jq -r --arg v "$vm_name" \
                  'to_entries[] | select(.value.vmName == $v) | .key' \
                  "$VM_REGISTRY" 2>/dev/null | head -1)
              [[ -z "$key" ]] && key="''${vm_name#microvm-}"

              local subnet cid
              subnet=$(jq -r --arg k "$key" '.[$k].subnet // empty' "$VM_REGISTRY" 2>/dev/null || echo "")
              cid=$(jq -r --arg k "$key" '.[$k].cid // empty' "$VM_REGISTRY" 2>/dev/null || echo "")
              if [[ -n "$subnet" && -n "$cid" ]]; then
                  echo "''${subnet}.''${cid}"
                  return
              fi
          fi

          echo ""
      }

      # Check if VM is running
      is_running() {
          local vm_name="$1"
          systemctl is-active --quiet "microvm@''${vm_name}.service" 2>/dev/null
      }

      # Check if VM is headless (no display-mode service).
      # Reads hasDisplay from the registry. VMs not in the registry default to
      # graphical (false), task VMs and pre-activation VMs are display VMs.
      is_headless() {
          local vm_name="$1"
          if [[ -f "$VM_REGISTRY" ]]; then
              local has_display
              has_display=$(jq -r --arg v "$vm_name" \
                  'to_entries[] | .value.vmName as $name | select($name == $v or ($v | startswith($name + "-"))) | .value.hasDisplay' \
                  "$VM_REGISTRY" 2>/dev/null | head -1)
              if [[ -n "$has_display" ]]; then
                  [[ "$has_display" != "true" ]]
                  return
              fi
          fi
          # Not in registry: assume graphical
          return 1
      }

      # Check if VM is the builder
      is_builder() {
          local vm_name="$1"
          [[ "$vm_name" == "$BUILDER_NAME" || "$vm_name" == "microbuild" ]]
      }

      # Check if host nix-daemon is running
      host_daemon_running() {
          systemctl is-active --quiet nix-daemon.service 2>/dev/null
      }

      # Wait for gitsync vsock to be ready
      # Pings the git port (14512) directly - the same port the real command runs
      # on. Polling the separate status port (14513) instead used to let the host
      # proceed the instant that unrelated service came up, sometimes racing ahead
      # of gitsync-vsock itself and hitting "connection reset by peer".
      wait_for_gitsync() {
          local timeout="''${1:-60}"
          local elapsed=0

          while ! echo "PING" | timeout 2 vsock-cmd "''${GITSYNC_CID}" "''${GITSYNC_GIT_PORT}" 2>/dev/null | grep -q "PONG"; do
              sleep 1
              elapsed=$((elapsed + 1))
              if [[ $elapsed -ge $timeout ]]; then
                  return 1
              fi
          done
          return 0
      }

      # Wait for builder vsock to be ready (default: the host builder; a tier builder by CID)
      wait_for_builder() {
          local timeout="''${1:-60}"
          local cid="''${2:-$BUILDER_CID}"
          local elapsed=0

          while ! echo "PING" | timeout 2 vsock-cmd "$cid" "''${BUILDER_STATUS_PORT}" 2>/dev/null | grep -q "PONG"; do
              sleep 1
              elapsed=$((elapsed + 1))
              if [[ $elapsed -ge $timeout ]]; then
                  return 1
              fi
          done
          return 0
      }

      # Store tiers (hydrix.builder.storeTier): a VM whose registry entry has storeTier runs
      # from /var/lib/hydrix/stores/<tier>, written only by the VM whose buildsTier matches.
      # The host never reads a tier store; it only checks that a built path exists there.
      readonly TIER_STORES="/var/lib/hydrix/stores"
      readonly TIER_VIEWS="/var/lib/hydrix/stores/views"
      readonly HOST_CACHE="/var/lib/hydrix/caches/host"

      # Registry field of the entry whose vmName matches (empty if unset)
      registry_field() {
          local vm_name="$1" field="$2"
          [[ -f "$VM_REGISTRY" ]] || return 0
          jq -r --arg v "$vm_name" --arg f "$field" \
              'to_entries[] | select(.value.vmName == $v) | .value[$f] // empty' \
              "$VM_REGISTRY" 2>/dev/null | head -1
      }

      vm_store_tier() { registry_field "$1" storeTier; }

      # What the host builds for a VM: its runner, or for a tier VM the runner plus the
      # kernel outputs (system.build.tierHost, microvm-profile-base.nix).
      vm_build_attr() {
          if [[ -n "$(vm_store_tier "$1")" ]]; then
              echo "config.system.build.tierHost"
          else
              echo "config.microvm.declaredRunner"
          fi
      }

      tier_builder() {
          [[ -f "$VM_REGISTRY" ]] || return 0
          jq -r --arg t "$1" 'to_entries[] | select(.value.buildsTier == $t) | .value.vmName' \
              "$VM_REGISTRY" 2>/dev/null | head -1
      }

      # Send a build request ("BUILD <flake attr>", or "BUILDDRV <name> <drv>" to a tier
      # builder) to a builder VM and render its progress with nom, as nh does;
      # fails unless the builder ends with DONE. The builder streams Nix internal-json, which
      # is untrusted: nix-log-sanitize strips control characters from it before nom or the
      # log see it. nom reads each .drv from the host store: the host builder writes them
      # there, and for a tier build cache_export_tier has instantiated the same graph on the
      # host. The log replays with: nom --json < ~/.local/state/hydrix/last-build.log
      builder_send_build() {
          local cid="$1" request="$2" rc=0 sp sock_rc=0 interrupted=0
          local state="''${XDG_STATE_HOME:-$HOME/.local/state}/hydrix"
          local build_log="$state/last-build.log" raw="$state/last-build.raw" err="$state/last-build.socat"
          mkdir -p "$state"
          : > "$raw"
          # The connection drains into a file at full speed, never straight into the display.
          # In internal-json mode Nix sends bursts of small progress events once builds start;
          # piped into the display, back-pressure dropped the vsock connection (host socat
          # exit 1, the builder's write: Broken pipe). The display follows the file instead.
          # shut-none: the end of our input must not reach the builder. Its listener runs
          # with -t600, which would kill the build 600s after it saw that EOF. -T: an hour
          # without output still ends a hung build.
          { echo "$request"; sleep 1; } \
              | socat -t86400 -T3600 - "VSOCK-CONNECT:''${cid}:''${BUILDER_BUILD_PORT},shut-none" \
                  > "$raw" 2> "$err" &
          sp=$!
          # Ctrl+C ends the display; this also ends the connection, so the build fails cleanly
          # and the caller still stops its builder.
          trap 'kill "$sp" 2>/dev/null; interrupted=1' INT
          # tee -p keeps writing the log if nom exits, so the display cannot end the build.
          tail -n +1 -f --pid="$sp" "$raw" \
              | python3 -u ${./lib/nix-log-sanitize.py} \
              | tee -p "$build_log" \
              | nom --json
          wait "$sp" || sock_rc=$?
          trap - INT
          rm -f "$raw"
          if [[ $interrupted -eq 1 ]]; then
              log_error "Interrupted"
              rc=130
          elif grep -q "^ERROR" "$build_log"; then
              rc=1
          elif ! grep -q "^DONE" "$build_log"; then
              rc=1
              log_error "The builder's output ended without DONE or ERROR (socat exit ''${sock_rc})"
              [[ -s "$err" ]] && head -n 5 "$err" | LC_ALL=C tr -d '\000-\010\013-\037\177'
          fi
          if [[ $rc -ne 0 ]]; then
              log "Full build output: ''${build_log} (replay: nom --json < ''${build_log})"
          fi
          return "$rc"
      }

      # Build a tier VM. The host builds what it owns first (runner and kernel, tierHost),
      # exports what the tier system shares with the host store to the host cache, then the
      # tier builder builds the system from that cache. current moves only at the end, so a
      # failed step leaves the VM on its previous build.
      cmd_tier_build() {
          local vm_name="$1" tier="$2"
          local builder
          builder=$(tier_builder "$tier")
          if [[ -z "$builder" ]]; then
              log_error "No builder owns store tier ''${tier} (buildsTier in an infra meta.nix)"
              return 1
          fi
          if [[ ! -e "/var/lib/microvms/''${builder}/current" ]]; then
              log_error "''${builder} is not built yet: shard -b ''${builder}"
              return 1
          fi

          local start
          start=$(timer_start)

          # One host evaluation gives all three paths: the host part (tierHost: runner and
          # kernel), the tier system and its recipe. tierSystem links the system and its
          # closure registration (microvm-profile-base.nix); it is built (never substituted)
          # after its whole closure is in the tier store. The host evaluates: the tier builder
          # never sees the flake, only the exported recipes.
          local attr="nixosConfigurations.''${vm_name}.config.system.build.tierSystem"
          local host_part tier_system drv paths
          log "Evaluating ''${BOLD}''${vm_name}''${NC}..."
          if ! paths=$(nix eval --raw "''${FLAKE_DIR}#nixosConfigurations.''${vm_name}.config.system.build" \
                  --apply 'b: b.tierHost.outPath + " " + b.tierSystem.outPath + " " + b.tierSystem.drvPath'); then
              log_error "Evaluation failed"
              return 1
          fi
          read -r host_part tier_system drv <<< "$paths"

          # The runner changes only with the kernel, initrd or QEMU settings: when this exact
          # host part is already in the host store, the host builder is not started at all.
          log "''${BOLD}[1/4]''${NC} Host part of ''${vm_name}: runner and kernel"
          if nix path-info "$host_part" &>/dev/null; then
              log "Unchanged, already built: ''${host_part}"
              vm_link "$vm_name" tier-host "$host_part"
          else
              _HYDRIX_TIER_FLOW=1 cmd_build "$vm_name" || return 1
          fi
          local runner
          runner=$(readlink -f "/var/lib/microvms/''${vm_name}/tier-host/runner")
          if [[ ! -x "$runner/bin/microvm-run" ]]; then
              log_error "Host part has no runner: /var/lib/microvms/''${vm_name}/tier-host"
              return 1
          fi

          local tier_path="''${TIER_STORES}/''${tier}''${tier_system}"

          if [[ -d "$tier_path" && ! -L "$tier_path" ]]; then
              log "''${BOLD}[2/4]''${NC} Skipped: the system is already in the ''${tier} store"
              log "''${BOLD}[3/4]''${NC} Skipped"
          else
              log "''${BOLD}[2/4]''${NC} Exporting what the host already has to the host cache"
              cache_export_tier "$vm_name" "$drv" || return 1

              log "''${BOLD}[3/4]''${NC} Building the system in the ''${tier} store (''${builder})"
              local cid started=0 rc=0 step
              step=$(timer_start)
              cid=$(get_cid "$builder")
              if ! is_running "$builder"; then
                  cmd_start "$builder" || return 1
                  started=1
              fi
              log "Waiting for ''${builder}..."
              if ! wait_for_builder 90 "$cid"; then
                  log_error "Timeout waiting for ''${builder}"
                  rc=1
              else
                  builder_send_build "$cid" "BUILDDRV ''${vm_name} ''${drv}" || rc=1
              fi
              [[ $started -eq 1 ]] && { cmd_stop "$builder" || true; }
              if [[ $rc -ne 0 ]]; then
                  log_error "Tier build failed; ''${vm_name} keeps its previous build"
                  return 1
              fi
              if [[ ! -d "$tier_path" || -L "$tier_path" ]]; then
                  log_error "Built system is missing from the ''${tier} store: ''${tier_path}"
                  return 1
              fi
              log_time "System built in ''${BOLD}$(timer_end "$step")s''${NC}"
          fi

          if is_headless "$vm_name"; then
              log "''${BOLD}[4/4]''${NC} Store view and runner"
          else
              log "''${BOLD}[4/4]''${NC} Store view, runner and app list"
          fi
          # The view gets the new closure before current and tier-system move, so the recorded
          # build always has a complete view (start's exact sync reads tier-system).
          tier_view_sync "$vm_name" add "$tier_system" || return 1
          vm_link "$vm_name" current "$runner"
          # cmd_switch finds the system and its registration through this (tier store path).
          printf '%s\n' "$tier_system" | sudo install -m 644 /dev/stdin "/var/lib/microvms/''${vm_name}/tier-system"
          if is_headless "$vm_name"; then
              sudo rm -f "/var/lib/microvms/''${vm_name}/apps.tsv"
          else
              tier_write_apps "$vm_name" "$tier" "$tier_system"
          fi
          gen_record "$vm_name" "$host_part" "$tier_system"
          root_flake_inputs
          log_success "Build complete in ''${BOLD}$(timer_end "$start")s''${NC}: $runner"
          echo ""
          build_apply_hint "$vm_name"
      }

      # Copy store paths and their closures into the host cache. Unsigned: tier builders read
      # it read-only and trusted (?trusted=1, microvm-builder.nix); only host root writes it.
      # --derivation first: copy .drv files with their recipe closures instead of outputs.
      host_cache_copy() {
          local copy_mode=()
          [[ "''${1:-}" == --derivation ]] && { copy_mode=(--derivation); shift; }
          if is_running "$BUILDER_NAME"; then
              log_error "Stop ''${BUILDER_NAME} first (it holds the host store)"
              return 1
          fi
          # A reader's Nix creates these when it opens the cache and drops the cache when it
          # can't: the tier builders mount it read-only.
          sudo install -d -m 755 "''${HOST_CACHE}"/{nar,realisations,log}
          printf '%s\n' "$@" \
              | sudo xargs -r nix copy "''${copy_mode[@]}" --to "file://''${HOST_CACHE}?compression=zstd"
      }

      # Export to the host cache what a tier VM's system can take from the host store instead
      # of building. Walks the derivation graph from the top, as substitution does: where the
      # host has every output a derivation is needed for, those outputs (with their closures)
      # are exported and the walk stops there; otherwise it continues into that derivation's
      # inputs. Nothing outside the VM's own graph reaches the cache.
      # The recipes go too (the .drv closure, with the sources they reference): the tier builder
      # builds from them and never evaluates the flake (BUILDDRV).
      cache_export_tier() {
          local vm_name="$1" drv="''${2:-}" paths=()
          local attr="nixosConfigurations.''${vm_name}.config.system.build.tierSystem"
          if [[ -z "$drv" ]]; then
              drv=$(nix eval --raw "''${FLAKE_DIR}#''${attr}.drvPath") || return 1
          fi
          log "Exporting the build recipes of ''${vm_name}..."
          host_cache_copy --derivation "$drv" || { log_error "Recipe export failed"; return 1; }
          mapfile -t paths < <(nix derivation show -r "''${drv}^*" 2>/dev/null \
              | python3 ${./lib/tier-export-walk.py} "$drv")
          if [[ ''${#paths[@]} -eq 0 ]]; then
              log "Nothing to export: the host has none of it"
              return 0
          fi
          local before after step
          step=$(timer_start)
          before=$(sudo find "$HOST_CACHE" -maxdepth 1 -name '*.narinfo' | wc -l)
          log "''${#paths[@]} paths shared with the host store, copying them with their closures..."
          host_cache_copy "''${paths[@]}" || { log_error "Host cache export failed"; return 1; }
          after=$(sudo find "$HOST_CACHE" -maxdepth 1 -name '*.narinfo' | wc -l)
          log_time "Exported $((after - before)) new paths in ''${BOLD}$(timer_end "$step")s''${NC} (cache: $(sudo du -sh "$HOST_CACHE" | cut -f1))"
      }

      # Host binary cache, exported for tier builders (unsigned, read trusted and read-only).
      # Only the host writes it; caches flow down, the host never substitutes from a tier.
      cmd_cache() {
          local sub="''${1:-help}"
          [[ $# -gt 0 ]] && shift
          case "$sub" in
              export)
                  local paths=() arg vm sys
                  [[ $# -eq 0 ]] && set -- system
                  for arg in "$@"; do
                      case "$arg" in
                          system)
                              paths+=("$(readlink -f /run/current-system)")
                              ;;
                          /nix/store/*)
                              paths+=("$arg")
                              ;;
                          *)
                              vm=$(resolve_vm_name "$arg")
                              if [[ -n "$(vm_store_tier "$vm")" ]]; then
                                  cache_export_tier "$vm" || return 1
                                  continue
                              fi
                              sys=$(readlink -f "/var/lib/microvms/''${vm}/current/share/microvm/system" 2>/dev/null || true)
                              if [[ -z "$sys" ]]; then
                                  log_error "''${vm} has no system in the host store (a tier VM, or not built)"
                                  return 1
                              fi
                              paths+=("$sys")
                              ;;
                      esac
                  done
                  [[ ''${#paths[@]} -eq 0 ]] && return 0
                  log "Exporting ''${#paths[@]} closure(s) to ''${HOST_CACHE}..."
                  local start
                  start=$(timer_start)
                  host_cache_copy "''${paths[@]}" || return 1
                  log_time "Exported in ''${BOLD}$(timer_end "$start")s''${NC}, cache: $(sudo du -sh "$HOST_CACHE" | cut -f1)"
                  ;;
              clear)
                  sudo find "$HOST_CACHE" -mindepth 1 ! -name nix-cache-info -delete
                  sudo install -d -m 755 "''${HOST_CACHE}"/{nar,realisations,log}
                  log_success "Host cache cleared"
                  ;;
              status)
                  echo "  Host cache: $(sudo du -sh "$HOST_CACHE" 2>/dev/null | cut -f1)"
                  local d
                  for d in "$TIER_STORES"/*/; do
                      [[ -d "$d" ]] || continue
                      echo "  Tier $(basename "$d"): $(sudo du -sh "$d" 2>/dev/null | cut -f1)"
                  done
                  ;;
              *)
                  echo "Usage: shard cache <export [system|<vm>|<store path>...]|clear|status>"
                  echo "  export with no argument exports the host system closure."
                  ;;
          esac
      }

      # A microvm.nix runner (has bin/microvm-run), not some other build output.
      is_microvm_runner() { [[ -x "$1/bin/microvm-run" ]]; }

      # Point /var/lib/microvms/<vm>/<name> at a store path, recreating the directory
      # structure tmpfiles would (needed after a purge).
      vm_link() {
          local vm_name="$1" name="$2" path="$3"
          sudo mkdir -p "/var/lib/microvms/''${vm_name}/config"
          sudo chown microvm:kvm "/var/lib/microvms/''${vm_name}"
          sudo chown root:root "/var/lib/microvms/''${vm_name}/config"
          sudo chmod 755 "/var/lib/microvms/''${vm_name}" "/var/lib/microvms/''${vm_name}/config"
          sudo ln -sfn "$path" "/var/lib/microvms/''${vm_name}/''${name}"
      }

      # Build microVM
      cmd_build() {
          local vm_name="$1"
          engagement_prompt "$vm_name" || return 1
          # A VM built before generations existed keeps its current build as generation 1
          gen_adopt "$vm_name"

          # Auto-provision the LUKS-encrypted home volume before building, if this VM
          # declares hydrix.microvm.encryption.enable and doesn't have one yet. Runs
          # first, before the lockdown-mode reroute below, since it's a pure host-side
          # operation unrelated to what's built inside the builder VM. This also means
          # it's already a no-op by the time cmd_builder_build's own
          # _HYDRIX_BUILDER_FLOW=1 host-registration call reaches this same function
          # (the file will already exist from this first pass).
          # The `|| echo "false"` fallback makes this a no-op for VM types that don't
          # declare hydrix.microvm.encryption at all (router/builder/infra VMs built
          # via mkMicrovmRouter/mkMicrovmBuilder/mkInfraVm don't import
          # microvm-profile-options.nix).
          local luks_path="/var/lib/microvms/''${vm_name}/home.luks"
          if [[ ! -f "$luks_path" ]]; then
              local enc_enabled
              enc_enabled=$(nix eval --json "''${FLAKE_DIR}#nixosConfigurations.''${vm_name}.config.hydrix.microvm.encryption.enable" 2>/dev/null || echo "false")
              if [[ "$enc_enabled" == "true" ]]; then
                  log "Encryption enabled for ''${vm_name}, no encrypted volume found, setting one up..."
                  if ! _HYDRIX_AUTO_ENCRYPT=1 cmd_encrypt_setup "$vm_name"; then
                      log_error "Encrypted volume setup failed"
                      return 1
                  fi
              fi
          fi

          # Tier VM: the system is built in its tier store first (cmd_tier_build), then
          # the runner continues below.
          local tier
          tier=$(vm_store_tier "$vm_name")
          if [[ -n "$tier" && "''${_HYDRIX_TIER_FLOW:-}" != "1" ]]; then
              cmd_tier_build "$vm_name" "$tier"
              return
          fi

          # In lockdown mode, route through builder VM (skip if already inside builder flow).
          # The builder too: its existing build runs and builds the new one, since the host
          # cannot fetch whatever a garbage collection took (sources, build tools). Only its
          # very first build (no current yet) builds on the host.
          if [[ "''${_HYDRIX_BUILDER_FLOW:-}" != "1" ]] && \
             [[ "$(detect_current_specialisation)" == "lockdown" ]] && \
             { ! is_builder "$vm_name" || [[ -e "/var/lib/microvms/''${vm_name}/current" ]]; }; then
              log "Lockdown mode, routing build through builder VM"
              cmd_builder_build "$vm_name"
              return
          fi

          # Builder VM: need host nix-daemon running to build the VM image
          # (different from when builder is RUNNING, when we need it stopped)
          if is_builder "$vm_name" && ! host_daemon_running; then
              log "Starting host nix-daemon (needed to build VM image)..."
              # Remount store read-only first if it's still rw
              restore_store_ro || true
              sudo systemctl start nix-daemon.socket
          fi

          log "Building ''${BOLD}''${vm_name}''${NC}..."
          local start
          start=$(timer_start)

          # Lockdown: the host has no network, so never ask a substituter (an unreachable
          # one fails the build). Everything comes from the store or builds locally.
          local offline=()
          [[ "$(detect_current_specialisation)" == "lockdown" ]] && offline=(--offline)

          local out_link="/tmp/''${vm_name}"
          if ! nom build "''${offline[@]}" "''${FLAKE_DIR}#nixosConfigurations.''${vm_name}.$(vm_build_attr "$vm_name")" -o "$out_link"; then
              log_error "Build failed"
              return 1
          fi

          local build_time
          build_time=$(timer_end "$start")
          log_time "Build completed in ''${BOLD}''${build_time}s''${NC}"

          # Resolve to the store path (systemd has PrivateTmp, can't see /tmp). The out-link is
          # only a GC root until current or tier-host points at the build: dropped below, so
          # /tmp keeps no roots that outlive the VM's own links (or its name).
          local store_path
          store_path=$(readlink -f "$out_link")

          # Tier VM: its system is not built yet, so current stays; cmd_tier_build links it
          # once the system is in the tier store. tier-host is a GC root for the kernel
          # outputs (host/microvm/default.nix).
          if [[ -n "$(vm_store_tier "$vm_name")" ]]; then
              vm_link "$vm_name" tier-host "$store_path"
              rm -f "$out_link" 2>/dev/null || true
              log_success "Host part built: $store_path"
              return 0
          fi

          # A host-store runner links its system (share/microvm/system); a tier runner does not
          # (microvm-profile-base.nix). One without it here means the flake already puts this VM
          # on a store tier but the host registry, which decides the route above, does not know
          # yet: its system was never built, and linking the runner would leave a VM that
          # cannot boot.
          if is_microvm_runner "$store_path" && [[ ! -e "$store_path/share/microvm/system" ]]; then
              log_error "''${vm_name} now runs from a store tier, but the host registry does not list it yet"
              log "Run rebuild first (the registry comes from the host config), then: shard -b ''${vm_name}"
              log "Nothing was linked; ''${vm_name} keeps its previous build."
              return 1
          fi

          log "Updating symlink..."
          vm_link "$vm_name" current "$store_path"
          rm -f "$out_link" 2>/dev/null || true
          gen_record "$vm_name" "$store_path"
          root_flake_inputs
          # Only tier VMs have one (cmd_tier_build); a VM moved off a tier reads its system again.
          sudo rm -f "/var/lib/microvms/''${vm_name}/apps.tsv"

          log_success "Build complete: $store_path"
          echo ""
          build_apply_hint "$vm_name"
      }

      # Start microVM
      # Return /nix/store to read-only after the builder had it read-write.
      # Retries while virtiofsd releases it, then checks the result: a store
      # left writable must never pass silently.
      restore_store_ro() {
          local i
          for i in 1 2 3 4 5; do
              if findmnt -no OPTIONS /nix/store | grep -qE '(^|,)ro(,|$)'; then
                  return 0
              fi
              sudo mount -o remount,ro,bind /nix/store 2>/dev/null || sleep 1
          done
          if findmnt -no OPTIONS /nix/store | grep -qE '(^|,)ro(,|$)'; then
              return 0
          fi
          log_error "/nix/store is still read-write on the host (remount busy)"
          log "Restore it with: sudo mount -o remount,ro,bind /nix/store"
          log "A reboot also restores it."
          return 1
      }

      # Unlock the VM's encrypted home volume if it has one and it is closed.
      # Every path that starts the service goes through here (start, restart).
      ensure_unlocked() {
          local vm_name="$1"
          local luks_path="/var/lib/microvms/''${vm_name}/home.luks"
          local mapper_name="vm-''${vm_name}-home"

          # The built runner's qemu -drive args hardcode /dev/mapper/vm-<name>-home
          # when encryption.enable is set at build time (microvm-profile-base.nix,
          # autoCreate = false, the host must have already luksOpen'd it). Detect
          # that expectation directly from the runner so a missing LUKS container
          # (e.g. after `shard purge`, which deletes *.luks) fails fast with a
          # clear message instead of crash-looping to a display-service timeout.
          if grep -q "/dev/mapper/''${mapper_name}" \
              "/var/lib/microvms/''${vm_name}/current/bin/microvm-run" 2>/dev/null \
              && [[ ! -f "$luks_path" ]]; then
              log_error "''${vm_name} expects an encrypted home volume (/dev/mapper/''${mapper_name}) but no LUKS container exists at ''${luks_path}"
              log "This usually happens after 'shard purge ''${vm_name}'. Run: shard encrypt-setup ''${vm_name}"
              return 1
          fi

          if [[ -f "$luks_path" ]]; then
              if [[ -b "/dev/mapper/''${mapper_name}" ]]; then
                  log "Encrypted volume already unlocked"
              else
                  log "Unlocking encrypted volume for ''${BOLD}''${vm_name}''${NC}..."
                  if ! sudo cryptsetup luksOpen "$luks_path" "$mapper_name"; then
                      log_error "Failed to unlock encrypted volume"
                      return 1
                  fi
                  log_success "Volume unlocked"
              fi
          fi
          return 0
      }

      # A tier builder writes its tier store through a virtiofsd running as host root; the
      # stores must be mounted nosuid,nodev first (hydrix-tier-stores-nosuid.service), or a
      # builder could leave a working setuid file or device node on the host.
      check_tier_stores() {
          local vm_name="$1" opts
          [[ -n "$(registry_field "$vm_name" buildsTier)" ]] || return 0
          opts=",$(findmnt -no OPTIONS --target "$TIER_STORES" 2>/dev/null),"
          if [[ "$opts" != *,nosuid,* || "$opts" != *,nodev,* ]]; then
              log_error "''${TIER_STORES} is not mounted nosuid,nodev: not starting ''${vm_name}"
              # restart: the unit stays active (RemainAfterExit), so start would do nothing.
              log "Mount it with: sudo systemctl restart hydrix-tier-stores-nosuid"
              return 1
          fi
      }

      # A tier VM's store share is its own view, /var/lib/hydrix/stores/views/<vm>/nix/store:
      # only its closure, hard-linked from the tier store (scripts/lib/tier-view.py), so it
      # never sees another tier VM's packages, systems or recipes. "add" may run while the VM
      # runs (nothing it booted with goes away); "exact" also drops what the closure no longer
      # needs and runs only while the VM is stopped. The tier system defaults to the recorded
      # last build; cmd_tier_build passes the new one before recording it.
      tier_view_sync() {
          local vm_name="$1" mode="$2" ts="''${3:-}" tier root reg out
          if [[ -n "$(registry_field "$vm_name" buildsTier)" ]]; then
              builder_view_sync "$vm_name" "$mode"
              return
          fi
          tier=$(vm_store_tier "$vm_name")
          [[ -n "$tier" ]] || return 0
          root="''${TIER_STORES}/''${tier}"
          if [[ -z "$ts" && ! -e "/var/lib/microvms/''${vm_name}/tier-system" ]] \
              && [[ -e "/var/lib/microvms/''${vm_name}/current/share/microvm/system" ]]; then
              # Moved to a tier, not rebuilt yet: its host-store build still boots as before.
              log "''${vm_name} runs its host-store build until shard -b ''${vm_name} moves it to the ''${tier} store"
              return 0
          fi
          [[ -n "$ts" ]] || ts=$(cat "/var/lib/microvms/''${vm_name}/tier-system" 2>/dev/null || true)
          if [[ ! "$ts" =~ ^/nix/store/[a-z0-9]{32}-hydrix-tier-system$ ]]; then
              log_error "''${vm_name} has no tier build yet: shard -b ''${vm_name}"
              return 1
          fi
          reg=$(readlink "''${root}''${ts}/registration" 2>/dev/null || true)
          if [[ -L "''${root}''${ts}" || ! "$reg" =~ ^/nix/store/[a-z0-9]{32}-closure-info$ ]]; then
              log_error "No usable tier build for ''${vm_name} in the ''${tier} store: shard -b ''${vm_name}"
              return 1
          fi
          if ! out=$(sudo ${pkgs.python3}/bin/python3 ${./lib/tier-view.py} \
                  "$root" "''${TIER_VIEWS}/''${vm_name}/nix/store" "$reg" "$mode" 2>&1); then
              log_error "Store view of ''${vm_name} failed:"
              printf '%s\n' "$out" | tail -n 5 | LC_ALL=C tr -d '\000-\010\013-\037\177'
              return 1
          fi
          log "Store view: $(printf '%s' "$out" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
      }

      # A tier builder's own store share (microvm-builder.nix): a copy of its runner's closure
      # from the host store, so it never sees the rest of the host store. Copied, not linked:
      # hard links cannot leave the /nix/store mount (on btrfs the copies are reflinks).
      # Root reads the closure: the host nix-daemon may be stopped for the host builder.
      builder_view_sync() {
          local vm_name="$1" mode="$2" runner closure list out rc=0
          runner=$(readlink -f "/var/lib/microvms/''${vm_name}/current" 2>/dev/null || true)
          if [[ ! "$runner" =~ ^/nix/store/[a-z0-9]{32}- ]]; then
              log_error "''${vm_name} is not built yet: shard -b ''${vm_name}"
              return 1
          fi
          if ! closure=$(sudo nix-store -qR "$runner"); then
              log_error "Could not read the closure of ''${vm_name}: ''${runner}"
              return 1
          fi
          list=$(mktemp)
          printf '%s\n' "$closure" > "$list"
          out=$(sudo ${pkgs.python3}/bin/python3 ${./lib/tier-view.py} \
              --copy "$list" "''${TIER_VIEWS}/''${vm_name}/nix/store" "$mode" 2>&1) || rc=$?
          rm -f "$list"
          if [[ $rc -ne 0 ]]; then
              log_error "Store view of ''${vm_name} failed:"
              printf '%s\n' "$out" | tail -n 5 | LC_ALL=C tr -d '\000-\010\013-\037\177'
              return 1
          fi
          log "Store view: $(printf '%s' "$out" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
      }

      # The launcher reads a VM's .desktop entries from its system, which is not in the host
      # store for a tier VM; tier-apps reads them from the tier store, which a tier builder
      # writes, so it resolves every link inside it and checks each name and command.
      tier_write_apps() {
          local vm_name="$1" tier="$2" tier_system="$3" apps
          if apps=$(python3 ${./lib/tier-apps.py} "''${TIER_STORES}/''${tier}" "$tier_system" "''${SUDO_USER:-$USER}"); then
              printf '%s\n' "$apps" | sudo install -m 644 /dev/stdin "/var/lib/microvms/''${vm_name}/apps.tsv"
              log "$(printf '%s\n' "$apps" | grep -c .) apps for the launcher"
          else
              log_warn "Could not list ''${vm_name}'s apps; the launcher will not show them"
          fi
      }

      # GC roots for the flake inputs this host has fetched (lib/flake-input-roots.py): a
      # lockdown host evaluates offline, so no garbage collection may take a source it
      # cannot download again. Only fetched inputs: rooting all of flake.lock would fetch
      # inputs evaluation never touches.
      root_flake_inputs() {
          [[ -f "''${FLAKE_DIR}/flake.lock" ]] || return 0
          local out
          if out=$(sudo ${pkgs.python3}/bin/python3 ${./lib/flake-input-roots.py} "${pkgs.nix}/bin" \
                  "''${FLAKE_DIR}/flake.lock" /nix/var/nix/gcroots/hydrix-inputs 2>&1); then
              log "$out"
          else
              log_warn "Could not root the flake inputs: $(printf '%s\n' "$out" | tail -n 1)"
          fi
      }

      # After a build: a running VM keeps its system until it switches or restarts
      build_apply_hint() {
          local short
          # shard -r applies it right after
          [[ "''${_HYDRIX_APPLYING:-}" == 1 ]] && return 0
          short=$(vm_short_name "$1")
          if is_running "$1"; then
              echo -e "  ''${DIM}''${short} still runs its previous system. Apply:''${NC} shard -w ''${short} (live) or shard -R ''${short} (restart)"
          else
              echo -e "  ''${DIM}To start:''${NC} shard -s ''${short}"
          fi
      }

      # ===== Generations =====
      # Every build that moves current is a generation: /var/lib/microvms/<vm>/generations/<N>/
      # with host (the runner, or tier-host for a tier VM), system (tier VMs: the system's
      # tier store path) and created. Each one is a GC root in the host store
      # (/nix/var/nix/gcroots/microvm/gen-<vm>-<N>) and, for a tier VM, in its tier store
      # (gcroots/hydrix/<vm>-gen<N>), so switching back needs no rebuild until it is purged.
      # A running VM keeps its runner through booted and its system through its view
      # (hardlinks), so only the generation current points at is never purged.
      gen_dir() { echo "/var/lib/microvms/$1/generations"; }

      gen_numbers() {
          local d
          d=$(gen_dir "$1")
          [[ -d "$d" ]] || return 0
          find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
              | grep -E '^[0-9]+$' | sort -n || true
      }

      # The runner a generation boots: tier-host/runner for a tier build, else host itself
      gen_runner() {
          local g
          g="$(gen_dir "$1")/$2"
          if [[ -f "$g/system" ]]; then
              readlink -f "$g/host/runner" 2>/dev/null || true
          else
              readlink -f "$g/host" 2>/dev/null || true
          fi
      }

      gen_record() {
          local vm_name="$1" host="$2" system="''${3:-}" created="''${4:-}" d last n tier
          d=$(gen_dir "$vm_name")
          last=$(gen_numbers "$vm_name" | tail -n 1)
          if [[ -n "$last" && "$(readlink "$d/$last/host" 2>/dev/null || true)" == "$host" \
                && "$(cat "$d/$last/system" 2>/dev/null || true)" == "$system" ]]; then
              return 0
          fi
          n=$(( ''${last:-0} + 1 ))
          sudo install -d -m 755 "$d/$n"
          sudo ln -sfn "$host" "$d/$n/host"
          if [[ -n "$system" ]]; then
              printf '%s\n' "$system" | sudo install -m 644 /dev/stdin "$d/$n/system"
          fi
          [[ -n "$created" ]] || created=$(date '+%Y-%m-%d %H:%M')
          printf '%s\n' "$created" | sudo install -m 644 /dev/stdin "$d/$n/created"
          sudo ln -sfn "$d/$n/host" "/nix/var/nix/gcroots/microvm/gen-''${vm_name}-''${n}"
          if [[ -n "$system" ]]; then
              tier=$(vm_store_tier "$vm_name")
              sudo install -d -m 755 "''${TIER_STORES}/''${tier}/nix/var/nix/gcroots/hydrix"
              sudo ln -sfn "$system" "''${TIER_STORES}/''${tier}/nix/var/nix/gcroots/hydrix/''${vm_name}-gen''${n}"
          fi
          log "Recorded as generation ''${BOLD}''${n}''${NC} (shard -g list ''${vm_name})"
          gen_prune "$vm_name"
      }

      # Remove one generation: its record and its GC roots (host store and, for a tier VM,
      # its tier store). The space comes back at the next collection.
      gen_drop() {
          local vm_name="$1" n="$2" tier
          tier=$(vm_store_tier "$vm_name")
          sudo rm -f "/nix/var/nix/gcroots/microvm/gen-''${vm_name}-''${n}"
          if [[ -n "$tier" ]]; then
              sudo rm -f "''${TIER_STORES}/''${tier}/nix/var/nix/gcroots/hydrix/''${vm_name}-gen''${n}"
          fi
          sudo rm -rf -- "$(gen_dir "$vm_name")/''${n:?}"
      }

      # Drop the oldest generations beyond KEEP_GENERATIONS (current always stays): their
      # records and GC roots only. The space comes back at the next collection.
      gen_prune() {
          local vm_name="$1" d current others drop=() a
          [[ "$KEEP_GENERATIONS" -gt 0 ]] || return 0
          d=$(gen_dir "$vm_name")
          current=" $(gen_current "$vm_name" | tr '\n' ' ') $(gen_running "$vm_name") "
          others=$(for a in $(gen_numbers "$vm_name"); do [[ "$current" == *" $a "* ]] || echo "$a"; done)
          # current takes one of the kept places
          local keep_others=$(( KEEP_GENERATIONS - 1 ))
          # shellcheck disable=SC2207
          drop=($(printf '%s\n' "$others" | grep . | head -n -"$keep_others" || true))
          [[ ''${#drop[@]} -gt 0 ]] || return 0
          for a in "''${drop[@]}"; do
              gen_drop "$vm_name" "$a"
          done
          log "Dropped generation(s) ''${drop[*]} (keeping ''${KEEP_GENERATIONS}; space frees at the next shard -g gc)"
      }

      # A VM built before generations existed: its current build becomes generation 1.
      gen_adopt() {
          local vm_name="$1" dir="/var/lib/microvms/$1" host system=""
          [[ -z "$(gen_numbers "$vm_name")" ]] || return 0
          if [[ -n "$(vm_store_tier "$vm_name")" ]]; then
              [[ -L "$dir/tier-host" && -f "$dir/tier-system" && -L "$dir/current" ]] || return 0
              host=$(readlink "$dir/tier-host")
              system=$(cat "$dir/tier-system")
              # A VM just moved to a tier still has its host-store runner as current
              [[ "$(readlink -f "$dir/current")" == "$(readlink -f "$host/runner")" ]] || return 0
          else
              [[ -L "$dir/current" ]] || return 0
              host=$(readlink "$dir/current")
          fi
          [[ -e "$host" ]] || return 0
          # Dated by when current was linked, not now
          gen_record "$vm_name" "$host" "$system" \
              "$(date -d "@$(stat -c %Y "$dir/current")" '+%Y-%m-%d %H:%M')"
      }

      # Generation numbers current points at (runner and, for a tier VM, system)
      gen_current() {
          local vm_name="$1" dir="/var/lib/microvms/$1" cur sys n
          cur=$(readlink -f "$dir/current" 2>/dev/null || true)
          sys=$(cat "$dir/tier-system" 2>/dev/null || true)
          [[ -n "$(vm_store_tier "$vm_name")" ]] || sys=""
          for n in $(gen_numbers "$vm_name"); do
              [[ "$(gen_runner "$vm_name" "$n")" == "$cur" \
                 && "$(cat "$(gen_dir "$vm_name")/$n/system" 2>/dev/null || true)" == "$sys" ]] && echo "$n"
          done
          return 0
      }

      # The registry key (browsing, pentest-task1, builder...) for a VM name, for examples
      vm_short_name() {
          local k
          k=$(jq -r --arg v "$1" 'to_entries[] | select(.value.vmName == $v) | .key' "$VM_REGISTRY" 2>/dev/null | head -1)
          echo "''${k:-$1}"
      }

      # A generation's NixOS system: from its tier store entry, or the runner's own link
      gen_system() {
          local vm_name="$1" n="$2" sys tier
          sys=$(cat "$(gen_dir "$vm_name")/$n/system" 2>/dev/null || true)
          if [[ -n "$sys" ]]; then
              tier=$(vm_store_tier "$vm_name")
              [[ -n "$tier" ]] && readlink "''${TIER_STORES}/''${tier}''${sys}/system" 2>/dev/null || true
          else
              readlink -f "$(gen_runner "$vm_name" "$n")/share/microvm/system" 2>/dev/null || true
          fi
      }

      # The system the running VM has live (its /run/current-system, from the switch
      # service). Untrusted reply: only a NixOS system store path is accepted.
      vm_live_system() {
          local cid reply live
          is_running "$1" || return 0
          cid=$(get_cid "$1")
          [[ -n "$cid" ]] || return 0
          reply=$(vsock_query "$cid" "$SWITCH_PORT" "STATUS" 3 5 2>/dev/null || true)
          live=$(printf '%s\n' "$reply" | sed -n 's/^CURRENT //p' | head -n 1)
          [[ "$live" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-[A-Za-z0-9._-]+$ ]] && echo "$live"
          return 0
      }

      # The generation the VM runs now: the one whose system the VM has live (the default
      # wins when several share it). Without an answer from the VM, the one whose runner
      # starts the running initrd. (booted can lag: microvm.nix sets it on a full start
      # only, not when QEMU starts again after a reboot inside the VM.)
      gen_running() {
          local vm_name="$1" pid initrd n found="" current live
          is_running "$vm_name" || return 0
          current=" $(gen_current "$vm_name" | tr '\n' ' ')"
          live=$(vm_live_system "$vm_name")
          if [[ -n "$live" ]]; then
              for n in $(gen_numbers "$vm_name" | sort -rn); do
                  [[ "$(gen_system "$vm_name" "$n")" == "$live" ]] || continue
                  if [[ "$current" == *" $n "* ]]; then
                      echo "$n"
                      return 0
                  fi
                  [[ -n "$found" ]] || found="$n"
              done
              [[ -z "$found" ]] || echo "$found"
              return 0
          fi
          pid=$(systemctl show -p MainPID --value "microvm@''${vm_name}.service" 2>/dev/null || true)
          [[ -n "$pid" && "$pid" != 0 && -r "/proc/$pid/cmdline" ]] || return 0
          initrd=$(tr '\0' '\n' < "/proc/$pid/cmdline" | grep -A1 -x -- '-initrd' | tail -n 1 || true)
          [[ "$initrd" =~ ^/nix/store/ ]] || return 0
          for n in $(gen_numbers "$vm_name" | sort -rn); do
              grep -qF -- "$initrd" "$(gen_runner "$vm_name" "$n")/bin/microvm-run" 2>/dev/null || continue
              if [[ "$current" == *" $n "* ]]; then
                  echo "$n"
                  return 0
              fi
              [[ -n "$found" ]] || found="$n"
          done
          [[ -z "$found" ]] || echo "$found"
      }

      gen_list_one() {
          local vm_name="$1" d nums n run sys running marks tier current
          gen_adopt "$vm_name"
          d=$(gen_dir "$vm_name")
          nums=$(gen_numbers "$vm_name")
          echo -e "''${BOLD}''${vm_name}''${NC}"
          if [[ -z "$nums" ]]; then
              echo "  no generations yet (recorded from the next shard -b)"
              return 0
          fi
          tier=$(vm_store_tier "$vm_name")
          current=" $(gen_current "$vm_name" | tr '\n' ' ')"
          running=$(gen_running "$vm_name")
          for n in $nums; do
              run=$(gen_runner "$vm_name" "$n")
              sys=$(cat "$d/$n/system" 2>/dev/null || true)
              marks=""
              [[ "$current" == *" $n "* ]] && marks+=" ''${GREEN}default''${NC}"
              [[ "$n" == "$running" ]] && marks+=" ''${CYAN}running''${NC}"
              [[ -e "$run" ]] || marks+=" ''${RED}runner collected''${NC}"
              if [[ -n "$sys" && -n "$tier" && ! -d "''${TIER_STORES}/''${tier}''${sys}" ]]; then
                  marks+=" ''${RED}system collected''${NC}"
              fi
              printf '  %4s  %s  runner %s' "$n" "$(cat "$d/$n/created" 2>/dev/null || echo '?')" \
                  "$(basename "$run" | cut -c1-8)"
              [[ -n "$sys" ]] && printf '  system %s' "$(basename "$sys" | cut -c1-8)"
              echo -e "$marks"
          done
          if [[ $(printf '%s\n' "$nums" | grep -c .) -gt 1 ]]; then
              echo -e "  ''${DIM}Switch: shard -g switch $(vm_short_name "$vm_name") <N|prev|latest>''${NC}"
          fi
      }

      gen_list() {
          if [[ -n "''${1:-}" ]]; then
              gen_list_one "$1"
              return
          fi
          local c vm any=0
          for c in /var/lib/microvms/*/current; do
              [[ -L "$c" ]] || continue
              vm=$(basename "$(dirname "$c")")
              gen_list_one "$vm"
              any=1
          done
          [[ $any -eq 1 ]] || echo "No VM is built yet."
      }

      # Run a generation now, like booting an older entry on the host: current keeps the
      # newest build, so every start that does not ask for one (autostart, shard -s, -R)
      # boots the newest again. A reboot inside the VM only stops it (microvm@ restarts on
      # failure only). With the running kernel and initrd the system switches live;
      # otherwise (or when the VM is stopped) the generation boots once.
      gen_switch() {
          local vm_name="$1" n="''${2:-}" d nums short ref run sys tier latest
          d=$(gen_dir "$vm_name")
          gen_adopt "$vm_name"
          nums=$(gen_numbers "$vm_name")
          short=$(vm_short_name "$vm_name")
          latest=$(gen_current "$vm_name" | tail -n 1)
          case "$n" in
              prev|previous)
                  # The newest generation older than the one running (or the default)
                  ref=$(gen_running "$vm_name")
                  [[ -n "$ref" ]] || ref="$latest"
                  n=$(for a in $nums; do
                          if [[ -n "$ref" && "$a" -lt "$ref" ]]; then echo "$a"; fi
                      done | tail -n 1)
                  [[ -n "$n" ]] || { log_error "''${short} has no older generation"; return 1; }
                  ;;
              latest) n="$latest" ;;
          esac
          if [[ ! "$n" =~ ^[0-9]+$ || ! -d "$d/$n" ]]; then
              [[ -n "$n" ]] && log_error "No generation ''${n} for ''${short}"
              gen_list_one "$vm_name"
              echo ""
              echo "  shard -g switch ''${short} <N>       e.g. shard -g switch ''${short} $(printf '%s\n' "$nums" | head -n 1)"
              echo "  shard -g switch ''${short} prev      the one before the running generation"
              echo "  shard -g switch ''${short} latest    back to the newest (also: shard -R ''${short})"
              return 1
          fi
          run=$(gen_runner "$vm_name" "$n")
          if [[ ! -x "$run/bin/microvm-run" ]]; then
              log_error "Generation ''${n}'s runner is no longer in the host store"
              return 1
          fi
          sys=$(cat "$d/$n/system" 2>/dev/null || true)
          tier=$(vm_store_tier "$vm_name")
          if [[ -n "$tier" && -z "$sys" ]]; then
              log_error "Generation ''${n} is from before ''${short} moved to the ''${tier} tier"
              return 1
          elif [[ -z "$tier" && -n "$sys" ]]; then
              log_error "Generation ''${n} is a tier build; ''${short} is not on a store tier now"
              return 1
          fi

          if is_running "$vm_name" && [[ -n "$(vm_live_system "$vm_name")" ]] \
             && [[ "$(vm_live_system "$vm_name")" == "$(gen_system "$vm_name" "$n")" ]]; then
              log "''${short} already runs generation ''${n}'s system: nothing to switch"
              [[ "$n" == "$latest" ]] || log "Its next boot starts generation ''${latest}"
              return 0
          fi
          if is_running "$vm_name" && gen_same_boot "$vm_name" "$run"; then
              log "Same kernel and initrd as the running VM: switching live to generation ''${n}"
              if [[ -n "$tier" ]]; then
                  _HYDRIX_SWITCH_TIER_SYSTEM="$sys" cmd_switch "$vm_name" || return 1
              else
                  cmd_switch "$vm_name" "$(readlink -f "$run/share/microvm/system")" || return 1
              fi
          elif [[ "$n" == "$latest" ]]; then
              log "Booting the newest generation (''${n})"
              if is_running "$vm_name"; then cmd_restart "$vm_name"; else cmd_start "$vm_name"; fi
              return
          else
              gen_boot_once "$vm_name" "$n" || return 1
          fi
          if [[ "$n" != "$latest" ]]; then
              log_success "''${short} runs generation ''${n} until its next boot, which starts ''${latest} again"
              echo -e "  ''${DIM}Back now: shard -g switch ''${short} latest''${NC}"
          fi
      }

      # Boot a generation once: current and tier-system point at it while the VM starts,
      # then back at the newest, so the next start boots the newest. The view gets the
      # newest system back too (a later live switch to it needs no new view sync).
      gen_boot_once() {
          local vm_name="$1" n="$2" dir rc=0 latest_run latest_sys sys tier
          dir="/var/lib/microvms/''${vm_name}"
          tier=$(vm_store_tier "$vm_name")
          latest_run=$(readlink "$dir/current")
          latest_sys=$(cat "$dir/tier-system" 2>/dev/null || true)
          sys=$(cat "$(gen_dir "$vm_name")/$n/system" 2>/dev/null || true)
          log "Kernel or initrd differ (or the VM is stopped): booting generation ''${n} once"
          if is_running "$vm_name"; then cmd_stop "$vm_name" || return 1; fi
          vm_link "$vm_name" current "$(gen_runner "$vm_name" "$n")"
          [[ -n "$tier" ]] && printf '%s\n' "$sys" | sudo install -m 644 /dev/stdin "$dir/tier-system"
          # A subshell: whatever cmd_start does on failure, current goes back below
          ( cmd_start "$vm_name" ) || rc=$?
          vm_link "$vm_name" current "$latest_run"
          if [[ -n "$tier" && -n "$latest_sys" ]]; then
              printf '%s\n' "$latest_sys" | sudo install -m 644 /dev/stdin "$dir/tier-system"
              tier_view_sync "$vm_name" add "$latest_sys" || true
          fi
          return $rc
      }

      # True when a runner starts the kernel and initrd the running VM was booted with
      gen_same_boot() {
          local vm_name="$1" runner="$2" pid args kernel initrd
          pid=$(systemctl show -p MainPID --value "microvm@''${vm_name}.service" 2>/dev/null || true)
          [[ -n "$pid" && "$pid" != 0 && -r "/proc/$pid/cmdline" ]] || return 1
          args=$(tr '\0' '\n' < "/proc/$pid/cmdline")
          kernel=$(printf '%s\n' "$args" | grep -A1 -x -- '-kernel' | tail -n 1 || true)
          initrd=$(printf '%s\n' "$args" | grep -A1 -x -- '-initrd' | tail -n 1 || true)
          [[ "$kernel" =~ ^/nix/store/ && "$initrd" =~ ^/nix/store/ ]] || return 1
          grep -qF -- "$kernel" "$runner/bin/microvm-run" 2>/dev/null \
              && grep -qF -- "$initrd" "$runner/bin/microvm-run" 2>/dev/null
      }

      # Free what purged generations held: the host store, then the tier store through its
      # builder (the host never collects a tier store itself).
      gen_collect() {
          local tier="''${1:-}" out
          if is_running "$BUILDER_NAME"; then
              log_warn "''${BUILDER_NAME} holds the host store: host garbage collection skipped"
          else
              root_flake_inputs
              log "Collecting garbage in the host store..."
              if out=$(sudo nix-store --gc 2>&1); then
                  log "$(printf '%s\n' "$out" | tail -n 1)"
              else
                  log_warn "Host garbage collection failed: $(printf '%s\n' "$out" | tail -n 1)"
              fi
          fi
          [[ -n "$tier" ]] || return 0
          gen_collect_tier "$tier"
      }

      gen_collect_tier() {
          local tier="$1" builder cid started=0 rc=0
          builder=$(tier_builder "$tier")
          if [[ -z "$builder" || ! -e "/var/lib/microvms/''${builder}/current" ]]; then
              log_warn "No built builder for the ''${tier} tier: its store was not collected"
              return 0
          fi
          log "Collecting garbage in the ''${tier} store (''${builder})..."
          cid=$(get_cid "$builder")
          if ! is_running "$builder"; then
              cmd_start "$builder" || return 1
              started=1
          fi
          if ! wait_for_builder 90 "$cid"; then
              log_error "Timeout waiting for ''${builder}"
              rc=1
          else
              builder_send_build "$cid" "GC" || rc=1
          fi
          [[ $started -eq 1 ]] && { cmd_stop "$builder" || true; }
          return $rc
      }

      # purge <vm> <N...|old> [--keep K] [--no-gc] [-f]
      gen_purge() {
          local vm_name="$1"
          shift
          local nogc=0 force=0 keep="" all=0 want=() a
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  --no-gc) nogc=1 ;;
                  -f|--force) force=1 ;;
                  --keep)
                      keep="''${2:-}"
                      [[ "$keep" =~ ^[0-9]+$ ]] || { log_error "--keep needs a number"; return 1; }
                      shift
                      ;;
                  old) all=1 ;;
                  *)
                      [[ "$1" =~ ^[0-9]+$ ]] || { log_error "Not a generation number: $1"; return 1; }
                      want+=("$1")
                      ;;
              esac
              shift
          done
          gen_adopt "$vm_name"
          local nums current d
          nums=$(gen_numbers "$vm_name")
          # The default (newest) and the one running stay
          current=" $(gen_current "$vm_name" | tr '\n' ' ') $(gen_running "$vm_name") "
          d=$(gen_dir "$vm_name")
          if [[ $all -eq 0 && -z "$keep" && ''${#want[@]} -eq 0 ]]; then
              log_error "Usage: shard -g purge <vm> <N...|old> [--keep K] [--no-gc] [-f]"
              return 1
          fi
          # old or --keep K: every generation but current (and the K newest others)
          local candidates=()
          if [[ $all -eq 1 || -n "$keep" ]]; then
              local others
              others=$(for a in $nums; do [[ "$current" == *" $a "* ]] || echo "$a"; done)
              [[ -n "$keep" && "$keep" -gt 0 ]] && others=$(printf '%s\n' "$others" | head -n -"$keep")
              # shellcheck disable=SC2206
              candidates=($others)
          fi
          for a in "''${want[@]}"; do
              [[ -d "$d/$a" ]] || { log_error "No generation $a for ''${vm_name}"; return 1; }
              if [[ "$current" == *" $a "* ]]; then
                  log_error "Generation $a is the default or running one"
                  return 1
              fi
              candidates+=("$a")
          done
          if [[ ''${#candidates[@]} -eq 0 ]]; then
              log "Nothing to purge for ''${vm_name}"
              return 0
          fi
          echo -e "Purge generations of ''${BOLD}''${vm_name}''${NC}: ''${candidates[*]}"
          if [[ $force -eq 0 ]]; then
              local confirm
              read -rp "Type 'yes' to confirm: " confirm
              [[ "$confirm" != "yes" ]] && { log "Aborted"; return 1; }
          fi
          local tier
          tier=$(vm_store_tier "$vm_name")
          for a in "''${candidates[@]}"; do
              gen_drop "$vm_name" "$a"
          done
          log_success "Purged ''${#candidates[@]} generation(s) of ''${vm_name}"
          [[ $nogc -eq 1 ]] && return 0
          gen_collect "$tier"
      }

      # gc [vm ...] [-f]: every generation but the current one goes, for the named VMs or
      # every built VM; then leftover roots in both stores, stopped tier VMs' views trimmed to
      # their current system, and garbage collection in the host store and the tier stores.
      gen_gc() {
          local force=0 vms=() a v c t cur old plan=() tiers=() total=0
          for a in "$@"; do
              case "$a" in
                  -f|--force) force=1 ;;
                  *) vms+=("$(resolve_vm_name "$a")") ;;
              esac
          done
          if [[ ''${#vms[@]} -eq 0 ]]; then
              for c in /var/lib/microvms/*/current; do
                  [[ -L "$c" ]] && vms+=("$(basename "$(dirname "$c")")")
              done
          fi
          for v in "''${vms[@]}"; do
              gen_adopt "$v"
              cur=" $(gen_current "$v" | tr '\n' ' ')"
              if [[ "$cur" == " " ]]; then
                  [[ -n "$(gen_numbers "$v")" ]] && log_warn "$(vm_short_name "$v"): current is no recorded generation, its generations stay"
                  continue
              fi
              # The one running stays too
              cur="$cur$(gen_running "$v") "
              old=$(for a in $(gen_numbers "$v"); do [[ "$cur" == *" $a "* ]] || echo "$a"; done | tr '\n' ' ')
              old="''${old% }"
              if [[ -n "$old" ]]; then
                  plan+=("$v|$old")
                  total=$(( total + $(wc -w <<< "$old") ))
              fi
              t=$(vm_store_tier "$v")
              [[ -n "$t" && " ''${tiers[*]} " != *" $t "* ]] && tiers+=("$t")
          done

          if [[ $total -gt 0 ]]; then
              echo -e "''${BOLD}Generations to drop''${NC} (all but the default and the running one):"
              for a in "''${plan[@]}"; do
                  echo "  $(vm_short_name "''${a%%|*}"): ''${a#*|}"
              done
              if [[ $force -eq 0 ]]; then
                  local confirm
                  read -rp "Type 'yes' to confirm: " confirm
                  [[ "$confirm" != "yes" ]] && { log "Aborted"; return 1; }
              fi
              for a in "''${plan[@]}"; do
                  for c in ''${a#*|}; do
                      gen_drop "''${a%%|*}" "$c"
                  done
              done
              log_success "Dropped $total generation(s)"
          else
              log "No old generations"
          fi

          # Leftover roots: generation roots whose generation is gone (also of deleted VMs),
          # and a tier builder's own out-link per VM, which can hold a build no generation
          # keeps (after a switch back). The current generation's root keeps the current build.
          for c in /nix/var/nix/gcroots/microvm/gen-*; do
              [[ -L "$c" ]] || continue
              [[ -d "$(dirname "$(readlink "$c")")" ]] || sudo rm -f "$c"
          done
          local all_tiers
          all_tiers=$(jq -r '[.[] | .buildsTier // empty] | unique | .[]' "$VM_REGISTRY" 2>/dev/null || true)
          for t in $all_tiers; do
              local roots="''${TIER_STORES}/''${t}/nix/var/nix/gcroots/hydrix" name
              while IFS= read -r name; do
                  [[ -n "$name" ]] || continue
                  if [[ "$name" =~ ^(.+)-gen([0-9]+)$ ]]; then
                      [[ -d "/var/lib/microvms/''${BASH_REMATCH[1]}/generations/''${BASH_REMATCH[2]}" ]] \
                          || sudo rm -f "$roots/$name"
                  elif [[ -n "$(gen_current "$name")" ]]; then
                      sudo rm -f "$roots/$name"
                  fi
              done < <(sudo find "$roots" -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null || true)
              [[ " ''${tiers[*]} " == *" $t "* ]] || tiers+=("$t")
          done

          # A stopped tier VM's view keeps only its current system (a running one is trimmed
          # at its next start)
          for v in "''${vms[@]}"; do
              [[ -n "$(vm_store_tier "$v")" ]] || continue
              is_running "$v" && continue
              [[ -f "/var/lib/microvms/$v/tier-system" ]] || continue
              tier_view_sync "$v" exact || true
          done

          gen_collect ""
          for t in "''${tiers[@]}"; do
              gen_collect_tier "$t" || true
          done
      }

      cmd_generations() {
          local action="''${1:-help}"
          case "$action" in
              list)
                  if [[ -n "''${2:-}" ]]; then gen_list "$(resolve_vm_name "$2")"; else gen_list; fi
                  ;;
              switch)
                  [[ -n "''${2:-}" ]] || { log_error "Usage: shard -g switch <vm> <N|prev|latest>"; return 1; }
                  gen_switch "$(resolve_vm_name "$2")" "''${3:-}"
                  ;;
              gc)
                  gen_gc "''${@:2}"
                  ;;
              purge)
                  [[ -n "''${2:-}" ]] || { log_error "Usage: shard -g purge <vm> <N...|old> [--keep K] [--no-gc] [-f]"; return 1; }
                  gen_purge "$(resolve_vm_name "$2")" "''${@:3}"
                  ;;
              *)
                  echo -e "''${BOLD}shard -g''${NC} | ''${BOLD}shard generations''${NC} - A VM's builds"
                  echo ""
                  echo "  list [vm]                       Generations of one VM, or of every VM"
                  echo "  switch <vm> <N|prev|latest>     Run generation N now: live when kernel and initrd"
                  echo "                                  match the running VM, else booted once. The next"
                  echo "                                  boot starts the default (newest) again; without N:"
                  echo "                                  the list and examples"
                  echo "  purge <vm> <N...|old> [-f]      Delete generations (never the current one), then"
                  echo "        [--keep K] [--no-gc]      collect garbage in the host store and the VM's"
                  echo "                                  tier store. old: every generation but current;"
                  echo "                                  --keep K: also keep the K newest others"
                  echo "  gc [vm ...] [-f]                Drop every generation but the current one (named"
                  echo "                                  VMs, or all), leftover roots in both stores, stale"
                  echo "                                  views; then collect the host and tier stores"
                  echo ""
                  echo "default: what every start boots (the newest build). running: what runs now."
                  echo "Every shard -b that moves current records a generation in"
                  echo "/var/lib/microvms/<vm>/generations/. Each is a GC root until purged, in the host"
                  echo "store and, for a tier VM, in its tier store, so a switch back needs no rebuild."
                  echo "Each VM keeps the newest ''${KEEP_GENERATIONS} (hydrix.microvmHost.keepGenerations,"
                  echo "0: all); a build drops older ones, and their space frees at the next gc."
                  ;;
          esac
      }

      # Push waypipe mode, connect the host tunnel and report waypipe-connect's verdict: it
      # confirms the tunnel twice, the second time a few seconds after it goes live.
      connect_waypipe_tunnel() {
          local vm_name="$1" cid="$2"
          local logf="/tmp/waypipe-connect-''${vm_name}.log"
          log "Starting VM waypipe service..."
          vsock_query "$cid" "$DISPLAY_MODE_PORT" "waypipe" 3 5 >/dev/null 2>&1 || true
          log "Waiting for VM to settle..."
          sleep 10
          pkill -f "waypipe-connect ''${vm_name}$" 2>/dev/null || true
          sleep 0.5
          log "Connecting host waypipe tunnel..."
          setsid waypipe-connect "$vm_name" </dev/null >"$logf" 2>&1 &
          disown
          local _i
          for _i in $(seq 1 60); do
              sleep 0.5
              if grep -q '^Tunnel live' "$logf" 2>/dev/null; then
                  log_success "waypipe tunnel live"
                  return 0
              fi
              if grep -qE '^Tunnel (did not confirm|lost)' "$logf" 2>/dev/null; then
                  log_warn "waypipe tunnel not ready in the VM (waypipe-connect keeps retrying):"
                  grep -E '^Tunnel |^  VM: ' "$logf" | tail -n 11 | sed 's/^/     /'
                  log_warn "Full log: ''${logf}"
                  return 0
              fi
          done
          log_warn "waypipe tunnel not confirmed after 30s, see ''${logf}"
      }

      cmd_start() {
          local vm_name="$1"
          engagement_prompt "$vm_name" || return 1
          check_tier_stores "$vm_name" || return 1

          if is_running "$vm_name"; then
              log_error "''${vm_name} is already running"
              return 1
          fi

          local cid
          cid=$(get_cid "$vm_name")
          if [[ -z "$cid" ]]; then
              log_error "Cannot get vsock CID for ''${vm_name}. Is it defined in the flake?"
              return 1
          fi

          # Builder VM: stop host nix-daemon and remount store as read-write
          if is_builder "$vm_name"; then
              if host_daemon_running; then
                  log "Stopping host nix-daemon (required for builder)..."
                  sudo systemctl stop nix-daemon.service nix-daemon.socket
              fi
              # Remount /nix/store as read-write for builder to write to
              log "Remounting /nix/store as read-write..."
              sudo mount -o remount,rw,bind /nix/store
          fi

          ensure_unlocked "$vm_name" || return 1
          tier_view_sync "$vm_name" exact || return 1

          log "Starting ''${BOLD}''${vm_name}''${NC} (CID: ''${cid})..."
          local start
          start=$(timer_start)

          sudo systemctl start "microvm@''${vm_name}.service"

          local boot_time
          boot_time=$(timer_end "$start")
          log_time "Service started in ''${BOLD}''${boot_time}s''${NC}"

          # Headless VMs (router, builder) - different ready check
          if is_headless "$vm_name"; then
              if is_builder "$vm_name"; then
                  log "Waiting for builder vsock..."
                  if ! wait_for_builder 60; then
                      log_error "Timeout waiting for builder"
                      log "Check logs with: shard logs ''${vm_name}"
                      return 1
                  fi
                  local total_time
                  total_time=$(timer_end "$start")
                  log_success "Builder ready! Total boot time: ''${BOLD}''${total_time}s''${NC}"
                  echo ""
                  echo -e "  ''${DIM}Build:''${NC} shard builder build <flake>"
                  echo -e "  ''${DIM}Status:''${NC} shard builder status"
                  echo -e "  ''${DIM}Shell:''${NC} shard console ''${vm_name}"
              else
                  # Router - just report started
                  local total_time
                  total_time=$(timer_end "$start")
                  log_success "Started in ''${BOLD}''${total_time}s''${NC}"
                  echo ""
                  echo -e "  ''${DIM}Console:''${NC} shard console ''${vm_name}"
              fi
              return 0
          fi

          # Graphical VMs - wait for display-mode service (vsock:14509)
          log "Waiting for VM display service..."
          local dm_start
          dm_start=$(timer_start)
          local dm_timeout=45
          local dm_elapsed=0
          local dm_ready=0
          while [[ $dm_elapsed -lt $((dm_timeout * 2)) ]]; do
              if vsock_query "$cid" "$DISPLAY_MODE_PORT" "PING" 2 3 2>/dev/null | grep -q "OK"; then
                  dm_ready=1
                  break
              fi
              sleep 0.5
              dm_elapsed=$((dm_elapsed + 1))
          done

          if [[ $dm_ready -eq 0 ]]; then
              log_error "Timeout waiting for VM display service"
              log "Check logs with: shard logs ''${vm_name}"
              return 1
          fi

          local dm_time
          dm_time=$(timer_end "$dm_start")
          log_time "VM ready in ''${BOLD}''${dm_time}s''${NC}"

          local total_time
          total_time=$(timer_end "$start")
          log_success "Ready! Total boot time: ''${BOLD}''${total_time}s''${NC}"

          local profile
          profile=$(jq -r --arg v "$vm_name" 'to_entries[] | select(.value.vmName == $v) | .key' \
              "$VM_REGISTRY" 2>/dev/null | head -1)
          [[ -z "$profile" ]] && profile="''${vm_name#microvm-}"

          # In waypipe mode (Wayland): push waypipe mode to VM, wait 10s for it to
          # fully settle, then connect the host-side tunnel.
          local _waypipe_started=0
          if [[ -n "''${WAYLAND_DISPLAY:-}" ]] && command -v waypipe-connect >/dev/null 2>&1; then
              local vm_ws
              vm_ws=$(jq -r --arg p "$profile" '.[$p].workspace // empty' \
                  /etc/hydrix/vm-registry.json 2>/dev/null)
              if [[ -n "$vm_ws" ]]; then
                  connect_waypipe_tunnel "$vm_name" "$cid"
                  _waypipe_started=1
              fi
          fi

          # Fallback display-mode push (waypipe path above already handles the common case)
          if [[ "$_waypipe_started" -eq 0 ]] && command -v vm-push-display-mode >/dev/null 2>&1; then
              vm-push-display-mode "$profile" >/dev/null 2>&1 &
              disown
          fi

          # Push current host colors to the new VM via vsock
          if command -v push-colors-to-vms >/dev/null 2>&1; then
              push-colors-to-vms >/dev/null 2>&1 &
              disown
          fi

          # Desktop notification, waypipe mode includes workspace hint
          if [[ "$_waypipe_started" -eq 1 ]]; then
              notify-send -u normal "MicroVM launched" \
                  "''${vm_name} ready, WS''${vm_ws} apps available (Mod+Return)" 2>/dev/null || true
          else
              notify-send "MicroVM launched" "''${vm_name} is ready for interaction" 2>/dev/null || true
          fi

          # Register task slots as the active VM of their base profile's workspace
          # for waybar/vm-select
          local slot_profile
          slot_profile=$(task_slot_profile "$vm_name")
          if [[ -n "$slot_profile" ]]; then
              local active_vms_file="$HOME/.cache/hydrix/active-vms.json"
              mkdir -p "$(dirname "$active_vms_file")"
              [[ ! -f "$active_vms_file" ]] && echo '{}' > "$active_vms_file"
              local tmp
              tmp=$(mktemp)
              jq --arg p "$slot_profile" --arg vm "$vm_name" '.[$p] = $vm' "$active_vms_file" > "$tmp" && mv "$tmp" "$active_vms_file"
          fi

          echo ""
          echo -e "  ''${DIM}Launch app:''${NC} shard app ''${vm_name} firefox"
      }

      # Wait for service to fully stop
      wait_for_stop() {
          local vm_name="$1"
          local timeout="''${2:-10}"
          local elapsed=0

          while systemctl is-active --quiet "microvm@''${vm_name}.service" 2>/dev/null; do
              sleep 0.5
              elapsed=$((elapsed + 1))
              if [[ $elapsed -ge $((timeout * 2)) ]]; then
                  return 1
              fi
          done
          return 0
      }

      # Stop microVM
      # Ask a VM's windows to close before the VM goes down. Cutting a client off with live
      # surfaces (Firefox) has crashed Hyprland 0.55 during its teardown (a use-after-free in
      # wl_client_destroy); closed windows tear down in order. Best effort: a window that
      # stays open (a close-tabs prompt) does not hold up the stop.
      vm_windows() {
          hyprctl clients -j 2>/dev/null | jq -r --arg t "vm-$1" --arg p "[$1] " \
              '.[] | select(((.tags // []) | map(rtrimstr("*")) | index($t)) or (.title | startswith($p))) | .address'
      }
      close_vm_windows() {
          local vm_name="$1" key addrs addr i
          [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null 2>&1 || return 0
          key=$(jq -r --arg v "$vm_name" 'to_entries[] | select(.value.vmName == $v) | .key' "$VM_REGISTRY" 2>/dev/null | head -1)
          [[ -n "$key" ]] || return 0
          addrs=$(vm_windows "$key")
          [[ -n "$addrs" ]] || return 0
          log "Closing ''${key} windows..."
          while IFS= read -r addr; do
              hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1 || true
          done <<< "$addrs"
          for i in $(seq 1 20); do
              [[ -z "$(vm_windows "$key")" ]] && return 0
              sleep 0.25
          done
          log_warn "Some ''${key} windows did not close (after ''${i} checks); stopping anyway"
      }

      cmd_stop() {
          local vm_name="$1"

          if ! is_running "$vm_name"; then
              # Builder special case: restore store and restart nix-daemon if needed
              if is_builder "$vm_name" && ! host_daemon_running; then
                  log "Builder not running, but restoring host state..."
                  # Check if store is still rw and remount ro
                  log "Remounting /nix/store as read-only..."
                  restore_store_ro || true
                  log "Restarting host nix-daemon..."
                  sudo systemctl start nix-daemon.socket
                  log_success "Host state restored"
              else
                  log_error "''${vm_name} is not running"
              fi
              return 1
          fi

          log "Stopping ''${BOLD}''${vm_name}''${NC}..."
          local start
          start=$(timer_start)

          is_headless "$vm_name" || close_vm_windows "$vm_name"
          sudo systemctl stop "microvm@''${vm_name}.service"

          # Wait for service to fully stop
          if ! wait_for_stop "$vm_name" 10; then
              log_error "Timeout waiting for service to stop cleanly"
              log "Attempting force kill..."
              sudo systemctl kill --signal=SIGKILL "microvm@''${vm_name}.service" 2>/dev/null || true
              sleep 1
          fi

          local stop_time
          stop_time=$(timer_end "$start")
          log_success "Stopped in ''${BOLD}''${stop_time}s''${NC}"

          # Kill host-side waypipe tunnel for this VM (graphical VMs only).
          if ! is_headless "$vm_name"; then
              local _cid
              _cid=$(get_cid "$vm_name" 2>/dev/null || true)
              if [[ -n "$_cid" ]]; then
                  local _port=$(( 14600 + _cid - 100 ))
                  pkill -f "waypipe-connect ''${vm_name}$" 2>/dev/null || true
                  pkill -f "waypipe.*socket.*''${_port}" 2>/dev/null || true
                  sleep 0.3  # let processes die before caller starts a fresh tunnel
                  log "waypipe tunnel closed"
              fi
          fi

          # Lock encrypted home volume if open
          local mapper_name="vm-''${vm_name}-home"
          if [[ -b "/dev/mapper/''${mapper_name}" ]]; then
              log "Locking encrypted volume..."
              sudo cryptsetup luksClose "$mapper_name" || log "''${YELLOW}Warning: Could not lock encrypted volume''${NC}"
          fi

          # Deregister task slots from active-vms.json (only if still the active one)
          local slot_profile
          slot_profile=$(task_slot_profile "$vm_name")
          if [[ -n "$slot_profile" ]]; then
              local active_vms_file="$HOME/.cache/hydrix/active-vms.json"
              if [[ -f "$active_vms_file" ]]; then
                  local tmp
                  tmp=$(mktemp)
                  jq --arg p "$slot_profile" --arg vm "$vm_name" 'if .[$p] == $vm then del(.[$p]) else . end' \
                      "$active_vms_file" > "$tmp" && mv "$tmp" "$active_vms_file"
              fi
          fi

          # Builder VM: remount store read-only and restart host nix-daemon
          if is_builder "$vm_name"; then
              log "Remounting /nix/store as read-only..."
              # Wait a moment for virtiofsd to release the mount
              sleep 1
              restore_store_ro || true
              log "Restarting host nix-daemon..."
              sudo systemctl start nix-daemon.socket
              log_success "Host nix-daemon restarted"
          fi
      }

      # Restart microVM
      cmd_restart() {
          local vm_name="$1"
          engagement_prompt "$vm_name" || return 1

          # The host builder needs cmd_start/cmd_stop: they stop the host nix-daemon and
          # remount the store read-write around it. A plain service restart skipped both.
          if is_builder "$vm_name"; then
              if is_running "$vm_name"; then
                  cmd_stop "$vm_name" || return 1
              fi
              cmd_start "$vm_name"
              return
          fi

          check_tier_stores "$vm_name" || return 1
          log "Restarting ''${BOLD}''${vm_name}''${NC}..."
          local start
          start=$(timer_start)

          local cid
          cid=$(get_cid "$vm_name")
          if [[ -z "$cid" ]]; then
              log_error "Cannot get vsock CID for ''${vm_name}. Is it defined in the flake?"
              return 1
          fi

          if is_running "$vm_name"; then
              is_headless "$vm_name" || close_vm_windows "$vm_name"
              log "Stopping service..."
              sudo systemctl stop "microvm@''${vm_name}.service"

              # Wait for service to fully stop before starting again
              if ! wait_for_stop "$vm_name" 10; then
                  log_error "Timeout waiting for service to stop"
                  log "Attempting force kill..."
                  sudo systemctl kill --signal=SIGKILL "microvm@''${vm_name}.service" 2>/dev/null || true
                  sleep 1
              fi

              # Kill stale waypipe tunnel (wrapper + actual waypipe client by port)
              # so cmd_start opens a completely fresh tunnel after restart.
              local _port=$(( 14600 + cid - 100 ))
              pkill -f "waypipe-connect ''${vm_name}$" 2>/dev/null || true
              pkill -f "waypipe.*socket.*''${_port}" 2>/dev/null || true
              sleep 0.3
          fi

          ensure_unlocked "$vm_name" || return 1
          tier_view_sync "$vm_name" exact || return 1

          log "Starting service..."
          sudo systemctl start "microvm@''${vm_name}.service"

          # Headless VMs (router, builder) - no display forwarding
          if is_headless "$vm_name"; then
              local total_time
              total_time=$(timer_end "$start")
              log_success "Restarted in ''${BOLD}''${total_time}s''${NC}"
              echo ""
              echo -e "  ''${DIM}Console:''${NC} shard console ''${vm_name}"
              return 0
          fi

          # Graphical VMs - wait for display-mode service (vsock:14509)
          log "Waiting for VM display service..."
          local dm_elapsed=0
          local dm_ready=0
          while [[ $dm_elapsed -lt 60 ]]; do
              if vsock_query "$cid" "$DISPLAY_MODE_PORT" "PING" 2 3 2>/dev/null | grep -q "OK"; then
                  dm_ready=1
                  break
              fi
              sleep 0.5
              dm_elapsed=$((dm_elapsed + 1))
          done

          if [[ $dm_ready -eq 0 ]]; then
              log_error "Timeout waiting for VM display service"
              log "Check logs with: shard logs ''${vm_name}"
              return 1
          fi

          local total_time
          total_time=$(timer_end "$start")
          log_success "Restarted in ''${BOLD}''${total_time}s''${NC}"

          local profile
          profile=$(jq -r --arg v "$vm_name" 'to_entries[] | select(.value.vmName == $v) | .key' \
              "$VM_REGISTRY" 2>/dev/null | head -1)
          [[ -z "$profile" ]] && profile="''${vm_name#microvm-}"

          # In waypipe mode (Wayland): push waypipe mode to VM, wait for it to settle,
          # then connect the host-side tunnel.
          local _waypipe_started=0
          if [[ -n "''${WAYLAND_DISPLAY:-}" ]] && command -v waypipe-connect >/dev/null 2>&1; then
              local vm_ws
              vm_ws=$(jq -r --arg p "$profile" '.[$p].workspace // empty' \
                  /etc/hydrix/vm-registry.json 2>/dev/null)
              if [[ -n "$vm_ws" ]]; then
                  connect_waypipe_tunnel "$vm_name" "$cid"
                  _waypipe_started=1
              fi
          fi

          # Fallback display-mode push (waypipe path above already handles the common case)
          if [[ "$_waypipe_started" -eq 0 ]] && command -v vm-push-display-mode >/dev/null 2>&1; then
              vm-push-display-mode "$profile" >/dev/null 2>&1 &
              disown
          fi

          # Desktop notification
          if [[ "$_waypipe_started" -eq 1 ]]; then
              notify-send -u normal "MicroVM restarted" \
                  "''${vm_name} ready, WS''${vm_ws} apps available (Mod+Return)" 2>/dev/null || true
          else
              notify-send "MicroVM Ready" "''${vm_name} is ready for interaction" 2>/dev/null || true
          fi
      }

      # Launch app
      cmd_app() {
          local vm_name="$1"
          shift
          local app_cmd="$*"

          if ! is_running "$vm_name"; then
              log_error "''${vm_name} is not running. Start it first: shard start ''${vm_name}"
              return 1
          fi

          log "Launching ''${BOLD}''${app_cmd}''${NC} on ''${vm_name}..."
          local start
          start=$(timer_start)

          local VM_REGISTRY="/etc/hydrix/vm-registry.json"

          if [[ -n "''${WAYLAND_DISPLAY:-}" ]] && command -v waypipe-connect >/dev/null 2>&1; then
              # Wayland: route via waypipe
              local cid
              cid=$(jq -r --arg v "$vm_name" \
                  'to_entries[] | select(.value.vmName == $v) | .value.cid' \
                  "$VM_REGISTRY" 2>/dev/null | head -1)
              if [[ -z "$cid" ]]; then
                  log_error "Cannot resolve CID for $vm_name"
                  return 1
              fi
              local ready=0
              for _i in $(seq 1 20); do
                  local st
                  st=$(vsock_query "$cid" "$DISPLAY_MODE_PORT" "STATUS" 3 5 2>/dev/null || true)
                  [[ "$st" == "waypipe" ]] && { ready=1; break; }
                  sleep 0.5
              done
              if [[ "$ready" -eq 0 ]]; then
                  log_error "waypipe not ready in $vm_name, is waypipe-connect running?"
                  return 1
              fi
              vsock_query "$cid" "$WAYPIPE_LAUNCH_PORT" "$app_cmd" 10 15
          else
              log_error "waypipe-connect not available, cannot launch app in $vm_name"
              return 1
          fi

          local launch_time
          launch_time=$(timer_end "$start")
          log_time "App launched in ''${BOLD}''${launch_time}s''${NC}"
      }

      # Show status
      cmd_status() {
          local vm_name="''${1:-}"

          if [[ -n "$vm_name" ]]; then
              local eng
              eng=$(engagement_of_slot "$vm_name")
              if [[ -n "$eng" ]]; then
                  echo -e "''${BOLD}Engagement:''${NC} $eng, windows show [$(vm_label "$vm_name")]"
                  echo ""
              fi
              # Exits 3 for a stopped VM, which is a status, not a failure
              systemctl status "microvm@''${vm_name}.service" --no-pager || true

              # If running, also show switch status
              if is_running "$vm_name" && ! is_headless "$vm_name"; then
                  local cid
                  cid=$(get_cid "$vm_name" 2>/dev/null || echo "")
                  if [[ -n "$cid" ]]; then
                      local switch_status
                      switch_status=$(vsock_query "$cid" "$SWITCH_PORT" "STATUS" 5 10 2>/dev/null || true)
                      if [[ -n "$switch_status" ]]; then
                          echo ""
                          echo -e "''${BOLD}Live Switch Status''${NC}"
                          while IFS= read -r line; do
                              case "$line" in
                                  CURRENT\ *) echo -e "  Current: ''${CYAN}''${line#CURRENT }''${NC}" ;;
                                  BOOTED\ *)  echo -e "  Booted:  ''${DIM}''${line#BOOTED }''${NC}" ;;
                                  PROFILE\ *) echo -e "  Profile: ''${DIM}''${line#PROFILE }''${NC}" ;;
                              esac
                          done <<< "$switch_status"

                          # Show host-side built path
                          local host_path
                          host_path=$(get_current_system_path "$vm_name" 2>/dev/null || echo "")
                          if [[ -n "$host_path" ]]; then
                              echo -e "  Built:   ''${GREEN}''${host_path}''${NC}"
                          fi
                      fi
                  fi
              fi
          else
              echo -e "''${BOLD}MicroVM Status''${NC}"
              echo ""

              if [[ ! -f "$VM_REGISTRY" ]]; then
                  echo "VM registry not found, run 'rebuild' first"
                  return
              fi

              # vm-registry.json is already host-scoped (written by 'rebuild' for
              # this machine only), so no per-machine router filtering is needed
              # here, unlike a flake eval, which would return every machine's
              # nixosConfigurations.
              local declared
              declared=$(jq -r '.[] | "\(.vmName) \(.cid) \(.taskSlot // "-")"' "$VM_REGISTRY" 2>/dev/null | sort -u)

              if [[ -z "$declared" ]]; then
                  echo "No microVMs declared"
                  return
              fi

              # Pad plain text before colouring it: printf counts escape bytes as width
              local w
              w=$(awk '{ if (length($1) > m) m = length($1) } END { print m }' <<< "$declared")
              printf "  ''${DIM}%-*s %-8s %-4s %s''${NC}\n" "$w" "NAME" "STATUS" "CID" "ENGAGEMENT"

              while IFS=' ' read -r vm cid slot; do
                  local status eng_str=""
                  # Bound task slots: the engagement and the label their windows show
                  if [[ "$slot" != "-" ]]; then
                      local eng
                      eng=$(engagement_of_slot "$vm")
                      [[ -n "$eng" ]] && eng_str="$eng [$(vm_label "$vm")]"
                  fi
                  if is_running "$vm"; then
                      status="''${GREEN}running ''${NC}"
                  else
                      status="''${DIM}stopped ''${NC}"
                  fi
                  printf "  %-*s %s %-4s %s\n" "$w" "$vm" "$status" "$cid" "$eng_str"
              done <<< "$declared"

              local orphans_raw orphan_count=0
              if orphans_raw=$(_gc_find_orphans 2>/dev/null); then
                  orphan_count=$(echo "$orphans_raw" | grep -c . || true)
              fi
              if [[ "$orphan_count" -gt 0 ]]; then
                  echo ""
                  echo -e "  ''${YELLOW}''${orphan_count} orphaned VM director$([[ "$orphan_count" -eq 1 ]] && echo y || echo ies) with no matching flake VM''${NC} - run ''${BOLD}shard gc''${NC} to review"
              fi
          fi
      }

      # List declared microVMs
      cmd_list() {
          if [[ ! -f "$VM_REGISTRY" ]]; then
              echo "VM registry not found, run 'rebuild' first"
              return
          fi
          jq -r '.[].vmName' "$VM_REGISTRY" 2>/dev/null | sort -u
      }

      # View logs
      cmd_logs() {
          local vm_name="$1"
          sudo journalctl -u "microvm@''${vm_name}.service" -f --no-pager
      }

      # Attach to console (for headless VMs like router, builder)
      cmd_console() {
          local vm_name="$1"

          if ! is_running "$vm_name"; then
              log_error "''${vm_name} is not running"
              return 1
          fi

          local console_sock="/var/lib/microvms/''${vm_name}/console.sock"
          if [[ ! -S "$console_sock" ]]; then
              log_error "Console socket not found: $console_sock"
              return 1
          fi

          # Reattaching over the serial socket lands on the getty session that's
          # been logged in (autologin) since boot - login's own MOTD print already
          # fired once and won't fire again. Re-fetch it straight from the flake
          # instead (users.motd is just a string in the VM's config) so it still
          # shows on every attach; empty/missing for VMs with no motd set.
          local motd
          motd=$(nix eval --raw "$FLAKE_DIR#nixosConfigurations.''${vm_name}.config.users.motd" 2>/dev/null || true)
          [[ -n "$motd" ]] && printf '%s\n' "$motd"

          # screen can't attach to console.sock directly - it's a UNIX socket, not
          # a character device, so screen's serial-line detection never fires and
          # it tries (and fails) to exec the socket path as a command instead.
          log "Attaching to ''${BOLD}''${vm_name}''${NC} console (Ctrl+] to detach)..."
          TERM=linux sudo socat -,rawer,escape=0x1d "UNIX-CONNECT:''${console_sock}"
      }

      # Builder: check status
      cmd_builder_status() {
          echo -e "''${BOLD}Builder Status''${NC}"
          echo ""

          if is_running "$BUILDER_NAME"; then
              echo -e "VM Status: ''${GREEN}running''${NC}"

              # Query builder status
              local status
              status=$(vsock_query "$BUILDER_CID" "$BUILDER_STATUS_PORT" "STATUS" 5 8 2>/dev/null || echo "unreachable")
              echo "Builder: $status"
          else
              echo -e "VM Status: ''${DIM}stopped''${NC}"
          fi

          echo ""
          if host_daemon_running; then
              echo -e "Host nix-daemon: ''${GREEN}running''${NC}"
          else
              echo -e "Host nix-daemon: ''${YELLOW}stopped''${NC} (normal when builder is active)"
          fi

          # Check for lockdown mode
          if [[ -f /etc/LOCKDOWN_MODE ]]; then
              echo ""
              echo -e "Mode: ''${YELLOW}LOCKDOWN''${NC} - host has no internet"
              echo "  Builder can fetch packages via router VM"
          fi
      }

      # Backups: stopped-VM copies of every persistent volume, LUKS containers included
      # (copied still encrypted). cp --reflink=auto clones extents on btrfs (the @microvms
      # subvolume, nodatacow on both sides so the clone is allowed), making create and restore
      # instant; elsewhere it is a full, hole-preserving copy. On btrfs a backup shares
      # blocks with the live volume: a rollback point, not protection against disk loss.
      readonly BACKUP_ROOT="/var/lib/microvms/.backups"

      # Persistent volumes in a VM directory; nix-overlay is rebuilt from the store, so skipped
      backup_volumes() {
          local f
          for f in "$1"/*.qcow2 "$1"/*.luks "$1"/*.img; do
              [[ -f "$f" && ! -L "$f" && "$(basename "$f")" != "nix-overlay.qcow2" ]] && echo "$f"
          done
          return 0
      }

      backup_is_btrfs() {
          [[ "$(stat -f -c %T /var/lib/microvms 2>/dev/null)" == "btrfs" ]]
      }

      # backup_space_ok <file>...: room for a full copy, always true on btrfs (reflinks)
      backup_space_ok() {
          backup_is_btrfs && return 0
          local need avail
          need=$(sudo du -cB1 "$@" | tail -1 | cut -f1)
          avail=$(df -B1 --output=avail /var/lib/microvms | tail -1 | tr -d ' ')
          if (( need >= avail )); then
              log_error "Not enough space: need $(numfmt --to=iec "$need"), $(numfmt --to=iec "$avail") free"
              return 1
          fi
      }

      # Volumes are only consistent with the VM stopped and its LUKS mapping closed
      backup_vm_idle() {
          local vm_name="$1"
          if is_running "$vm_name"; then
              log_error "''${vm_name} is running. Stop it first: shard -S ''${vm_name}"
              return 1
          fi
          if [[ -b "/dev/mapper/vm-''${vm_name}-home" ]]; then
              log_error "Encrypted volume of ''${vm_name} is still unlocked (/dev/mapper/vm-''${vm_name}-home)"
              log "Lock it with: sudo cryptsetup luksClose vm-''${vm_name}-home"
              return 1
          fi
      }

      backup_meta() {
          sudo cat "$1/meta" 2>/dev/null | sed -n "s/^$2=//p" || true
      }

      backup_create() {
          local vm_name="$1" name="''${2:-}"
          [[ -z "$name" ]] && name=$(date +%F-%H%M%S)
          local vm_dir="/var/lib/microvms/''${vm_name}"
          local dest="''${BACKUP_ROOT}/''${vm_name}/''${name}"

          if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ || "$name" == *.partial ]]; then
              log_error "Invalid backup name: $name (letters, digits, '.', '_', '-')"
              return 1
          fi
          local vols
          vols=$(backup_volumes "$vm_dir")
          if [[ -z "$vols" ]]; then
              log_error "No persistent volumes found for ''${vm_name} in $vm_dir"
              return 1
          fi
          backup_vm_idle "$vm_name" || return 1
          if sudo test -e "$dest"; then
              log_error "Backup $name of ''${vm_name} already exists"
              return 1
          fi
          local -a files
          mapfile -t files <<< "$vols"
          backup_space_ok "''${files[@]}" || return 1

          local mode="full copy"
          backup_is_btrfs && mode="btrfs reflink"
          log "Backing up ''${BOLD}''${vm_name}''${NC} as ''${BOLD}''${name}''${NC} (''${mode})..."

          # Copied into <name>.partial and renamed at the end, so an interrupted
          # copy never lists as a backup; leftovers are cleared on the next create
          # Listable without sudo (backup_notices), each backup itself root-only
          sudo install -d -m 755 "$BACKUP_ROOT" "''${BACKUP_ROOT}/''${vm_name}"
          sudo find "''${BACKUP_ROOT}/''${vm_name}" -mindepth 1 -maxdepth 1 -name '*.partial' -exec rm -rf -- {} +
          sudo install -d -m 700 "''${dest}.partial"
          local f
          for f in "''${files[@]}"; do
              echo -e "  ''${DIM}$(basename "$f")''${NC}"
              if ! sudo cp --reflink=auto --preserve=mode,ownership,timestamps -- "$f" "''${dest}.partial/"; then
                  sudo rm -rf -- "''${dest}.partial"
                  log_error "Copy of $f failed, backup discarded"
                  return 1
              fi
          done
          printf 'created=%s\nengagement=%s\n' "$(date '+%F %T')" "$(engagement_of_slot "$vm_name")" \
              | sudo tee "''${dest}.partial/meta" >/dev/null
          sudo mv -T -- "''${dest}.partial" "$dest"
          log_success "Backup created: $dest"
      }

      backup_list() {
          local vm_filter="''${1:-}" vm_dir backup any=0
          printf "''${BOLD}%-40s %-24s %-20s %8s''${NC}\n" "VM" "BACKUP" "CREATED" "SIZE"
          while IFS= read -r vm_dir; do
              [[ -n "$vm_filter" && "$(basename "$vm_dir")" != "$vm_filter" ]] && continue
              while IFS= read -r backup; do
                  any=1
                  printf "%-40s %-24s %-20s %8s\n" "$(basename "$vm_dir")" "$(basename "$backup")" \
                      "$(backup_meta "$backup" created)" "$(sudo du -sh "$backup" | cut -f1)"
              done < <(sudo find "$vm_dir" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' | sort)
          done < <(sudo find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
          [[ $any -eq 0 ]] && echo -e "  ''${DIM}(no backups)''${NC}"
          backup_is_btrfs && echo -e "\n  ''${DIM}Sizes on btrfs include blocks shared with the live volumes.''${NC}"
          return 0
      }

      backup_restore() {
          local vm_name="$1" name="$2" force="''${3:-}"
          local vm_dir="/var/lib/microvms/''${vm_name}"
          local src="''${BACKUP_ROOT}/''${vm_name}/''${name}"

          if ! sudo test -d "$src" || [[ "$name" == *.partial || "$name" == */* ]]; then
              log_error "No backup $name for ''${vm_name} (see: shard backup list ''${vm_name})"
              return 1
          fi
          if [[ ! -d "$vm_dir" ]]; then
              log_error "$vm_dir does not exist. Build the VM first: shard -b ''${vm_name}"
              return 1
          fi
          backup_vm_idle "$vm_name" || return 1

          # A task slot's data belongs to one engagement; never restore it into another's slot
          local saved current
          saved=$(backup_meta "$src" engagement)
          current=$(engagement_of_slot "$vm_name")
          if [[ "$saved" != "$current" ]]; then
              log_error "Backup belongs to engagement ''${saved:-none}, ''${vm_name} is bound to ''${current:-none}"
              [[ -n "$saved" ]] && log "Bind it first: shard pentest ''${saved}"
              return 1
          fi

          local -a files
          mapfile -t files < <(sudo find "$src" -mindepth 1 -maxdepth 1 -type f ! -name meta -printf '%f\n' | sort)
          if [[ ''${#files[@]} -eq 0 ]]; then
              log_error "Backup $name contains no volumes"
              return 1
          fi

          echo -e "''${YELLOW}Restoring ''${BOLD}''${name}''${NC}''${YELLOW} over the current volumes of ''${BOLD}''${vm_name}''${NC}''${YELLOW}:''${NC}"
          local f
          for f in "''${files[@]}"; do
              if [[ -f "$vm_dir/$f" ]]; then echo "  $f (replaces current)"; else echo "  $f (new)"; fi
          done
          while IFS= read -r f; do
              [[ -z "$f" ]] && continue
              [[ " ''${files[*]} " == *" $(basename "$f") "* ]] || log_warn "$(basename "$f") is not in the backup, left as is"
          done <<< "$(backup_volumes "$vm_dir")"
          if grep -q "/dev/mapper/vm-''${vm_name}-home" "$vm_dir/current/bin/microvm-run" 2>/dev/null; then
              [[ " ''${files[*]} " == *" home.luks "* ]] || log_warn "The built VM expects an encrypted home, this backup has no home.luks"
          elif [[ " ''${files[*]} " == *" home.luks "* ]]; then
              log_warn "This backup has an encrypted home, the built VM does not use encryption"
          fi
          echo ""

          if [[ "$force" != "--force" && "$force" != "-f" ]]; then
              echo -e "''${RED}Current data in these volumes will be lost.''${NC}"
              read -rp "Type 'yes' to confirm: " confirm
              [[ "$confirm" != "yes" ]] && { log "Aborted"; return 1; }
          fi

          local -a paths=()
          for f in "''${files[@]}"; do paths+=("$src/$f"); done
          backup_space_ok "''${paths[@]}" || return 1

          # Each volume is copied next to the live one, then renamed over it
          for f in "''${files[@]}"; do
              if ! sudo cp --reflink=auto --preserve=mode,ownership,timestamps -- "$src/$f" "$vm_dir/$f.restore-tmp"; then
                  sudo rm -f -- "$vm_dir/$f.restore-tmp"
                  log_error "Copy of $f failed; volumes already restored stay restored"
                  return 1
              fi
              sudo mv -f -T -- "$vm_dir/$f.restore-tmp" "$vm_dir/$f"
          done
          log_success "Restored ''${vm_name} from ''${name}"
          echo -e "  ''${DIM}Start with:''${NC} shard -s ''${vm_name}"
      }

      backup_delete() {
          local vm_name="$1" name="$2" force="''${3:-}"
          local target="''${BACKUP_ROOT}/''${vm_name}/''${name}"
          if [[ -z "$name" || "$name" == */* || "$name" == .* ]] || ! sudo test -d "$target"; then
              log_error "No backup $name for ''${vm_name} (see: shard backup list ''${vm_name})"
              return 1
          fi
          if [[ "$force" != "--force" && "$force" != "-f" ]]; then
              echo -e "''${YELLOW}Delete backup ''${BOLD}''${name}''${NC}''${YELLOW} of ''${vm_name}?''${NC}"
              read -rp "Type 'yes' to confirm: " confirm
              [[ "$confirm" != "yes" ]] && { log "Aborted"; return 1; }
          fi
          sudo rm -rf -- "$target"
          sudo rmdir -- "''${BACKUP_ROOT}/''${vm_name}" 2>/dev/null || true
          log_success "Deleted backup $name of ''${vm_name}"
      }

      # EXIT trap: one warning per VM this run touched that has backups, so they are
      # not left to pile up unnoticed
      backup_notices() {
          local file="''${BACKUP_NOTICE_FILE:-}" vm dir b count oldest
          [[ -n "$file" && -s "$file" ]] || { [[ -n "$file" ]] && rm -f "$file"; return 0; }
          while IFS= read -r vm; do
              dir="''${BACKUP_ROOT}/''${vm}"
              [[ -d "$dir" ]] || continue
              count=0 oldest=""
              while IFS= read -r b; do
                  count=$((count + 1))
                  [[ -z "$oldest" ]] && oldest=$(stat -c %y "$b" | cut -d' ' -f1)
              done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '*.partial' -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
              (( count > 0 )) || continue
              log_warn "''${vm} has ''${count} backup$( (( count > 1 )) && echo s) (oldest ''${oldest}): shard backup list ''${vm}" >&2
          done < <(sort -u "$file")
          rm -f "$file"
          return 0
      }

      cmd_backup() {
          local action="''${1:-help}"
          case "$action" in
              create)
                  [[ -z "''${2:-}" ]] && { log_error "Usage: shard backup create <vm> [name]"; return 1; }
                  backup_create "$2" "''${3:-}"
                  ;;
              list) backup_list "''${2:-}" ;;
              restore)
                  [[ -z "''${3:-}" ]] && { log_error "Usage: shard backup restore <vm> <name> [-f]"; return 1; }
                  backup_restore "$2" "$3" "''${4:-}"
                  ;;
              delete)
                  [[ -z "''${3:-}" ]] && { log_error "Usage: shard backup delete <vm> <name> [-f]"; return 1; }
                  backup_delete "$2" "$3" "''${4:-}"
                  ;;
              *)
                  echo -e "''${BOLD}shard backup''${NC} - Back up and restore a VM's persistent volumes"
                  echo ""
                  echo "  create <vm> [name]          Back up every volume (VM stopped; name defaults to a timestamp)"
                  echo "  list [vm]                   List backups"
                  echo "  restore <vm> <name> [-f]    Replace the VM's volumes with a backup (VM stopped)"
                  echo "  delete <vm> <name> [-f]     Delete a backup"
                  echo ""
                  echo "Stored in $BACKUP_ROOT/<vm>/<name>/. nix-overlay.qcow2 is skipped (rebuilt"
                  echo "from the store); LUKS containers stay encrypted. On btrfs, create and restore"
                  echo "are instant reflinks sharing blocks with the live volumes; elsewhere they"
                  echo "are full copies. Every shard command on a VM with backups lists them on exit."
                  ;;
          esac
      }

      # Full workflow test with timing
      cmd_test() {
          local vm_name="$1"

          echo -e "''${BOLD}''${CYAN}═══════════════════════════════════════════════════''${NC}"
          echo -e "''${BOLD}''${CYAN}  MicroVM Full Workflow Test: ''${vm_name}''${NC}"
          echo -e "''${BOLD}''${CYAN}═══════════════════════════════════════════════════''${NC}"
          echo ""

          local total_start
          total_start=$(timer_start)

          # Build
          echo -e "''${BOLD}[1/4] BUILD''${NC}"
          cmd_build "$vm_name"
          echo ""

          # Start
          echo -e "''${BOLD}[2/4] START''${NC}"
          cmd_start "$vm_name"
          echo ""

          # Launch test app
          echo -e "''${BOLD}[3/4] APP LAUNCH''${NC}"
          cmd_app "$vm_name" alacritty
          echo ""

          # Summary
          local total_time
          total_time=$(timer_end "$total_start")

          echo -e "''${BOLD}[4/4] SUMMARY''${NC}"
          echo -e "''${GREEN}═══════════════════════════════════════════════════''${NC}"
          echo -e "  Total workflow time: ''${BOLD}''${total_time}s''${NC}"
          echo -e "''${GREEN}═══════════════════════════════════════════════════''${NC}"
          echo ""
          echo -e "  ''${DIM}Stop with:''${NC} shard stop ''${vm_name}"
      }

      # Purge microVM (delete all persistent data)
      cmd_purge() {
          local vm_name="$1"
          local force="''${2:-}"
          local vm_dir="/var/lib/microvms/''${vm_name}"

          if [[ ! -d "$vm_dir" ]]; then
              log_error "No data found for ''${vm_name}"
              log_error "Path: $vm_dir"
              return 1
          fi

          # Stop if running
          if is_running "$vm_name"; then
              log "Stopping ''${vm_name} first..."
              cmd_stop "$vm_name"
          fi

          # Show what will be deleted
          echo -e "''${YELLOW}This will delete all persistent data for ''${BOLD}''${vm_name}''${NC}''${YELLOW}:''${NC}"
          echo ""
          ls -lh "$vm_dir"/*.qcow2 "$vm_dir"/*.luks 2>/dev/null || echo "  (no data files found)"
          echo ""

          # Calculate total size
          local total_size
          total_size=$(du -sh "$vm_dir" 2>/dev/null | cut -f1)
          echo -e "  Total size: ''${BOLD}''${total_size}''${NC}"
          echo ""

          # Confirm unless --force
          if [[ "$force" != "--force" && "$force" != "-f" ]]; then
              echo -e "''${RED}Are you sure? This cannot be undone.''${NC}"
              read -rp "Type 'yes' to confirm: " confirm
              if [[ "$confirm" != "yes" ]]; then
                  log "Aborted"
                  return 1
              fi
          fi

          log "Purging ''${BOLD}''${vm_name}''${NC}..."

          # Delete qcow2 files and encrypted volumes
          sudo rm -f "$vm_dir"/*.qcow2 "$vm_dir"/*.luks

          # Delete socket files and other runtime state
          sudo rm -f "$vm_dir"/console.sock 2>/dev/null || true

          log_success "Purged ''${vm_name}"
          echo ""
          echo -e "  ''${DIM}Rebuild with:''${NC} shard build ''${vm_name}"
          echo -e "  ''${DIM}The VM will start fresh with a new home volume.''${NC}"
      }

      # Prints orphaned VM directory names (one per line): dirs under /var/lib/microvms/
      # with no matching nixosConfiguration in the current flake. Shared by cmd_gc
      # (interactive) and cmd_gc_check (cache-writing, for waybar/eww). Returns 1 if
      # the flake couldn't be evaluated at all (caller decides how to handle that).
      _gc_find_orphans() {
          local declared
          declared=$(nix eval --json "''${FLAKE_DIR}#nixosConfigurations" --apply builtins.attrNames 2>/dev/null) || return 1

          local dir name
          for dir in /var/lib/microvms/*/; do
              [[ -d "$dir" ]] || continue
              name=$(basename "$dir")
              echo "$declared" | jq -e --arg n "$name" 'index($n) != null' >/dev/null 2>&1 || echo "$name"
          done
      }

      # Writes orphan count + names to a cache file for waybar/eww to read cheaply
      # (they poll far more often than a fresh `nix eval` is worth doing). Called
      # periodically by the hydrix-gc-check user timer; never deletes anything.
      cmd_gc_check() {
          local cache="/tmp/hydrix-gc-status"
          local orphans_json
          orphans_json=$(_gc_find_orphans 2>/dev/null | jq -R . | jq -cs '{"count": length, "names": .}')
          echo "$orphans_json" > "''${cache}.tmp" && mv "''${cache}.tmp" "$cache"
      }

      # List (and optionally remove) /var/lib/microvms/<name>/ directories with no
      # corresponding nixosConfiguration in the current flake - leftovers from renamed,
      # removed, or one-off test VMs. Dry-run by default; deletes only with confirmation.
      cmd_gc() {
          local force="''${1:-}"

          log "Checking declared VMs against ''${FLAKE_DIR}#nixosConfigurations..."
          local orphans_raw
          if ! orphans_raw=$(_gc_find_orphans); then
              log_error "Could not evaluate nixosConfigurations from ''${FLAKE_DIR}"
              return 1
          fi

          local orphans=()
          local name
          while IFS= read -r name; do
              [[ -n "$name" ]] && orphans+=("$name")
          done <<< "$orphans_raw"

          if [[ ''${#orphans[@]} -eq 0 ]]; then
              log_success "No orphaned VM directories found."
              return 0
          fi

          echo -e "''${YELLOW}Found ''${#orphans[@]} director$([[ ''${#orphans[@]} -eq 1 ]] && echo y || echo ies) with no matching VM in the current flake:''${NC}"
          echo ""
          for name in "''${orphans[@]}"; do
              local size mtime
              size=$(du -sh "/var/lib/microvms/''${name}" 2>/dev/null | cut -f1)
              mtime=$(stat -c '%y' "/var/lib/microvms/''${name}" 2>/dev/null | cut -d' ' -f1)
              printf "  %-40s %8s   %s\n" "$name" "$size" "$mtime"
          done
          echo ""

          if [[ "$force" != "--force" && "$force" != "-f" ]]; then
              echo -e "''${RED}This cannot be undone.''${NC}"
              read -rp "Delete all of the above? Type 'yes' to confirm: " confirm
              if [[ "$confirm" != "yes" ]]; then
                  log "Aborted"
                  return 1
              fi
          fi

          for name in "''${orphans[@]}"; do
              if is_running "$name"; then
                  log "Stopping ''${name} first..."
                  cmd_stop "$name"
              fi
              sudo rm -rf -- "/var/lib/microvms/''${name}"
              log_success "Removed ''${name}"
          done
      }

      # Set up LUKS-encrypted home volume for a microVM (Option C encryption)
      # Creates a raw LUKS container at /var/lib/microvms/<name>/home.luks
      # shard start/stop will open/close it automatically around the VM lifecycle
      cmd_encrypt_setup() {
          local vm_name="$1"
          local size_mb="''${2:-}"

          if [[ -z "$vm_name" ]]; then
              log_error "Usage: shard encrypt-setup <name> [size_mb]"
              return 1
          fi

          local vm_dir="/var/lib/microvms/''${vm_name}"
          local luks_path="''${vm_dir}/home.luks"
          local mapper_name="vm-''${vm_name}-home"

          if [[ -f "$luks_path" ]]; then
              log_error "Encrypted volume already exists at ''${luks_path}"
              log_error "Run 'shard start ''${vm_name}', it will prompt for the passphrase"
              return 1
          fi

          if is_running "$vm_name"; then
              log_error "Stop ''${vm_name} before setting up encryption"
              return 1
          fi

          # encrypt-setup only makes sense once the VM's config actually declares
          # encryption.enable = true, otherwise the LUKS container gets built and
          # the next 'shard build' just ignores it (home volume stays plain qcow2).
          local enc_enabled
          enc_enabled=$(nix eval --json "''${FLAKE_DIR}#nixosConfigurations.''${vm_name}.config.hydrix.microvm.encryption.enable" 2>/dev/null || echo "false")
          if [[ "$enc_enabled" != "true" ]]; then
              log_error "''${vm_name} does not have hydrix.microvm.encryption.enable = true in its config"
              log_error "Set it first (in the VM's profile/task default.nix), then run this again"
              return 1
          fi

          # Non-blocking: encryption is opt-in per-VM, so reaching this point means
          # it's already been decided (declared in config, or cmd_build auto-invoked
          # us), no need to gate on an extra confirmation for an existing qcow2.
          if [[ -f "''${vm_dir}/home.qcow2" ]]; then
              log_warn "Existing home.qcow2 found at ''${vm_dir}/home.qcow2, it will NOT be migrated, data inside will be inaccessible after this"
          fi

          # Determine size: prefer explicit arg, else derive from the VM's own declared
          # persistence.homeSize. Never guess a flat default here, that's exactly what
          # let a comms LUKS container balloon to 100GB when its real declared size is
          # 10GB (nobody passed a size, so it silently fell back to a 100GB constant).
          if [[ -z "$size_mb" ]]; then
              size_mb=$(nix eval --json "''${FLAKE_DIR}#nixosConfigurations.''${vm_name}.config.hydrix.microvm.persistence.homeSize" 2>/dev/null || echo "")
              if [[ -z "$size_mb" ]]; then
                  log_error "Could not determine ''${vm_name}'s declared homeSize from the flake"
                  log_error "Pass it explicitly: shard encrypt-setup ''${vm_name} <size_mb>"
                  return 1
              fi
              log "Using ''${vm_name}'s declared home volume size: ''${BOLD}''${size_mb} MB''${NC}"
          fi

          # Capture the passphrase once, twice for confirmation, then feed the same
          # confirmed bytes to both luksFormat and the immediately-following luksOpen
          # via stdin (--key-file=-), so cryptsetup never prompts on its own and
          # there's no repeated/third entry.
          log "Setting up encryption passphrase..."
          local pass1 pass2
          read -rs -p "Enter encryption passphrase: " pass1; echo >&2
          read -rs -p "Confirm encryption passphrase: " pass2; echo >&2
          if [[ "$pass1" != "$pass2" ]]; then
              log_error "Passphrases do not match"
              return 1
          fi
          if [[ -z "$pass1" ]]; then
              log_error "Passphrase cannot be empty"
              return 1
          fi

          log "Creating ''${size_mb} MB LUKS container at ''${luks_path}..."
          sudo mkdir -p "$vm_dir"
          if ! sudo fallocate -l "''${size_mb}M" "$luks_path"; then
              sudo rm -f "$luks_path"
              log_error "Failed to allocate ''${size_mb}MB at ''${luks_path} (out of disk space?)"
              return 1
          fi

          log "Formatting LUKS container..."
          if ! printf '%s' "$pass1" | sudo cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$luks_path"; then
              sudo rm -f "$luks_path"
              log_error "LUKS format failed"
              return 1
          fi

          log "Opening container to initialise filesystem..."
          if ! printf '%s' "$pass1" | sudo cryptsetup luksOpen --key-file=- "$luks_path" "$mapper_name"; then
              sudo rm -f "$luks_path"
              log_error "Could not open freshly formatted container"
              return 1
          fi
          unset pass1 pass2

          log "Creating ext4 filesystem..."
          sudo mkfs.ext4 -L "vm-''${vm_name}" "/dev/mapper/''${mapper_name}"

          log "Closing container..."
          sudo cryptsetup luksClose "$mapper_name"

          log_success "Encrypted volume ready at ''${luks_path}"
          if [[ "''${_HYDRIX_AUTO_ENCRYPT:-}" != "1" ]]; then
              echo ""
              echo -e "  ''${DIM}Next steps:''${NC}"
              echo -e "  1. Run ''${BOLD}shard build ''${vm_name}''${NC} to rebuild with the encrypted volume"
              echo -e "  2. Run ''${BOLD}shard start ''${vm_name}''${NC}, it will prompt for your passphrase"
          fi
      }

      # Get system toplevel path from current symlink
      get_current_system_path() {
          local vm_name="$1"
          local current="/var/lib/microvms/''${vm_name}/current"

          if [[ -L "$current" ]]; then
              # The current symlink points to the declaredRunner
              # We need share/microvm/system for the NixOS toplevel
              local runner_path
              runner_path=$(readlink -f "$current")
              local system_path="''${runner_path}/share/microvm/system"
              if [[ -d "$system_path" ]]; then
                  echo "$system_path"
                  return 0
              fi
          fi
          return 1
      }

      # Wait for switch service to be ready
      wait_for_switch_service() {
          local cid="$1"
          local timeout="''${2:-10}"
          local elapsed=0

          while ! vsock_query "$cid" "$SWITCH_PORT" "PING" 2 5 2>/dev/null | grep -q "PONG"; do
              sleep 0.5
              elapsed=$((elapsed + 1))
              if [[ $elapsed -ge $((timeout * 2)) ]]; then
                  return 1
              fi
          done
          return 0
      }

      # Live switch microVM to new configuration (without restart)
      cmd_switch() {
          local vm_name="$1"
          local path="''${2:-}"
          local explicit_path=1
          [[ -z "$path" ]] && explicit_path=0

          [[ -z "$vm_name" ]] && { log_error "Usage: shard switch <name> [path]"; return 1; }

          if ! is_running "$vm_name"; then
              log_error "''${vm_name} is not running. Use 'shard start' instead."
              return 1
          fi

          # Tier VM: its system and closure registration are in the tier store, which the VM
          # already sees through its store share (tierSystem links both, microvm-profile-base.nix).
          # The registration is copied as is, never parsed here: it was written by the tier's
          # builder and goes only to that tier's VM. The link targets are checked, and no
          # directory on the way may be a symlink: root copies the file, so a link could point
          # it at a host file.
          local tier reg_src=""
          tier=$(vm_store_tier "$vm_name")
          if [[ -n "$tier" ]]; then
              if [[ $explicit_path -eq 1 ]]; then
                  log_error "''${vm_name} runs from a store tier: it switches to its last build (no path)"
                  return 1
              fi
              local tier_root="''${TIER_STORES}/''${tier}" ts reg
              # shard -g switch passes a generation's system; otherwise the latest build's
              ts="''${_HYDRIX_SWITCH_TIER_SYSTEM:-}"
              [[ -n "$ts" ]] || ts=$(cat "/var/lib/microvms/''${vm_name}/tier-system" 2>/dev/null || true)
              path=$(readlink "''${tier_root}''${ts}/system" 2>/dev/null || true)
              reg=$(readlink "''${tier_root}''${ts}/registration" 2>/dev/null || true)
              reg_src="''${tier_root}''${reg}/registration"
              if [[ ! "$ts" =~ ^/nix/store/[a-z0-9]{32}-hydrix-tier-system$ \
                    || ! "$path" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-[A-Za-z0-9._-]+$ \
                    || ! "$reg" =~ ^/nix/store/[a-z0-9]{32}-closure-info$ \
                    || -L "''${tier_root}''${ts}" || -L "''${tier_root}''${reg}" \
                    || ! -f "$reg_src" || -L "$reg_src" ]]; then
                  log_error "No usable tier build recorded for ''${vm_name}: shard -b ''${vm_name}"
                  return 1
              fi
              # The running VM sees only its view: the new system goes in before the switch.
              tier_view_sync "$vm_name" add "$ts" || return 1
          fi

          local cid
          cid=$(get_cid "$vm_name")
          if [[ -z "$cid" ]]; then
              log_error "Cannot get vsock CID for ''${vm_name}"
              return 1
          fi

          # If no path provided, get from current symlink (this is what used to be
          # called "update": switch with no explicit path always means "apply the
          # config I already built").
          if [[ -z "$path" ]]; then
              path=$(get_current_system_path "$vm_name")
              if [[ -z "$path" ]]; then
                  log_error "No current symlink found. Run 'shard build $vm_name' first."
                  return 1
              fi
          fi

          log "Switching ''${BOLD}''${vm_name}''${NC} to: ''${path}"
          local start
          start=$(timer_start)

          # Check if switch service is ready
          if ! wait_for_switch_service "$cid" 5; then
              log_error "Switch service not responding. Is the VM running a configuration with vm-switch?"
              return 1
          fi

          # Dump nix DB registration for new closure paths so VM can register them.
          # Without this, the VM's nix DB doesn't know about host-built store paths
          # and home-manager activation fails during switch-to-configuration.
          local reg_file="/var/lib/microvms/''${vm_name}/config/.switch-reg"
          log "Registering store paths for VM..."
          local reg_start
          reg_start=$(timer_start)
          local reg_output
          if [[ -n "$reg_src" ]]; then
              if ! reg_output=$(sudo install -m 644 "$reg_src" "$reg_file" 2>&1); then
                  log_error "Failed to copy the tier registration for the VM"
                  [[ -n "$reg_output" ]] && echo -e "''${DIM}''${reg_output}''${NC}"
                  return 1
              fi
          elif ! reg_output=$(nix-store -qR "$path" | xargs nix-store --dump-db | sudo tee "$reg_file" 2>&1 >/dev/null); then
              log_error "Failed to register store paths for VM, home-manager activation may fail during switch"
              [[ -n "$reg_output" ]] && echo -e "''${DIM}''${reg_output}''${NC}"
              return 1
          fi
          local reg_time
          reg_time=$(timer_end "$reg_start")
          log_time "Registration dump in ''${BOLD}''${reg_time}s''${NC}"

          # Send switch command
          local result
          result=$(vsock_query "$cid" "$SWITCH_PORT" "SWITCH $path" 60 120 2>&1)
          # The VM only reads the dump (its share is read-only); remove it here.
          sudo rm -f "$reg_file"

          local switch_time
          switch_time=$(timer_end "$start")

          if [[ -z "$result" ]]; then
              log_error "No response from VM (timeout or connection closed)"
              log "Check VM logs: journalctl -u vm-switch --no-pager -n 20"
              return 1
          elif [[ "$result" == OK:* ]]; then
              # Extract first line (status) and rest (details)
              local first_line="''${result%%$'\n'*}"
              local details="''${result#*$'\n'}"
              local suffix=""
              [[ "$explicit_path" == 0 ]] && suffix=" (no restart required)"

              # Check if it's a partial success (some units failed)
              if [[ "$first_line" == *"some units failed"* ]]; then
                  log_warn "$first_line"
                  if [[ -n "$details" && "$details" != "$first_line" ]]; then
                      echo -e "''${DIM}''${details}''${NC}"
                  fi
                  log_time "Switched in ''${BOLD}''${switch_time}s''${NC} (with warnings)"
              else
                  log_success "$first_line"
                  log_time "Switched in ''${BOLD}''${switch_time}s''${NC}''${suffix}"
              fi
          else
              log_error "$result"
              return 1
          fi
      }

      # Query switch status from VM
      cmd_switch_status() {
          local vm_name="$1"
          [[ -z "$vm_name" ]] && { log_error "Usage: shard switch-status <name>"; return 1; }

          if ! is_running "$vm_name"; then
              log_error "''${vm_name} is not running"
              return 1
          fi

          local cid
          cid=$(get_cid "$vm_name")
          if [[ -z "$cid" ]]; then
              log_error "Cannot get vsock CID for ''${vm_name}"
              return 1
          fi

          log "Querying switch status for ''${BOLD}''${vm_name}''${NC}..."

          local result
          result=$(vsock_query "$cid" "$SWITCH_PORT" "STATUS" 10 15 2>&1)

          if [[ -z "$result" ]]; then
              log_error "No response from switch service"
              return 1
          fi

          echo ""
          echo -e "''${BOLD}Live System Status''${NC}"
          echo ""

          # Parse and display status
          while IFS= read -r line; do
              case "$line" in
                  CURRENT\ *)
                      echo -e "  Current: ''${CYAN}''${line#CURRENT }''${NC}"
                      ;;
                  BOOTED\ *)
                      echo -e "  Booted:  ''${DIM}''${line#BOOTED }''${NC}"
                      ;;
                  PROFILE\ *)
                      echo -e "  Profile: ''${DIM}''${line#PROFILE }''${NC}"
                      ;;
                  *)
                      echo "  $line"
                      ;;
              esac
          done <<< "$result"

          # Also show what's built on host
          local host_path
          host_path=$(get_current_system_path "$vm_name" 2>/dev/null || echo "")
          if [[ -n "$host_path" ]]; then
              echo ""
              echo -e "  Host:    ''${GREEN}''${host_path}''${NC}"
          fi
      }

      # Detect host machine config name (mirrors detect_machine_config in rebuild)
      detect_host_config() {
          local flake_dir="$FLAKE_DIR"
          local serial=""

          # 1) Serial number (primary, setup-hydrix names configs by serial)
          for path in /sys/class/dmi/id/product_serial \
                      /sys/class/dmi/id/board_serial \
                      /sys/class/dmi/id/chassis_serial; do
              serial=$(cat "$path" 2>/dev/null | xargs || echo "")
              local lower
              lower=$(echo "$serial" | tr '[:upper:]' '[:lower:]')
              case "$lower" in
                  ""|\
                  "to be filled by o.e.m."|\
                  "to be filled by o.e.m"|\
                  "default string"|\
                  "system serial number"|\
                  "not specified"|\
                  "none"|"n/a"|"na"|"unknown"|"undefined"|\
                  "chassis serial number"|\
                  "type2 - board serial number")
                      serial=""; continue ;;
              esac
              [[ "$lower" =~ ^0+$ ]] && { serial=""; continue; }
              [[ -n "$serial" ]] && break
          done

          if [[ -n "$serial" ]]; then
              serial=$(echo "$serial" | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
              serial=$(echo "$serial" | sed 's/[^a-z0-9-]//g; s/-\+/-/g; s/^-//; s/-$//')
              [[ ! "$serial" =~ ^[a-z0-9] ]] && serial="h-$serial"
              serial="''${serial:0:63}"
              if [[ -f "$flake_dir/machines/''${serial}.nix" ]]; then
                  echo "$serial"; return
              fi
          fi

          # 2) board_name -> mb-<name>
          local board_name board_id
          board_name=$(cat /sys/class/dmi/id/board_name 2>/dev/null | xargs || echo "")
          board_id=$(echo "$board_name" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | sed 's/[^a-z0-9-]//g; s/-\+/-/g; s/^-//; s/-$//')
          if [[ -n "$board_id" ]] && [[ "$board_id" != "default-string" ]] && [[ "$board_id" != "not-applicable" ]]; then
              if [[ -f "$flake_dir/machines/mb-''${board_id}.nix" ]]; then
                  echo "mb-''${board_id}"; return
              fi
          fi

          # 3) product_name -> prod-<name>, bare, mb-<name>
          local product_name sanitized
          product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null | xargs || echo "")
          if [[ -n "$product_name" ]]; then
              sanitized=$(echo "$product_name" | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
              sanitized=$(echo "$sanitized" | sed 's/[^a-z0-9-]//g; s/-\+/-/g; s/^-//; s/-$//')
              for candidate in "prod-''${sanitized}" "''${sanitized}" "mb-''${sanitized}"; do
                  if [[ -f "$flake_dir/machines/''${candidate}.nix" ]]; then
                      echo "$candidate"; return
                  fi
              done
          fi

          # 4) Single non-hardware config
          local configs=()
          for f in "$flake_dir"/machines/*.nix; do
              [[ ! -f "$f" ]] && continue
              local base
              base=$(basename "$f" .nix)
              [[ "$base" == *-hardware ]] && continue
              [[ "$base" == *-grub-entries ]] && continue
              configs+=("$base")
          done
          if [[ ''${#configs[@]} -eq 1 ]]; then
              echo "''${configs[0]}"; return
          fi

          # No match, fail loudly rather than silently using hostname
          log_error "Could not detect machine config in $flake_dir/machines/"
          log_error "Tried: serial, board_name, product_name, single-config fallback"
          return 1
      }

      # Resolve builder target to flake path
      # Uses fixed mount point for builder VM
      # Resolve a short target name (VM registry key, engagement name, infra
      # alias, or an already-full microvm-* name) to its real per-machine VM name.
      # Used by every host-side command, word or flag form alike.
      # Every VM name a command touches passes through here, so this is where VMs get
      # noted for the exit-time backup notice (backup_notices)
      resolve_vm_name() {
          local vm
          vm=$(_resolve_vm_name "$1")
          if [[ -n "$vm" && -n "''${BACKUP_NOTICE_FILE:-}" ]]; then
              echo "$vm" >> "$BACKUP_NOTICE_FILE"
          fi
          echo "$vm"
      }

      _resolve_vm_name() {
          local target="$1"
          case "$target" in
              router)
                  echo "$ROUTER_NAME"
                  ;;
              router-stable|stable-router|stable)
                  echo "$STABLE_ROUTER_NAME"
                  ;;
              builder)
                  echo "microvm-builder"
                  ;;
              gitsync)
                  echo "microvm-gitsync"
                  ;;
              files)
                  echo "microvm-files"
                  ;;
              vault)
                  echo "microvm-vault"
                  ;;
              task[0-9]*)
                  task_slot_vm "$target"
                  ;;
              micro*)
                  # Direct microVM name
                  echo "$target"
                  ;;
              host|.#*|*#*)
                  # Not a VM
                  echo ""
                  ;;
              *)
                  # Any key declared in vm-registry.json (any profile, current or future)
                  # resolves via the registry rather than needing to be listed here.
                  if [[ -f "$VM_REGISTRY" ]] && jq -e --arg k "$target" 'has($k)' "$VM_REGISTRY" >/dev/null 2>&1; then
                      registry_vm_name "$target"
                      return
                  fi
                  # Try engagement-name lookup (see ENGAGEMENTS_FILE) before
                  # falling back to prepending microvm-. Lets "shard -s google"
                  # resolve straight to the task slot the engagement is bound to.
                  local slot
                  slot=$(engagement_slot "$target" 2>/dev/null)
                  if [[ -n "$slot" ]]; then
                      echo "$slot"
                  elif [[ "$target" == microvm-* ]]; then
                      echo "$target"
                  else
                      echo "microvm-$target"
                  fi
                  ;;
          esac
      }

      # Resolve a target to a full builder-VM flake attribute path (declaredRunner
      # for VMs, system.build.toplevel for the host). Delegates VM-name resolution
      # to resolve_vm_name, so pentest engagement names and every registry key
      # work here too, not just the handful of infra names once hardcoded in this
      # function separately.
      resolve_builder_flake_attr() {
          local target="$1"
          # Inside builder VM, hydrix-config is mounted read-only at /mnt/hydrix
          local builder_flake="/mnt/hydrix"

          case "$target" in
              host)
                  local host_config
                  host_config=$(detect_host_config) || return 1
                  echo "''${builder_flake}#nixosConfigurations.''${host_config}.config.system.build.toplevel"
                  ;;
              .#*|*#*)
                  # Flake path - pass through as-is
                  echo "$target"
                  ;;
              *)
                  local vm_name
                  vm_name=$(resolve_vm_name "$target")
                  echo "''${builder_flake}#nixosConfigurations.''${vm_name}.$(vm_build_attr "$vm_name")"
                  ;;
          esac
      }

      # Builder: full workflow (start -> build all targets in VM -> stop -> host builds)
      # Accepts multiple targets - eval cache stays warm across builds in one session:
      #   shard builder build browsing pentest dev
      cmd_builder_build() {
          [[ $# -eq 0 ]] && { log_error "Usage: shard builder build <target> [target...]"; return 1; }
          local targets=("$@")

          local total_start
          total_start=$(timer_start)

          # Step 1: Start builder if not running
          if ! is_running "$BUILDER_NAME"; then
              log "Starting builder..."
              cmd_start "$BUILDER_NAME" || return 1
          else
              log "Builder already running"
          fi

          # Step 2: Build all targets in one builder session
          # Eval cache is warm after the first build - subsequent targets skip the 2+ min eval
          local failed_targets=()
          for target in "''${targets[@]}"; do
              local flake_target
              flake_target=$(resolve_builder_flake_attr "$target")
              log "Building ''${BOLD}''${target}''${NC}..."

              if ! builder_send_build "$BUILDER_CID" "BUILD $flake_target"; then
                  log_error "Build failed: ''${BOLD}''${target}''${NC}"
                  failed_targets+=("$target")
              fi
          done

          # Step 3: Stop builder (restores host nix-daemon and read-only store)
          log "Stopping builder..."
          cmd_stop "$BUILDER_NAME" || return 1

          # Step 4: Host-side registration for each successful target
          # Store is already populated - these complete in seconds
          log "Registering builds on host..."
          local host_failed=false
          for target in "''${targets[@]}"; do
              # Skip targets that failed in builder
              local skip=false
              for f in "''${failed_targets[@]}"; do [[ "$f" == "$target" ]] && skip=true && break; done
              $skip && continue

              if [[ "$target" == "host" ]]; then
                  local current_spec
                  current_spec=$(detect_current_specialisation)
                  log "Host config (specialisation: ''${BOLD}''${current_spec}''${NC})..."
                  local host_start
                  host_start=$(timer_start)
                  # --offline: lockdown has no network, so a path the builder did not produce
                  # fails at once instead of retrying every substituter.
                  local offline=()
                  [[ "$current_spec" == "lockdown" ]] && offline=(--offline)
                  if sudo --preserve-env=HYDRIX_BUILD_TIME,HYDRIX_BUILD_TAG nixos-rebuild build --flake "''${FLAKE_DIR}#$(detect_host_config)" --impure "''${offline[@]}"; then
                      log_time "Host build: ''${BOLD}$(timer_end "$host_start")s''${NC}"
                  else
                      log_error "Host build failed"
                      host_failed=true
                      continue
                  fi
                  echo ""
                  # Everything is in the store now, so rebuild applies it without network.
                  log "To apply:"
                  if [[ "$current_spec" == "lockdown" ]]; then
                      echo "  rebuild"
                  else
                      echo "  rebuild ''${current_spec}"
                  fi
              else
                  local vm_name
                  vm_name=$(resolve_vm_name "$target")
                  if [[ -n "$vm_name" ]]; then
                      _HYDRIX_BUILDER_FLOW=1 cmd_build "$vm_name" || { log_error "Host registration failed: ''${target}"; host_failed=true; }
                  else
                      local flake_target_check
                      flake_target_check=$(resolve_builder_flake_attr "$target")
                      if nix path-info "$flake_target_check" &>/dev/null; then
                          log_success "Path verified: ''${target}"
                      else
                          log_error "Built path not found on host: ''${target}"
                          host_failed=true
                      fi
                  fi
              fi
          done

          local total_time
          total_time=$(timer_end "$total_start")
          echo ""

          if [[ ''${#failed_targets[@]} -gt 0 ]] || $host_failed; then
              log_error "Completed with errors in ''${BOLD}''${total_time}s''${NC}"
              [[ ''${#failed_targets[@]} -gt 0 ]] && log_error "Builder failures: ''${failed_targets[*]}"
              return 1
          fi

          local count=''${#targets[@]}
          local label
          [[ $count -gt 1 ]] && label="''${count} targets: ''${targets[*]}" || label="''${targets[0]}"
          log_success "Build complete: ''${BOLD}''${label}''${NC} in ''${BOLD}''${total_time}s''${NC}"
      }

      # Builder: fetch only (prefetch deps, don't stop builder or build on host)
      cmd_builder_fetch() {
          local target="$1"
          [[ -z "$target" ]] && { log_error "Usage: shard builder fetch <target>"; return 1; }

          local flake_target
          flake_target=$(resolve_builder_flake_attr "$target")
          log "Target: ''${BOLD}''${target}''${NC} → ''${flake_target}"

          # Start builder if not running
          if ! is_running "$BUILDER_NAME"; then
              log "Starting builder..."
              cmd_start "$BUILDER_NAME" || return 1
          else
              log "Builder already running"
          fi

          # Prefetch via vsock
          log "Fetching in builder VM..."
          local fetch_output
          # Use -t600 to wait up to 10 minutes for remote to close after we send command
          fetch_output=$(vsock_query "$BUILDER_CID" "$BUILDER_BUILD_PORT" "BUILD $flake_target" 600 900 2>&1)

          # Parse and display output
          while IFS= read -r line; do
              case "$line" in
                  OK*)
                      log "$line"
                      ;;
                  RESULT\ *)
                      log_success "Result: ''${BOLD}''${line#RESULT }''${NC}"
                      ;;
                  DONE*)
                      log_success "$line"
                      ;;
                  ERROR*)
                      log_error "$line"
                      ;;
                  *)
                      [[ -n "$line" ]] && echo "  $line"
                      ;;
              esac
          done <<< "$fetch_output"

          if echo "$fetch_output" | grep -q "^ERROR"; then
              log_error "Fetch failed"
              return 1
          fi

          echo ""
          log "Fetch complete. Builder still running - use 'builder stop' when done."
      }

      # Builder: update flake inputs without host network (lockdown). The builder locks the
      # flake anew, puts the lock file in the store it shares with the host and sends its
      # path; the host checks it and writes flake.lock. The fetched sources are already in the
      # host store, so the next evaluation works offline. Usage: builder update [input ...]
      cmd_builder_update() {
          local started=0 rc=0 lock n changes
          local log_file="''${XDG_STATE_HOME:-$HOME/.local/state}/hydrix/last-build.log"
          for n in "$@"; do
              [[ "$n" =~ ^[A-Za-z0-9_-]+$ ]] || { log_error "Not an input name: $n"; return 1; }
          done
          if is_running "$BUILDER_NAME"; then
              log "Builder already running"
          else
              cmd_start "$BUILDER_NAME" || return 1
              started=1
          fi
          if ! wait_for_builder 90 "$BUILDER_CID"; then
              log_error "Timeout waiting for ''${BUILDER_NAME}"
              rc=1
          else
              log "Updating ''${BOLD}''${*:-every input}''${NC} in ''${BUILDER_NAME}..."
              builder_send_build "$BUILDER_CID" "UPDATE $*" || rc=1
          fi
          [[ $started -eq 1 ]] && { cmd_stop "$BUILDER_NAME" || rc=1; }
          [[ $rc -eq 0 ]] || { log_error "Flake update failed; flake.lock unchanged"; return 1; }

          lock=$(grep -m1 '^LOCK ' "$log_file" | cut -d' ' -f2 || true)
          if [[ -z "$lock" ]]; then
              if grep -q '^UNCHANGED' "$log_file"; then
                  log "flake.lock is already up to date"
                  return 0
              fi
              log_error "The builder sent no lock file"
              return 1
          fi
          # Untrusted reply: a store path of the expected name, holding a flake lock
          if [[ ! "$lock" =~ ^/nix/store/[0-9a-z]{32}-flake\.lock$ || ! -f "$lock" || -L "$lock" ]]; then
              log_error "The builder sent no usable lock file path"
              return 1
          fi
          if ! jq -e '(.version == 7) and (.root | type == "string") and (.nodes | type == "object")
                      and (.nodes[.root] | type == "object")' "$lock" >/dev/null 2>&1; then
              log_error "The builder's lock file is not a flake lock; flake.lock unchanged"
              return 1
          fi
          if cmp -s "$lock" "''${FLAKE_DIR}/flake.lock"; then
              log "flake.lock is already up to date"
              return 0
          fi
          changes=$(jq -r --slurpfile prev "''${FLAKE_DIR}/flake.lock" '
              ($prev[0].nodes // {}) as $o
              | .nodes | to_entries[] | select(.value.locked != null)
              | select(($o[.key].locked // null) != .value.locked)
              | "  \(.key): \(($o[.key].locked.rev // $o[.key].locked.narHash // "new")[0:12])"
                + " -> \((.value.locked.rev // .value.locked.narHash // "?")[0:12])"' "$lock" 2>/dev/null \
              | LC_ALL=C tr -d '\000-\010\013-\037\177' || true)
          install -m 644 "$lock" "''${FLAKE_DIR}/flake.lock"
          log_success "flake.lock updated"
          root_flake_inputs
          [[ -n "$changes" ]] && printf '%s\n' "$changes"
          return 0
      }

      # Builder: start alias
      cmd_builder_start() {
          cmd_start "$BUILDER_NAME"
      }

      # Builder: stop alias
      cmd_builder_stop() {
          cmd_stop "$BUILDER_NAME"
      }

      # Builder: switch (build + apply with specialisation preservation)
      # Usage: shard builder switch [specialisation]
      # If specialisation is provided, uses that. Otherwise preserves current.
      cmd_builder_switch() {
          local target_spec="''${1:-}"

          # Detect current specialisation
          local current_spec
          current_spec=$(detect_current_specialisation)

          # Use provided spec or default to current
          if [[ -z "$target_spec" ]]; then
              target_spec="$current_spec"
          fi

          log "Current specialisation: ''${BOLD}''${current_spec}''${NC}"
          if [[ "$target_spec" != "$current_spec" ]]; then
              log "Target specialisation: ''${BOLD}''${target_spec}''${NC}"
              log "''${YELLOW}Note: Switching specialisations in lockdown mode may have limited effect''${NC}"
              log "''${YELLOW}      Consider rebooting and selecting '$target_spec' from boot menu''${NC}"
          fi

          local total_start
          total_start=$(timer_start)

          # Step 1: Build via builder workflow
          log "Building host configuration..."
          if ! cmd_builder_build host; then
              log_error "Build failed, not switching"
              return 1
          fi

          # Step 2: Switch with specialisation
          log "Applying configuration..."
          local host_config
          host_config=$(detect_host_config)
          local switch_cmd="sudo --preserve-env=HYDRIX_BUILD_TIME,HYDRIX_BUILD_TAG nixos-rebuild switch --flake ''${FLAKE_DIR}#''${host_config} --impure"
          if [[ "$target_spec" != "lockdown" ]]; then
              switch_cmd="$switch_cmd --specialisation ''${target_spec}"
          fi

          log "Running: ''${DIM}''${switch_cmd}''${NC}"
          if eval "$switch_cmd"; then
              # Re-attach TAPs to bridges (activation may have recreated bridges)
              restore_network
              local total_time
              total_time=$(timer_end "$total_start")
              echo ""
              log_success "Switch complete in ''${BOLD}''${total_time}s''${NC}"
              log "Now running: ''${BOLD}''${target_spec}''${NC} specialisation"
          else
              log_error "Switch failed"
              log "System is unchanged - previous configuration still active"
              return 1
          fi
      }

      # Builder: shell (console) alias
      cmd_builder_shell() {
          cmd_console "$BUILDER_NAME"
      }

      # Builder: help
      cmd_builder_help() {
          cat <<EOF
      ''${BOLD}shard builder''${NC} - Streamlined lockdown mode builds

      ''${BOLD}USAGE''${NC}
          shard builder <command> [target]

      ''${BOLD}COMMANDS''${NC}
          build <target>     Full workflow: start → build in VM → stop → build on host
          switch [spec]      Build + apply host config (default: preserve current spec)
          fetch <target>     Prefetch deps in builder (don't stop, don't build on host)
          update [input...]  Update flake inputs through the builder (lockdown: no host
                             network); writes flake.lock after checking it
          start              Start builder VM (stops host nix-daemon)
          stop               Stop builder VM (restarts host nix-daemon)
          status             Show builder and nix-daemon status
          shell              Attach to builder console

      ''${BOLD}NAMED TARGETS''${NC}
          browsing           → microvm-browsing
          pentest            → microvm-pentest
          dev                → microvm-dev
          comms              → microvm-comms
          lurking            → microvm-lurking
          router             → microvm-router
          builder            → microvm-builder
          host               → Host system (nixos-rebuild)
          micro*             → Direct microVM name
          .#path             → Raw flake path (passed through)

      ''${BOLD}EXAMPLES''${NC}
          # Build one or more microVMs (full workflow, eval cache warm after first)
          shard builder build browsing
          shard builder build browsing pentest dev

          # Build host config
          shard builder build host

          # Build AND apply host config (preserves current specialisation)
          shard builder switch
          shard builder switch administrative  # Build for specific specialisation

          # Prefetch multiple targets, then stop
          shard builder fetch browsing
          shard builder fetch pentest
          shard builder fetch host
          shard builder stop

          # Manual control
          shard builder start
          shard builder shell          # Interactive console
          shard builder stop

          # Check status
          shard builder status
      EOF
      }

      # Builder: dispatcher
      cmd_builder() {
          local subcmd="''${1:-help}"
          shift 2>/dev/null || true

          case "$subcmd" in
              build)   cmd_builder_build "$@" ;;
              switch)  cmd_builder_switch "$@" ;;
              fetch)   cmd_builder_fetch "$@" ;;
              update)  cmd_builder_update "$@" ;;
              start)   cmd_builder_start ;;
              stop)    cmd_builder_stop ;;
              status)  cmd_builder_status ;;
              shell)   cmd_builder_shell ;;
              help|-h|--help)  cmd_builder_help ;;
              *)
                  log_error "Unknown builder command: $subcmd"
                  cmd_builder_help
                  return 1
                  ;;
          esac
      }

      # ===== Task Slot Engagements =====
      # Task slots are generic VMs generated from hydrix-config's tasks/default.nix
      # (vm-registry entries carrying a taskSlot), each on its own isolated bridge.
      # An engagement is a name bound to a slot at runtime: no rebuild per
      # engagement, and the binding lives outside the flake so engagement names
      # never reach git or the nix store. Ending an engagement moves its home
      # volume out of the slot into the archive, so the slot is empty for the next
      # engagement and the data can later be resumed into any free slot.

      ENGAGEMENTS_FILE="/home/''${SUDO_USER:-$USER}/.local/share/hydrix/engagements.json"
      readonly ENGAGEMENTS_FILE
      # Same filesystem as the slot volumes, so end/resume is a rename, not a copy.
      # Dot-prefixed so VM directory globs (shard gc) never see it.
      readonly ENGAGEMENT_ARCHIVE="/var/lib/microvms/.engagements"

      # One "task1<TAB>vmName" line per slot, in CID order
      task_slots() {
          [[ -f "$VM_REGISTRY" ]] || return 0
          jq -r '[.[] | select(.taskSlot != null)] | sort_by(.cid)[] | "\(.taskSlot)\t\(.vmName)"' "$VM_REGISTRY" 2>/dev/null
      }

      # Slot name (task1) -> vmName, empty if there is no such slot
      task_slot_vm() {
          [[ -f "$VM_REGISTRY" ]] || return 0
          jq -r --arg s "$1" '[.[] | select(.taskSlot == $s) | .vmName][0] // empty' "$VM_REGISTRY" 2>/dev/null
      }

      # vmName -> the slot's base profile registry key (e.g. "pentest"), empty for non-slot VMs
      task_slot_profile() {
          [[ -f "$VM_REGISTRY" ]] || return 0
          jq -r --arg v "$1" \
              'to_entries[] | . as $e | select(.value.vmName == $v and .value.taskSlot != null) | .key | rtrimstr("-" + $e.value.taskSlot)' \
              "$VM_REGISTRY" 2>/dev/null | head -1
      }

      engagements_read() {
          if [[ -f "$ENGAGEMENTS_FILE" ]]; then
              cat "$ENGAGEMENTS_FILE"
          else
              echo '{"slots": {}, "archived": {}}'
          fi
      }

      # Replace the engagements file with stdin, written 0600 and atomically
      engagements_write() {
          local new
          new=$(cat)
          [[ -n "$new" ]] || return 1
          mkdir -p "$(dirname "$ENGAGEMENTS_FILE")"
          (umask 077 && printf '%s\n' "$new" > "$ENGAGEMENTS_FILE.tmp") && mv "$ENGAGEMENTS_FILE.tmp" "$ENGAGEMENTS_FILE"
      }

      engagement_of_slot() {
          engagements_read | jq -r --arg v "$1" '.slots[$v] // empty'
      }

      engagement_slot() {
          engagements_read | jq -r --arg n "$1" '(.slots // {}) | to_entries[] | select(.value == $n) | .key' | head -1
      }

      engagement_archived() {
          engagements_read | jq -e --arg n "$1" '(.archived // {}) | has($n)' >/dev/null
      }

      engagement_name_valid() {
          [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]
      }

      # The label a VM's windows get (window title, clipboard group, notifications):
      # <profile>-<engagement> for a bound task slot, else its registry key. Same rule as
      # hydrix-vm-label, which waypipe-connect uses.
      vm_label() {
          local vm="$1" key="" slot="" eng cand
          [[ -f "$VM_REGISTRY" ]] || { echo "$vm"; return; }
          IFS=$'\t' read -r key slot < <(jq -r --arg v "$vm" \
              '[to_entries[] | select(.value.vmName == $v)][0] // empty | "\(.key)\t\(.value.taskSlot // "")"' \
              "$VM_REGISTRY" 2>/dev/null) || true
          [[ -n "$key" ]] || { echo "$vm"; return; }
          if [[ -n "$slot" ]]; then
              eng=$(engagement_of_slot "$vm")
              if engagement_name_valid "$eng"; then
                  cand="''${key%-"$slot"}-$eng"
                  if ! jq -e --arg k "$cand" 'has($k)' "$VM_REGISTRY" >/dev/null 2>&1; then
                      key="$cand"
                  fi
              fi
          fi
          echo "$key"
      }

      # shard -b/-s/-R on a stopped, unbound task slot at a terminal: ask for an engagement
      # name and bind it as shard pentest taskN <name> would. Empty leaves the slot unbound.
      # A slot that already holds an unbound volume (built or started while unbound) gives
      # that volume to the name, as --adopt would. Asks once per slot and run, never without
      # a terminal. Fails when binding is refused, so the command stops there.
      ENGAGEMENT_ASKED=" "
      engagement_prompt() {
          local vm="$1" slot name what adopt_flag=()
          [[ -t 0 && -t 2 && -f "$VM_REGISTRY" ]] || return 0
          [[ "$ENGAGEMENT_ASKED" == *" $vm "* ]] && return 0
          slot=$(jq -r --arg v "$vm" '[.[] | select(.vmName == $v) | .taskSlot // empty][0] // empty' "$VM_REGISTRY" 2>/dev/null)
          [[ -n "$slot" ]] || return 0
          [[ -z "$(engagement_of_slot "$vm")" ]] || return 0
          is_running "$vm" && return 0
          ENGAGEMENT_ASKED+="$vm "
          what="Engagement name for $slot"
          if [[ -n "$(slot_volumes "/var/lib/microvms/$vm")" ]]; then
              adopt_flag=(--adopt)
              what="$what, keeps its unbound home volume"
          fi
          while true; do
              read -r -p "$what (empty: leave unbound): " name || return 0
              [[ -n "$name" ]] || return 0
              if engagement_name_valid "$name"; then break; fi
              log_error "Engagement names use lowercase letters, digits, - and _ (max 32 chars)"
          done
          ENGAGEMENT_BIND_QUIET=1 cmd_pentest_start "$slot" "$name" "''${adopt_flag[@]}"
      }

      # Home volume files present in a slot directory
      slot_volumes() {
          local f
          for f in "$1/home.qcow2" "$1/home.luks"; do
              if [[ -f "$f" ]]; then echo "$f"; fi
          done
      }

      pentest_print_table() {
          printf "''${BOLD}%-7s %-20s %-28s %-8s %-10s''${NC}\n" "SLOT" "ENGAGEMENT" "LABEL" "RUNNING" "VOLUME"
          local key vm
          while IFS=$'\t' read -r key vm; do
              local eng label="-" running_str="-" vol_size="-" f
              eng=$(engagement_of_slot "$vm")
              [[ -n "$eng" ]] && label=$(vm_label "$vm")
              is_running "$vm" && running_str="yes"
              running_str=$(printf '%-8s' "$running_str")
              [[ "$running_str" == yes* ]] && running_str="''${GREEN}$running_str''${NC}"
              f=$(slot_volumes "/var/lib/microvms/$vm" | head -1)
              if [[ -n "$f" ]]; then
                  vol_size=$(du -sh "$f" 2>/dev/null | cut -f1)
                  [[ -z "$eng" ]] && vol_size="$vol_size (unbound)"
              fi
              printf "%-7s %-20s %-28s %s %-10s\n" "$key" "''${eng:--}" "$label" "$running_str" "$vol_size"
          done < <(task_slots)

          local archived
          archived=$(engagements_read | jq -r '(.archived // {}) | to_entries[] | "\(.key)\t\(.value)"')
          if [[ -n "$archived" ]]; then
              echo ""
              echo -e "''${BOLD}ARCHIVED''${NC}"
              local name ended
              while IFS=$'\t' read -r name ended; do
                  printf "  %-20s ''${DIM}ended %s''${NC}\n" "$name" "$ended"
              done <<< "$archived"
          fi
      }

      # shard pentest [taskN] <name> [--adopt]
      # shard pentest start <name> [--slot N] [--adopt]
      cmd_pentest_start() {
          local slot_key="" name="" adopt=0
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  --slot)
                      [[ $# -lt 2 ]] && { log_error "--slot needs a slot number"; return 1; }
                      slot_key="task$2"
                      shift 2
                      ;;
                  --adopt) adopt=1; shift ;;
                  task[0-9]*) slot_key="$1"; shift ;;
                  -*) log_error "Unknown option: $1"; return 1 ;;
                  *)
                      [[ -n "$name" ]] && { log_error "Unexpected argument: $1"; return 1; }
                      name="$1"
                      shift
                      ;;
              esac
          done

          if [[ -z "$name" ]]; then
              log_error "Usage: shard pentest [taskN] <name>"
              return 1
          fi
          if ! engagement_name_valid "$name"; then
              log_error "Engagement names use lowercase letters, digits, - and _ (max 32 chars)"
              return 1
          fi
          case "$name" in
              list|ls|start|end|purge|help|task[0-9]*|micro*|router*|builder|gitsync|files|vault|host)
                  log_error "$name is a reserved word, pick another engagement name"
                  return 1
                  ;;
          esac
          if [[ -f "$VM_REGISTRY" ]] && jq -e --arg k "$name" 'has($k)' "$VM_REGISTRY" >/dev/null 2>&1; then
              log_error "$name is already a VM name, pick another engagement name"
              return 1
          fi

          local existing
          existing=$(engagement_slot "$name")
          if [[ -n "$existing" ]]; then
              log_error "Engagement $name is already active in $existing"
              return 1
          fi

          local slot=""
          if [[ -n "$slot_key" ]]; then
              slot=$(task_slot_vm "$slot_key")
              if [[ -z "$slot" ]]; then
                  log_error "No task slot named $slot_key"
                  pentest_print_table
                  return 1
              fi
              local occupant
              occupant=$(engagement_of_slot "$slot")
              if [[ -n "$occupant" ]]; then
                  log_error "$slot_key is in use by $occupant (free it with: shard pentest end $occupant)"
                  return 1
              fi
          else
              local key vm
              while IFS=$'\t' read -r key vm; do
                  if [[ -z "$(engagement_of_slot "$vm")" ]]; then
                      slot="$vm"
                      slot_key="$key"
                      break
                  fi
              done < <(task_slots)
              if [[ -z "$slot" ]]; then
                  log_error "No free task slot"
                  pentest_print_table
                  return 1
              fi
          fi

          if is_running "$slot"; then
              log_error "$slot_key is running without an engagement, stop it first: shard -S $slot_key"
              return 1
          fi

          local vm_dir="/var/lib/microvms/$slot" leftover
          leftover=$(slot_volumes "$vm_dir")
          if [[ -n "$leftover" ]]; then
              if engagement_archived "$name"; then
                  log_error "Can't resume $name into $slot_key: the slot still holds an unbound volume"
                  log "Pick another slot, or delete it first: shard -p $slot_key"
                  return 1
              fi
              if [[ "$adopt" -eq 0 ]]; then
                  log_error "$slot_key holds a home volume that isn't bound to any engagement:"
                  local f
                  while IFS= read -r f; do echo "     $f" >&2; done <<< "$leftover"
                  log "Keep it as $name: shard pentest $slot_key $name --adopt"
                  log "Delete it:        shard -p $slot_key"
                  return 1
              fi
              log_warn "Adopting the existing volume in $slot_key as $name"
          fi

          if engagement_archived "$name"; then
              log "Resuming archived engagement ''${BOLD}$name''${NC} into $slot_key..."
              sudo mkdir -p "$vm_dir"
              sudo find "$ENGAGEMENT_ARCHIVE/$name" -maxdepth 1 -name 'home.*' -exec mv -t "$vm_dir" {} +
              sudo rmdir "$ENGAGEMENT_ARCHIVE/$name"
              engagements_read | jq --arg n "$name" 'del(.archived[$n])' | engagements_write
          fi

          engagements_read | jq --arg v "$slot" --arg n "$name" '.slots[$v] = $n' | engagements_write
          log_success "Engagement ''${BOLD}$name''${NC} bound to $slot_key (windows show [$(vm_label "$slot")])"
          [[ -n "''${ENGAGEMENT_BIND_QUIET:-}" ]] && return 0
          echo ""
          echo -e "  ''${DIM}Build:''${NC}  shard -b $name"
          echo -e "  ''${DIM}Start:''${NC}  shard -s $name"
          echo -e "  ''${DIM}Finish:''${NC} shard pentest end $name"
      }

      cmd_pentest_list() {
          pentest_print_table
      }

      # shard pentest end <name>: free the slot, archive the engagement's volume
      cmd_pentest_end() {
          local name="''${1:-}"
          [[ -z "$name" ]] && { log_error "Usage: shard pentest end <name>"; return 1; }

          local slot
          slot=$(engagement_slot "$name")
          if [[ -z "$slot" ]]; then
              log_error "No active engagement named $name"
              echo ""
              pentest_print_table
              return 1
          fi

          if is_running "$slot"; then
              log "Stopping $slot..."
              cmd_stop "$slot"
          fi

          local vols
          vols=$(slot_volumes "/var/lib/microvms/$slot")
          if [[ -n "$vols" ]]; then
              local dest="$ENGAGEMENT_ARCHIVE/$name"
              if sudo test -e "$dest"; then
                  log_error "$dest already exists, refusing to overwrite it"
                  return 1
              fi
              sudo install -d -m 700 "$ENGAGEMENT_ARCHIVE" "$dest"
              xargs sudo mv -t "$dest" <<< "$vols"
              engagements_read | jq --arg n "$name" --arg d "$(date +%F)" '.archived[$n] = $d' | engagements_write
              log "Home volume archived at $dest"
          fi

          engagements_read | jq --arg v "$slot" 'del(.slots[$v])' | engagements_write
          log_success "Engagement ''${BOLD}$name''${NC} ended, its slot is free"
          if [[ -n "$vols" ]]; then
              echo ""
              echo -e "  ''${DIM}Resume later:''${NC} shard pentest $name"
              echo -e "  ''${DIM}Delete data:''${NC}  shard pentest purge $name"
          fi
      }

      # shard pentest purge <name> [-f]: delete an engagement's data, active or archived
      cmd_pentest_purge() {
          local name="" force=0 arg
          for arg in "$@"; do
              case "$arg" in
                  -f|--force) force=1 ;;
                  *) name="$arg" ;;
              esac
          done
          if [[ -z "$name" ]] || ! engagement_name_valid "$name"; then
              log_error "Usage: shard pentest purge <name> [-f|--force]"
              return 1
          fi

          local slot purge_paths=""
          slot=$(engagement_slot "$name")
          if [[ -n "$slot" ]]; then
              if is_running "$slot"; then
                  log "Stopping $slot..."
                  cmd_stop "$slot"
              fi
              purge_paths=$(slot_volumes "/var/lib/microvms/$slot")
          elif engagement_archived "$name"; then
              purge_paths="$ENGAGEMENT_ARCHIVE/$name"
          else
              log_error "No engagement named $name"
              echo ""
              pentest_print_table
              return 1
          fi

          echo -e "''${YELLOW}This deletes all data for engagement ''${BOLD}$name''${NC}''${YELLOW}:''${NC}"
          if [[ -n "$purge_paths" ]]; then
              xargs sudo du -sh <<< "$purge_paths" 2>/dev/null | sed 's/^/  /' || true
          else
              echo "  (no volume, only the binding)"
          fi
          echo ""
          if [[ "$force" -eq 0 ]]; then
              echo -e "''${RED}This cannot be undone.''${NC}"
              read -rp "Type 'yes' to confirm: " confirm
              [[ "$confirm" != "yes" ]] && { log "Aborted"; return 1; }
          fi

          if [[ -n "$slot" ]]; then
              [[ -n "$purge_paths" ]] && xargs sudo rm -f -- <<< "$purge_paths"
              engagements_read | jq --arg v "$slot" 'del(.slots[$v])' | engagements_write
          else
              sudo rm -rf -- "$ENGAGEMENT_ARCHIVE/$name"
              engagements_read | jq --arg n "$name" 'del(.archived[$n])' | engagements_write
          fi
          log_success "Engagement ''${BOLD}$name''${NC} purged"
      }

      cmd_pentest_help() {
          cat <<EOF
      ''${BOLD}shard pentest''${NC} - Bind engagements to task slots

      ''${BOLD}USAGE''${NC}
          shard pentest task<N> <name>      Bind <name> to slot N
          shard pentest <name>              Bind <name> to the first free slot
          shard pentest start <name> [--slot N]   Same, long form
          shard pentest end <name>          Free the slot, archive the engagement's volume
          shard pentest purge <name> [-f]   Delete an engagement's data (active or archived)
          shard pentest list                Slots, bindings, archived engagements

      Once bound, the engagement name works everywhere a VM name does:
          shard -b google, shard -s google, shard -S google, shard -a google firefox

      ''${BOLD}WORKFLOW''${NC}
          shard pentest task1 google        # bind
          shard -b google                   # build (sets up the encrypted volume first time)
          shard -s google                   # start
          shard pentest end google          # stop, archive data, free task1
          shard pentest task2 google        # resume archived data in any free slot
          shard pentest purge google        # delete it for good

      ''${BOLD}OPTIONS''${NC}
          --adopt     Bind a slot's existing unbound volume to the new engagement
                      instead of refusing (volumes left from before bindings existed)

      ''${BOLD}NOTES''${NC}
          - Slots come from tasks/default.nix in hydrix-config; each has its own
            bridge and subnet, isolated from every other VM network by the router
          - Binding and ending never rebuild; bindings are stored in
            $ENGAGEMENTS_FILE, archived volumes in $ENGAGEMENT_ARCHIVE
          - Backups: shard backup create/restore <engagement> <name>, restorable only
            while the same engagement is bound to the slot
      EOF
      }

      # shard pentest dispatcher: anything that isn't a subcommand is a bind
      cmd_pentest() {
          case "''${1:-help}" in
              list|ls) cmd_pentest_list ;;
              end) shift; cmd_pentest_end "$@" ;;
              purge) shift; cmd_pentest_purge "$@" ;;
              start) shift; cmd_pentest_start "$@" ;;
              help|-h|--help) cmd_pentest_help ;;
              *) cmd_pentest_start "$@" ;;
          esac
      }

      # ===== Network Restoration =====
      # Re-attach TAPs to bridges after switch-to-configuration
      # Bridges may be recreated during activation, detaching TAP interfaces
      restore_network() {
          log "Restoring network..."

          # Ensure bridges are up
          for br in $(ip -o link show type bridge 2>/dev/null | awk -F'[ :]+' '{print $2}'); do
              sudo ip link set "$br" up 2>/dev/null || true
          done

          # Re-attach router TAPs
          declare -A router_taps=(
              ["mv-router-mgmt"]="br-mgmt"
              ["mv-router-pent"]="br-pentest"
              ["mv-router-comm"]="br-comms"
              ["mv-router-lurk"]="br-lurking"
              ["mv-router-brow"]="br-browse"
              ["mv-router-dev"]="br-dev"
          )
          for tap in "''${!router_taps[@]}"; do
              local bridge="''${router_taps[$tap]}"
              if ip link show "$tap" &>/dev/null && ip link show "$bridge" &>/dev/null; then
                  sudo ip link set "$tap" master "$bridge" 2>/dev/null || true
                  sudo ip link set "$tap" up 2>/dev/null || true
              fi
          done

          # Re-attach VM TAPs
          for tap in $(ip -o link show 2>/dev/null | grep -oP 'mv-(?!router)[a-z-]+(?=[@:])' | sort -u); do
              local bridge="br-browse"
              case "$tap" in
                  mv-browse*)  bridge="br-browse" ;;
                  mv-pentest*) bridge="br-pentest" ;;
                  mv-hack*)    bridge="br-pentest" ;;
                  mv-dev*)     bridge="br-dev" ;;
                  mv-lurk*)    bridge="br-lurking" ;;
                  mv-comms*)   bridge="br-comms" ;;
                  mv-build*)   bridge="br-builder" ;;
                  mv-gitsyn*)  bridge="br-builder" ;;
              esac
              if ip link show "$bridge" &>/dev/null; then
                  sudo ip link set "$tap" master "$bridge" 2>/dev/null || true
                  sudo ip link set "$tap" up 2>/dev/null || true
              fi
          done

          # Task slot TAPs: mv-taskN belongs on its own br-taskN
          for tap in $(ip -o link show 2>/dev/null | grep -oP 'mv-task[0-9]+(?=[@:])' | sort -u); do
              local bridge="br-''${tap#mv-}"
              if ip link show "$bridge" &>/dev/null; then
                  sudo ip link set "$tap" master "$bridge" 2>/dev/null || true
                  sudo ip link set "$tap" up 2>/dev/null || true
              fi
          done

          # Restore host IP on management bridge
          sudo ip addr add 192.168.100.1/24 dev br-mgmt 2>/dev/null || true
      }

      # ===== Git-Sync Commands =====

      # Git-sync: send command via vsock and display output
      gitsync_vsock_cmd() {
          local cmd="$1"

          # Track if we started the VM so we can stop it when done
          local we_started=false
          if ! is_running "$GITSYNC_NAME"; then
              log "Starting git-sync VM..."
              cmd_start "$GITSYNC_NAME" || return 1
              we_started=true
          fi

          if ! wait_for_gitsync 60; then
              log_error "Timeout waiting for git-sync VM to be ready"
              [[ "$we_started" == "true" ]] && cmd_stop "$GITSYNC_NAME" 2>/dev/null || true
              return 1
          fi

          # A ready vsock port only proves the guest's own network is up - it says
          # nothing about the router this VM depends on for DNS/internet, which can
          # still be reconnecting to WiFi after a cold host boot. Retry network
          # commands instead of failing on the first attempt; CLONE/PUSH/PULL/FETCH
          # are all safe to retry. REPOS/STATUS/PING don't touch the network, so a
          # real failure there won't fix itself with time.
          local output rc=0
          # A clone of a large repo can take minutes; everything else answers in seconds.
          local total_timeout=120
          [[ "$cmd" == CLONE* ]] && total_timeout=900
          case "$cmd" in
              CLONE*|PUSH*|PULL*|FETCH*)
                  local attempt max_attempts=5 retry_delay=15
                  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
                      rc=0
                      output=$(vsock_query "$GITSYNC_CID" "$GITSYNC_GIT_PORT" "$cmd" 60 "$total_timeout" 2>&1) || rc=$?
                      echo "$output" | grep -q "^ERROR" && rc=1
                      [[ $rc -eq 0 ]] && break
                      # Refusals (undeclared, not empty, not shared) will not fix themselves.
                      echo "$output" | grep -q "^ERROR .*\(not found\|not empty\|not shared\|no URL\)" && break
                      if [[ $attempt -lt $max_attempts ]]; then
                          log "Attempt $attempt/$max_attempts failed (network likely still settling) - retrying in ''${retry_delay}s..."
                          sleep "$retry_delay"
                      fi
                  done
                  ;;
              *)
                  output=$(vsock_query "$GITSYNC_CID" "$GITSYNC_GIT_PORT" "$cmd" 60 120 2>&1) || rc=$?
                  echo "$output" | grep -q "^ERROR" && rc=1
                  ;;
          esac

          while IFS= read -r line; do
              case "$line" in
                  OK*)
                      log "$line"
                      ;;
                  DONE*)
                      log_success "$line"
                      ;;
                  ERROR*)
                      log_error "$line"
                      ;;
                  *)
                      [[ -n "$line" ]] && echo "  $line"
                      ;;
              esac
          done <<< "$output"

          if [[ "$we_started" == "true" ]]; then
              log "Stopping git-sync VM..."
              cmd_stop "$GITSYNC_NAME" 2>/dev/null || true
          fi

          return $rc
      }

      cmd_git_clone() {
          local repo="''${1:-}"
          [[ -z "$repo" ]] && { log_error "Usage: shard git clone <repo>"; return 1; }
          gitsync_vsock_cmd "CLONE $repo"
      }

      cmd_git_push() {
          local repo="''${1:-}"
          [[ -z "$repo" ]] && { log_error "Usage: shard git push <repo>"; return 1; }
          gitsync_vsock_cmd "PUSH $repo"
      }

      cmd_git_pull() {
          local repo="''${1:-}"
          [[ -z "$repo" ]] && { log_error "Usage: shard git pull <repo>"; return 1; }
          gitsync_vsock_cmd "PULL $repo"
      }

      cmd_git_fetch() {
          local repo="''${1:-}"
          [[ -z "$repo" ]] && { log_error "Usage: shard git fetch <repo>"; return 1; }
          gitsync_vsock_cmd "FETCH $repo"
      }

      cmd_git_status() {
          local repo="''${1:-}"
          [[ -z "$repo" ]] && { log_error "Usage: shard git status <repo>"; return 1; }
          gitsync_vsock_cmd "STATUS $repo"
      }

      cmd_git_repos() {
          gitsync_vsock_cmd "REPOS"
      }

      cmd_git_auth() {
          # Open console for interactive gh auth login
          if ! is_running "$GITSYNC_NAME"; then
              log "Starting git-sync VM..."
              cmd_start "$GITSYNC_NAME" || return 1
          fi
          log "Attaching to git-sync console for gh auth login..."
          log "Run: ''${BOLD}gh auth login''${NC}"
          log "Press Ctrl+] to detach from console"
          cmd_console "$GITSYNC_NAME"
      }

      cmd_git_help() {
          cat <<EOF
      ''${BOLD}shard git''${NC} - Git operations via git-sync VM (lockdown mode)

      ''${BOLD}USAGE''${NC}
          shard git <command> [repo]

      ''${BOLD}COMMANDS''${NC}
          clone <repo>       Clone a declared repo into its empty host directory
          push <repo>        Push commits to remote
          pull <repo>        Pull changes from remote
          fetch <repo>       Fetch from all remotes
          status <repo>      Show git status and recent commits
          repos              List available repos
          auth               Console for gh auth login (only with hydrix.gitsync.gh.enable)

      ''${BOLD}EXAMPLES''${NC}
          # List available repos
          shard git repos

          # Check status of a repo
          shard git status hydrix-config

          # Push commits (commit on host first, then push via git-sync)
          shard git push hydrix-config

          # Pull latest changes
          shard git pull Hydrix

      The git VM pushes with the SSH key from secrets/github.yaml (hydrix.secrets.githubSecretsFile);
      'shard git auth' is only for the optional gh CLI login.
      EOF
      }

      # Git: dispatcher
      cmd_git() {
          local subcmd="''${1:-help}"
          shift 2>/dev/null || true

          case "$subcmd" in
              clone)   cmd_git_clone "$@" ;;
              push)    cmd_git_push "$@" ;;
              pull)    cmd_git_pull "$@" ;;
              fetch)   cmd_git_fetch "$@" ;;
              status)  cmd_git_status "$@" ;;
              repos)   cmd_git_repos ;;
              auth)    cmd_git_auth ;;
              help|-h|--help)  cmd_git_help ;;
              *)
                  log_error "Unknown git command: $subcmd"
                  cmd_git_help
                  return 1
                  ;;
          esac
      }

      # ============================================================================
      # Files: encrypted inter-VM file transfer via microvm-files
      # ============================================================================
      #
      # Data streams source VM :8888 -> files VM (relay) -> destination VM :8888
      # as age(zstd(tar)), with nothing written to disk on the way. Per transfer
      # the host makes an age X25519 identity: the source only gets the public
      # recipient, the destination gets the identity over vsock, the files VM
      # gets no key at all. The destination extracts into staging and only moves
      # the result into place after the host has compared the ciphertext SHA-256
      # reported by the source, the files VM and the destination.
      # Protocol and checks: Hydrix vm/dev/xfer.py.

      FILES_VM_NAME="microvm-files"
      FILES_VM_CID=$(get_cid "$FILES_VM_NAME" 2>/dev/null || true); FILES_VM_CID="''${FILES_VM_CID:-212}"
      FILES_VSOCK_PORT=14505
      VM_AGENT_PORT=14506

      # Send a command to a VM via vsock, return the response.
      # vsock-cmd blocks until the handler exits and closes its end, with no total
      # read timeout of its own - `timeout` provides the outer bound here
      # (total_timeout 0 = no bound).
      vsock_query() {
          local cid="$1"
          local port="$2"
          local msg="$3"
          local connect_timeout="''${4:-10}"
          local total_timeout="''${5:-15}"
          # VM replies are untrusted text: drop control characters (except tab
          # and newline) so nothing a VM sends can drive the host terminal.
          printf '%s\n' "$msg" | timeout "$total_timeout" vsock-cmd "$cid" "$port" "$connect_timeout" \
              | LC_ALL=C tr -d '\000-\010\013-\037\177'
      }

      # Send a command to files VM via vsock 14505: <msg> [connect_timeout] [total_timeout]
      files_vm_send() {
          local msg="$1"
          shift
          vsock_query "$FILES_VM_CID" "$FILES_VSOCK_PORT" "$msg" "$@"
      }

      # Look up vsock CID for a given VM name.
      # Delegates to get_cid (registry → nix eval). All VMs are declared in
      # hydrix-config infra/*/meta.nix or profiles/*/meta.nix and appear in the registry.
      get_vm_cid() {
          local vm="$1"
          local cid
          cid=$(get_cid "$vm")
          if [[ -z "$cid" ]]; then
              log_error "Unknown VM: $vm (not in registry, nix eval failed)"
              return 1
          fi
          echo "$cid"
      }

      FILES_TMP=""
      FILES_STOP_VM=false
      FILES_BG_PIDS=()
      FILES_ABORT=()
      FILES_LAST_PID=""

      # One `shard files` operation at a time: every VM listens on the same port.
      files_lock() {
          local lock="''${XDG_RUNTIME_DIR:-/tmp}/hydrix-files.lock"
          exec {FILES_LOCK_FD}>"$lock"
          flock -n "$FILES_LOCK_FD" || { log_error "Another shard files operation is running"; exit 1; }
      }

      # EXIT trap: stop local helpers, ABORT every VM side (kills its helper and
      # removes staged data; a no-op after a commit), stop a files VM we started.
      files_cleanup() {
          local pid ep
          for pid in "''${FILES_BG_PIDS[@]}"; do
              kill "$pid" 2>/dev/null || true
          done
          for ep in "''${FILES_ABORT[@]}"; do
              vsock_query "''${ep% *}" "''${ep#* }" "ABORT" 3 10 >/dev/null 2>&1 || true
          done
          [[ -n "$FILES_TMP" ]] && rm -rf "$FILES_TMP"
          if $FILES_STOP_VM; then
              log "Stopping ''${FILES_VM_NAME}..."
              systemctl stop "microvm@''${FILES_VM_NAME}.service" 2>/dev/null || true
          fi
          backup_notices
      }

      files_begin() {
          files_lock
          FILES_TMP=$(mktemp -d -t shard-files.XXXXXX)
          trap files_cleanup EXIT
          trap 'exit 130' INT TERM
      }

      # The files VM only runs for a transfer: start it if needed, stop it on
      # exit either way (it has no volumes, so a stop also wipes it).
      files_vm_up() {
          FILES_STOP_VM=true
          if ! systemctl is-active --quiet "microvm@''${FILES_VM_NAME}.service" 2>/dev/null; then
              log "Starting ''${FILES_VM_NAME}..."
              systemctl start "microvm@''${FILES_VM_NAME}.service" || {
                  log_error "Failed to start ''${FILES_VM_NAME}"
                  exit 1
              }
          fi
          local deadline=$(( $(date +%s) + 30 ))
          until files_vm_send "PING" 3 5 2>/dev/null | grep -q "PONG"; do
              if (( $(date +%s) >= deadline )); then
                  log_error "Timeout waiting for ''${FILES_VM_NAME} vsock agent"
                  exit 1
              fi
              sleep 1
          done
      }

      files_b64() { printf '%s' "$1" | base64 -w0; }
      files_human() { numfmt --to=iec --suffix=B "''${1:-0}"; }

      # Run a vsock command in the background, raw reply into <out>. Sets FILES_LAST_PID.
      files_bg() {
          local out="$1" cid="$2" port="$3" msg="$4"
          printf '%s\n' "$msg" | vsock-cmd "$cid" "$port" 10 >"$out" 2>/dev/null &
          FILES_LAST_PID=$!
          FILES_BG_PIDS+=("$FILES_LAST_PID")
      }

      # Reply lines are untrusted: control characters are stripped before use.
      files_reply() { LC_ALL=C tr -d '\000-\010\013-\037\177' <"$1" 2>/dev/null || true; }
      files_result() { files_reply "$1" | grep -E '^(OK|ERROR)' | tail -1 || true; }
      files_field() { grep -o "$2=[^ ]*" <<<"$1" | head -1 | cut -d= -f2 || true; }
      files_warnings() {
          local line
          files_reply "$2" | grep '^WARN: ' | while IFS= read -r line; do
              log_warn "$1: ''${line#WARN: }"
          done || true
      }

      # Wait until a background command reports LISTENING; prints that line.
      files_wait_listening() {
          local out="$1" pid="$2" vm="$3" line
          local deadline=$(( $(date +%s) + 30 ))
          while (( $(date +%s) < deadline )); do
              line=$(files_reply "$out" | grep -E '^(LISTENING|ERROR)' | head -1 || true)
              if [[ "$line" == LISTENING* ]]; then
                  echo "$line"
                  return 0
              fi
              if [[ "$line" == ERROR* ]]; then
                  log_error "''${vm}: ''${line}"
                  return 1
              fi
              if ! kill -0 "$pid" 2>/dev/null; then
                  log_error "''${vm}: no reply from its files agent (vsock ''${VM_AGENT_PORT})"
                  return 1
              fi
              sleep 0.2
          done
          log_error "''${vm}: files agent did not get ready"
          return 1
      }

      # Wait for a background command; on a terminal, show the PROGRESS it reports.
      files_wait_progress() {
          local out="$1" pid="$2" bytes elapsed start=$SECONDS
          while kill -0 "$pid" 2>/dev/null; do
              if [[ -t 2 ]]; then
                  bytes=$(files_reply "$out" | grep '^PROGRESS ' | tail -1 | cut -d' ' -f2 || true)
                  elapsed=$(( SECONDS - start ))
                  if [[ -n "$bytes" ]] && (( elapsed > 0 )); then
                      printf '\r   %s streamed, %s/s ' "$(files_human "$bytes")" "$(files_human $(( bytes / elapsed )))" >&2
                  fi
              fi
              sleep 1
          done
          [[ -t 2 ]] && printf '\r\033[K' >&2
          wait "$pid" 2>/dev/null || true
      }

      # Split "<vm>/<path>" into FILES_VM and FILES_PATH (no trailing slashes).
      files_split() {
          FILES_VM="''${1%%/*}"
          FILES_PATH=""
          [[ "$1" == */* ]] && FILES_PATH="''${1#*/}"
          while [[ "$FILES_PATH" == */ ]]; do FILES_PATH="''${FILES_PATH%/}"; done
          FILES_VM="$(resolve_vm_name "$FILES_VM")"
      }

      # Fresh age identity for one operation, held only in this shell.
      files_keypair() {
          FILES_SECRET=$(age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-' || true)
          [[ -n "$FILES_SECRET" ]] || { log_error "age-keygen failed"; exit 1; }
          FILES_RECIPIENT=$(printf '%s\n' "$FILES_SECRET" | age-keygen -y)
          FILES_ID=$(openssl rand -hex 8)
      }

      # Compare the free space a receiver reported with the source size.
      files_check_space() {
          local size="$1" free="$2" vm="$3"
          if [[ -n "$size" && -n "$free" ]] && (( size > free )); then
              log_error "Not enough space on ''${vm}: $(files_human "$size") to receive, $(files_human "$free") free"
              exit 1
          fi
      }

      # All ciphertext hashes must agree; prints the source hash.
      files_verify() {
          local src_hash="$1" h
          [[ "$src_hash" =~ ^[0-9a-f]{64}$ ]] || { log_error "Source reported no checksum"; exit 1; }
          shift
          for h in "$@"; do
              if [[ "$h" != "$src_hash" ]]; then
                  log_error "Checksum mismatch: source ''${src_hash:0:16}..., got ''${h:0:16}... (nothing was written)"
                  exit 1
              fi
          done
          echo "$src_hash"
      }

      # Files: transfer <src-vm>/<path> <dest-vm>/<dest-path>
      cmd_files_transfer() {
          local src_vm src_path dst_vm dst_path name
          files_split "$1"; src_vm="$FILES_VM"; src_path="$FILES_PATH"
          files_split "$2"; dst_vm="$FILES_VM"; dst_path="$FILES_PATH"
          name="''${src_path##*/}"
          [[ -n "$src_path" ]] || { log_error "Name a path inside the source VM: <vm>/<path>"; exit 1; }
          [[ "$src_vm" != "$dst_vm" ]] || { log_error "Source and destination are the same VM"; exit 1; }

          local src_cid dst_cid src_ip dst_ip
          src_cid=$(get_vm_cid "$src_vm") || exit 1
          dst_cid=$(get_vm_cid "$dst_vm") || exit 1
          src_ip=$(get_vm_ip "$src_vm")
          dst_ip=$(get_vm_ip "$dst_vm")
          [[ -n "$src_ip" ]] || { log_error "Unknown IP for $src_vm (not in registry)"; exit 1; }
          [[ -n "$dst_ip" ]] || { log_error "Unknown IP for $dst_vm (not in registry)"; exit 1; }

          log "Origin:      ''${BOLD}''${src_vm}/''${src_path}''${NC}"
          log "Destination: ''${BOLD}''${dst_vm}/''${dst_path}''${dst_path:+/}''${name}''${NC}"

          local missing_vms=""
          is_running "$src_vm" || missing_vms+="source VM ($src_vm) "
          is_running "$dst_vm" || missing_vms+="destination VM ($dst_vm) "
          if [[ -n "$missing_vms" ]]; then
              log_error "Required VM(s) not running: ''${missing_vms% }"
              log_error "Start the missing VM(s) before transferring files."
              exit 1
          fi

          files_begin
          files_vm_up
          FILES_ABORT=("$dst_cid $VM_AGENT_PORT" "$src_cid $VM_AGENT_PORT" "$FILES_VM_CID $FILES_VSOCK_PORT")
          files_keypair

          local dst_out="$FILES_TMP/dst" src_out="$FILES_TMP/src" relay_out="$FILES_TMP/relay"
          local dst_pid src_pid relay_pid dst_ready src_ready size

          # The destination gets the identity on a second line, never in a command field.
          files_bg "$dst_out" "$dst_cid" "$VM_AGENT_PORT" \
              "RECV $FILES_ID $(files_b64 "$name") $(files_b64 "$dst_path")"$'\n'"$FILES_SECRET"
          dst_pid=$FILES_LAST_PID
          FILES_SECRET=""
          dst_ready=$(files_wait_listening "$dst_out" "$dst_pid" "$dst_vm") || exit 1

          files_bg "$src_out" "$src_cid" "$VM_AGENT_PORT" "SEND $FILES_RECIPIENT $(files_b64 "$src_path")"
          src_pid=$FILES_LAST_PID
          src_ready=$(files_wait_listening "$src_out" "$src_pid" "$src_vm") || exit 1
          size=$(files_field "$src_ready" SIZE)
          files_check_space "$size" "$(files_field "$dst_ready" FREE)" "$dst_vm"

          log "Streaming $(files_human "$size") through ''${FILES_VM_NAME} (age-encrypted)..."
          files_bg "$relay_out" "$FILES_VM_CID" "$FILES_VSOCK_PORT" "RELAY $src_ip $dst_ip"
          relay_pid=$FILES_LAST_PID
          files_wait_progress "$relay_out" "$relay_pid"

          local relay_res src_res dst_res hash
          relay_res=$(files_result "$relay_out")
          [[ "$relay_res" == OK* ]] || { log_error "''${FILES_VM_NAME}: ''${relay_res:-no reply}"; exit 1; }
          wait "$src_pid" 2>/dev/null || true
          src_res=$(files_result "$src_out")
          [[ "$src_res" == OK* ]] || { log_error "''${src_vm}: ''${src_res:-no reply}"; exit 1; }
          wait "$dst_pid" 2>/dev/null || true
          dst_res=$(files_result "$dst_out")
          files_warnings "$dst_vm" "$dst_out"
          [[ "$dst_res" == OK* ]] || { log_error "''${dst_vm}: ''${dst_res:-no reply}"; exit 1; }

          hash=$(files_verify "$(files_field "$src_res" SHA256)" \
              "$(files_field "$relay_res" SHA256)" "$(files_field "$dst_res" SHA256)") || exit 1
          log "Checksum verified on all three VMs: ''${hash:0:16}... ($(files_human "$(files_field "$dst_res" BYTES)") ciphertext)"

          local commit
          commit=$(vsock_query "$dst_cid" "$VM_AGENT_PORT" "COMMIT $FILES_ID $hash" 10 120)
          [[ "$commit" == OK ]] || { log_error "''${dst_vm}: commit failed: ''${commit:-no reply}"; exit 1; }

          local skipped
          skipped=$(files_field "$dst_res" SKIPPED)
          [[ "''${skipped:-0}" == 0 ]] || log_warn "''${skipped} link(s) or special file(s) were not transferred"
          log_success "Transfer complete: ''${dst_vm}:''${dst_path}''${dst_path:+/}''${name}"
      }

      # Files: help
      cmd_files_help() {
          cat <<EOF
      ''${BOLD}shard files''${NC} - Encrypted inter-VM file transfer

      ''${BOLD}USAGE''${NC}
          shard files <command> [args]

      ''${BOLD}COMMANDS''${NC}
          transfer <src-vm>/<path> <dest-vm>/<dest-dir>
              Copy a file or directory into <dest-dir> (relative to the
              destination's home; empty = home). Source stays untouched,
              an existing <dest-dir>/<name> is never overwritten.
              The files VM runs only for the transfer and is stopped (and
              so wiped) when it ends, even if it was already running.

      ''${BOLD}SECURITY''${NC}
          - Streamed as age(zstd(tar)): X25519 + ChaCha20-Poly1305, every
            64 KiB chunk and the end of the stream authenticated
          - Fresh age identity per operation, made on the host: the source
            gets only the public recipient, the receiver gets the identity
            over vsock, the files VM never holds a key
          - Ciphertext only on bridge networks; nothing stored in transit,
            the files VM keeps no data and has no disk
          - The receiver extracts into staging (regular files and dirs only)
            and moves it into place only after the source, files VM and
            receiver report the same ciphertext SHA-256
          - Any failure or Ctrl-C aborts every side and drops staged data

      ''${BOLD}EXAMPLES''${NC}
          shard files transfer pentest/projects/google/artifacts comms/pentest/google
          shard files transfer browsing/Downloads/report.pdf hostsync/
      EOF
      }

      # Files: dispatcher
      cmd_files() {
          local subcmd="''${1:-help}"
          shift 2>/dev/null || true

          case "$subcmd" in
              transfer) [[ $# -lt 2 ]] && { log_error "Usage: shard files transfer <src-vm>/<path> <dest-vm>/<path>"; exit 1; }
                        cmd_files_transfer "$@" ;;
              help|-h|--help) cmd_files_help ;;
              *)
                  log_error "Unknown files command: $subcmd"
                  cmd_files_help
                  return 1
                  ;;
          esac
      }

      # Usage
      usage() {
          cat <<EOF
      ''${BOLD}shard''${NC} - Simple microVM management with timing

      ''${BOLD}USAGE''${NC}
          shard <command> [args...]      Word form
          shard -<flags> <name> [...]    Flag form: combinable, run in the order given

      ''${BOLD}COMMANDS''${NC} (flag | word, both always work)
        ''${BOLD}Lifecycle:''${NC}
          -b | build <name>            Build microVM image
          -s | start <name>            Start microVM (waits until ready)
          -S | stop <name>             Stop microVM
          -R | restart <name>          Restart microVM
          -r | rebuild <name>          Build + live switch (no restart)
          -w | switch <name> [path]    Live switch to (already-)built config
          -W | switch-status <name>    Show live vs built configuration paths

        ''${BOLD}Apps & Sessions:''${NC}
          -a | app <name> <cmd>        Launch app in microVM (must be used alone)
          -c | console <name>          Attach to serial console (headless VMs)

        ''${BOLD}Status:''${NC}
          -i | status [name]           Show status of microVM(s)
          -l | logs <name>             View microVM logs (follow)
          list                         List all declared microVMs

        ''${BOLD}Builder (lockdown mode):''${NC}
          builder <cmd>           Streamlined build workflow (see: shard builder help)

        ''${BOLD}Git-Sync (lockdown mode):''${NC}
          git <cmd>               Git operations via git-sync VM (see: shard git help)

        ''${BOLD}File transfer:''${NC}
          files <cmd>             Encrypted inter-VM file ops (see: shard files help)

        ''${BOLD}Task pentest VMs:''${NC}
          pentest task<N> <name>  Bind an engagement to a task slot (see: shard pentest help)

        ''${BOLD}Store tiers:''${NC}
          cache <cmd>             Host cache for tier builders: export, clear, status

        ''${BOLD}Encryption:''${NC}
          encrypt-setup <name>    Set up LUKS-encrypted home volume (run once, VM must be stopped)
                                  Only needed to pre-provision before a build; 'shard build' auto-sets
                                  this up already if hydrix.microvm.encryption.enable is set.

        ''${BOLD}Utilities:''${NC}
          -t | test <name>        Full workflow test with timing
          -p | purge <name> [-f]  Delete all persistent data (fresh start)
          gc [-f]                 List (and, with confirmation, delete) /var/lib/microvms/
                                  directories with no matching VM in the current flake
          backup <action>         Back up/restore a stopped VM's volumes (create/list/restore/delete)
          -g | generations <act>  A VM's builds: list [vm], switch <vm> <N>, purge <vm> <N...|old>
                                  (see: shard -g help)

      ''${BOLD}FLAGS COMBINE, IN ORDER''${NC}
          shard -bs browsing              build then start, one VM
          shard -bs browsing lurking      build(browsing), build(lurking),
                                           start(browsing), start(lurking) - flag-major
          shard -sb browsing lurking      reversed: start both, then build both
          -a and -w take an extra argument (app command / explicit path) and can't
          be combined with other flags or multiple VM names. -g takes an action
          (shard -g list|switch|purge ...) and stands alone too.

      ''${BOLD}MICROVM TYPES''${NC}
          browsing                 Web browsing, persistent (10GB home)
          pentest                  Pentesting, persistent (100GB home, optionally LUKS-encrypted)
          dev                      Development, persistent (50GB home + 20GB docker)
          comms                    Communications, persistent
          lurking                  Darknet/Tor, ephemeral (maximum privacy)
          router                   WiFi passthrough router
          builder                  Builder for lockdown mode (populates host store)
          gitsync                  Git-sync for lockdown mode (push/pull repos)
          files                    Encrypted file transfer hub (see: shard files)
          task1 .. taskN           Task slots from tasks/default.nix, or use the bound
                                   engagement name (see: shard pentest)

          Each profile/task VM above is its own per-machine VM (e.g. "browsing" resolves to
          microvm-browsing-<serial> for whichever machine you're on) - always use the short
          name shown here, never the full nixosConfiguration name directly.

      ''${BOLD}EXAMPLES''${NC}
          # Build and start a microVM
          shard -bs browsing
          shard app browsing firefox

          # Live switch to whatever's already built (no restart)
          shard switch browsing

          # Or build and switch separately
          shard -b browsing
          shard -w browsing

          # Check what's running vs what's built
          shard switch-status browsing

          # Restart (for kernel/initrd changes)
          shard -bR browsing

          # Backups (VM must be stopped)
          shard backup create browsing before-update
          shard backup restore browsing before-update

          # Purge and start fresh (deletes all persistent data)
          shard -p dev
          shard -b dev

          # Clean up orphaned VM directories (renamed/removed profiles, old test VMs)
          shard gc

          # Encrypted home volume (pentest VM, auto-provisioned on build if enabled)
          shard build pentest             # Rebuild to point VM at encrypted volume
          shard start pentest             # Prompts for passphrase, then starts normally
          shard stop pentest              # Stops VM and locks volume automatically

          # Builder workflow (streamlined)
          shard builder build browsing pentest dev  # All in one session: eval cache warm after first
          shard builder switch             # Build AND apply host config (preserves specialisation)
          shard builder fetch pentest      # Just prefetch deps
          shard builder stop               # Stop when done

          # Builder workflow (manual)
          shard builder start
          shard builder shell              # Interactive console
          shard builder stop

      ''${BOLD}NOTE''${NC}
          For task-specific pentest VMs (per-engagement): shard pentest help
          For lab environments (Windows, AD, multi-machine): use libvirt with deploy-vm.sh
      EOF
      }

      # Flags: single ASCII letters mapped to per-VM lifecycle/status ops. Both
      # this flag form and the word form in main() below always work and dispatch
      # to the exact same cmd_* functions.
      readonly VALID_FLAG_LETTERS="bsSrRwWaciplt"

      flag_to_word() {
          case "$1" in
              b) echo build ;;
              s) echo start ;;
              S) echo stop ;;
              r) echo rebuild ;;
              R) echo restart ;;
              w) echo switch ;;
              W) echo switch-status ;;
              a) echo app ;;
              c) echo console ;;
              i) echo status ;;
              l) echo logs ;;
              p) echo purge ;;
              t) echo test ;;
          esac
      }

      # Parse a flag-form invocation (e.g. "-bs browsing lurking") into a
      # flag-major, mixed-token-order-preserving dispatch: each flag runs across
      # every listed VM before moving to the next flag. Flags may be one combined
      # token (-bs) or several separate tokens (-b -s); order is preserved across
      # both. VM names may appear anywhere relative to the flag tokens. A bare
      # -f/--force token is captured separately and passed through to purge.
      dispatch_flags() {
          # -a (app) and -w (switch) take extra passthrough arguments that may
          # themselves start with '-' (an app command, an explicit store path), so
          # they get a dedicated fast path before any generic tokenizing runs on
          # the rest of argv - this must check "$1" literally, before flags/vms
          # are split out below.
          # -g (generations) takes an action first: shard -g list|switch|purge ...
          if [[ "$1" == "-g" ]]; then
              shift
              cmd_generations "$@"
              return
          fi
          if [[ "$1" == "-a" || "$1" == "-w" ]]; then
              local which="$1"
              shift
              local vm_arg="''${1:-}"
              [[ -z "$vm_arg" ]] && {
                  log_error "Usage: shard $which <vm> $( [[ "$which" == "-a" ]] && echo "<command>" || echo "[path]" )"
                  exit 1
              }
              shift
              local vm
              vm="$(resolve_vm_name "$vm_arg")"
              if [[ "$which" == "-a" ]]; then
                  cmd_app "$vm" "$@"
              else
                  cmd_switch "$vm" "$@"
              fi
              return
          fi

          local flags=() vms=() force=""
          local tok
          for tok in "$@"; do
              case "$tok" in
                  -f|--force)
                      force="-f"
                      ;;
                  -*)
                      local letters="''${tok#-}"
                      local i ch
                      for ((i = 0; i < ''${#letters}; i++)); do
                          ch="''${letters:$i:1}"
                          [[ "$VALID_FLAG_LETTERS" == *"$ch"* ]] || {
                              log_error "Unknown flag: -$ch"
                              usage
                              exit 1
                          }
                          flags+=("$ch")
                      done
                      ;;
                  *)
                      vms+=("$tok")
                      ;;
              esac
          done

          local f
          for f in "''${flags[@]}"; do
              if [[ "$f" == "a" || "$f" == "w" ]]; then
                  log_error "Flag -$f ($(flag_to_word "$f")) must be used alone: shard -$f <vm> ..."
                  exit 1
              fi
          done

          [[ ''${#flags[@]} -eq 0 ]] && { log_error "No flags given"; usage; exit 1; }

          if [[ ''${#vms[@]} -eq 0 ]]; then
              # status is the only op with an optional VM name in word form too.
              if [[ ''${#flags[@]} -eq 1 && "''${flags[0]}" == "i" ]]; then
                  cmd_status ""
                  return
              fi
              log_error "No VM name given"
              usage
              exit 1
          fi

          local v vm
          for f in "''${flags[@]}"; do
              for v in "''${vms[@]}"; do
                  vm="$(resolve_vm_name "$v")"
                  case "$f" in
                      b) log "Building ''${BOLD}''${vm}''${NC}..."; cmd_build "$vm"; echo "" ;;
                      s) log "Starting ''${BOLD}''${vm}''${NC}..."; cmd_start "$vm"; echo "" ;;
                      S) log "Stopping ''${BOLD}''${vm}''${NC}..."; cmd_stop "$vm"; echo "" ;;
                      r)
                          log "Rebuilding ''${BOLD}''${vm}''${NC} (build + live switch)..."
                          _HYDRIX_APPLYING=1 cmd_build "$vm" || continue
                          if is_running "$vm"; then
                              cmd_switch "$vm" || continue
                          else
                              log "VM not running. Use 'shard start' to launch it."
                          fi
                          echo ""
                          ;;
                      R) cmd_restart "$vm"; echo "" ;;
                      W) cmd_switch_status "$vm" ;;
                      c) cmd_console "$vm" ;;
                      i) cmd_status "$vm" ;;
                      l) cmd_logs "$vm" ;;
                      p) log "Purging ''${BOLD}''${vm}''${NC}..."; cmd_purge "$vm" "$force"; echo "" ;;
                      t) cmd_test "$vm" ;;
                  esac
              done
          done
      }

      # Main
      main() {
          BACKUP_NOTICE_FILE=$(mktemp -t shard-backup-notice.XXXXXX)
          trap backup_notices EXIT

          if [[ $# -lt 1 ]]; then
              usage
              exit 0
          fi

          if [[ "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
              usage
              return
          fi

          if [[ "$1" == -* ]]; then
              dispatch_flags "$@"
              return
          fi

          local cmd="$1"
          shift

          case "$cmd" in
              build)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard build <name1> [name2] ..."; exit 1; }
                  for vm in "$@"; do
                      vm="$(resolve_vm_name "$vm")"
                      log "Building ''${BOLD}''${vm}''${NC}..."
                      cmd_build "$vm"
                      echo ""
                  done
                  ;;
              rebuild)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard rebuild <name1> [name2] ..."; exit 1; }
                  for vm in "$@"; do
                      vm="$(resolve_vm_name "$vm")"
                      log "Rebuilding ''${BOLD}''${vm}''${NC} (build + live switch)..."
                      _HYDRIX_APPLYING=1 cmd_build "$vm" || continue
                      if is_running "$vm"; then
                          cmd_switch "$vm" || continue
                      else
                          log "VM not running. Use 'shard start' to launch it."
                      fi
                      echo ""
                  done
                  ;;
              start)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard start <name1> [name2] ..."; exit 1; }
                  for vm in "$@"; do
                      vm="$(resolve_vm_name "$vm")"
                      log "Starting ''${BOLD}''${vm}''${NC}..."
                      cmd_start "$vm"
                      echo ""
                  done
                  ;;
              stop)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard stop <name1> [name2] ..."; exit 1; }
                  for vm in "$@"; do
                      vm="$(resolve_vm_name "$vm")"
                      log "Stopping ''${BOLD}''${vm}''${NC}..."
                      cmd_stop "$vm"
                      echo ""
                  done
                  ;;
              restart)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard restart <name1> [name2] ..."; exit 1; }
                  for vm in "$@"; do
                      vm="$(resolve_vm_name "$vm")"
                      cmd_restart "$vm"
                      echo ""
                  done
                  ;;
              switch)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard switch <name> [path]"; exit 1; }
                  set -- "$(resolve_vm_name "$1")" "''${@:2}"
                  cmd_switch "$@"
                  ;;
              switch-status)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard switch-status <name>"; exit 1; }
                  cmd_switch_status "$(resolve_vm_name "$1")"
                  ;;
              app)
                  [[ $# -lt 2 ]] && { log_error "Usage: shard app <name> <command>"; exit 1; }
                  set -- "$(resolve_vm_name "$1")" "''${@:2}"
                  cmd_app "$@"
                  ;;
              status)
                  cmd_status "$([[ -n "''${1:-}" ]] && resolve_vm_name "$1")"
                  ;;
              list)
                  cmd_list
                  ;;
              logs)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard logs <name>"; exit 1; }
                  cmd_logs "$(resolve_vm_name "$1")"
                  ;;
              console)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard console <name>"; exit 1; }
                  local vm
                  vm="$(resolve_vm_name "$1")"
                  cmd_console "$vm"
                  ;;
              builder)
                  cmd_builder "$@"
                  ;;
              pentest|task)
                  cmd_pentest "$@"
                  ;;
              git)
                  cmd_git "$@"
                  ;;
              files)
                  cmd_files "$@"
                  ;;
              cache)
                  cmd_cache "$@"
                  ;;
              test)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard test <name>"; exit 1; }
                  cmd_test "$(resolve_vm_name "$1")"
                  ;;
              purge)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard purge <name1> [name2] ... [-f|--force]"; exit 1; }
                  local force=""
                  [[ "''${!#}" == "-f" || "''${!#}" == "--force" ]] && { force="''${!#}"; set -- "''${@:1:$(($#-1))}"; }
                  for vm in "$@"; do
                      vm="$(resolve_vm_name "$vm")"
                      log "Purging ''${BOLD}''${vm}''${NC}..."
                      cmd_purge "$vm" "$force"
                      echo ""
                  done
                  ;;
              gc)
                  cmd_gc "''${1:-}"
                  ;;
              gc-check)
                  # Internal: cache-writing mode for the hydrix-gc-check timer, not
                  # meant for interactive use (no output, never prompts).
                  cmd_gc_check
                  ;;
              encrypt-setup)
                  [[ $# -lt 1 ]] && { log_error "Usage: shard encrypt-setup <name> [size_mb]"; exit 1; }
                  set -- "$(resolve_vm_name "$1")" "''${@:2}"
                  cmd_encrypt_setup "$@"
                  ;;
              generations|gen)
                  cmd_generations "$@"
                  ;;
              root-inputs)
                  # Internal (rebuild): GC roots for the fetched flake inputs
                  root_flake_inputs
                  ;;
              backup)
                  [[ $# -lt 1 ]] && { cmd_backup help; exit 0; }
                  # The backup commands that already show or change backups skip the notice
                  [[ "$1" == "create" ]] || { rm -f "$BACKUP_NOTICE_FILE"; BACKUP_NOTICE_FILE=""; }
                  [[ $# -ge 2 ]] && set -- "$1" "$(resolve_vm_name "$2")" "''${@:3}"
                  cmd_backup "$@"
                  ;;
              *)
                  log_error "Unknown command: $cmd"
                  usage
                  exit 1
                  ;;
          esac
      }

      main "$@"
    '';
  };

  # Fish tab-completion: ships alongside the binary via symlinkJoin below so
  # both land in the same package output with no separate module wiring.
  # Reads VM names live from /etc/hydrix/vm-registry.json at completion
  # time, so new VMs show up without a rebuild.
  shardFishCompletion = pkgs.writeTextDir "share/fish/vendor_completions.d/shard.fish" ''
    function __shard_vm_names
        jq -r 'keys[]' /etc/hydrix/vm-registry.json 2>/dev/null
    end

    # Word subcommands only right after "shard" (fish's own check also fires after a flag)
    function __shard_use_subcommand
        test (count (commandline -opc)) -eq 1
    end

    function __shard_first_is_flag
        set -l toks (commandline -opc)
        test (count $toks) -ge 2
        and string match -q -- '-*' $toks[2]
        and not contains -- $toks[2] -g
    end

    # Generations (shard -g / generations / gen): action, then VM, then a generation
    function __shard_gen_at
        set -l toks (commandline -opc)
        test (count $toks) -ge 2; and contains -- $toks[2] -g generations gen; or return 1
        test (count $toks) -eq $argv[1]; or return 1
        test (count $argv) -lt 2; or contains -- $toks[3] $argv[2..]
    end

    function __shard_gen_numbers
        set -l toks (commandline -opc)
        set -l vm (jq -r --arg k $toks[4] '.[$k].vmName // $k' /etc/hydrix/vm-registry.json 2>/dev/null)
        set -l d /var/lib/microvms/$vm/generations
        for n in (path basename $d/* 2>/dev/null | sort -n)
            printf '%s\t%s\n' $n (cat $d/$n/created 2>/dev/null)
        end
        if test "$toks[3]" = switch
            printf 'prev\tthe one before current\nlatest\tthe newest\n'
        else
            printf 'old\tevery generation but current\n'
        end
    end

    # Short flags: combinable natively via fish's short-option completion engine.
    complete -c shard -s b -d Build
    complete -c shard -s s -d Start
    complete -c shard -s S -d Stop
    complete -c shard -s R -d Restart
    complete -c shard -s r -d 'Rebuild (build + switch)'
    complete -c shard -s w -d Switch
    complete -c shard -s W -d 'Switch status'
    complete -c shard -s a -d 'Launch app'
    complete -c shard -s c -d Console
    complete -c shard -s i -d Status
    complete -c shard -s l -d Logs
    complete -c shard -s p -d Purge
    complete -c shard -s t -d Test
    complete -c shard -s g -d 'Generations (list, switch, purge, gc)'

    # Word subcommands, first position only.
    complete -c shard -n __shard_use_subcommand -a build -d 'Build microVM image'
    complete -c shard -n __shard_use_subcommand -a start -d 'Start microVM'
    complete -c shard -n __shard_use_subcommand -a stop -d 'Stop microVM'
    complete -c shard -n __shard_use_subcommand -a restart -d 'Restart microVM'
    complete -c shard -n __shard_use_subcommand -a rebuild -d 'Build + live switch'
    complete -c shard -n __shard_use_subcommand -a switch -d 'Live switch to built config'
    complete -c shard -n __shard_use_subcommand -a switch-status -d 'Show live vs built config'
    complete -c shard -n __shard_use_subcommand -a app -d 'Launch app in microVM'
    complete -c shard -n __shard_use_subcommand -a console -d 'Attach serial console'
    complete -c shard -n __shard_use_subcommand -a status -d 'Show VM status'
    complete -c shard -n __shard_use_subcommand -a list -d 'List all declared microVMs'
    complete -c shard -n __shard_use_subcommand -a logs -d 'Follow VM logs'
    complete -c shard -n __shard_use_subcommand -a builder -d 'Lockdown-mode build workflow'
    complete -c shard -n __shard_use_subcommand -a git -d 'Git ops via gitsync VM'
    complete -c shard -n __shard_use_subcommand -a files -d 'Encrypted inter-VM file transfer'
    complete -c shard -n __shard_use_subcommand -a pentest -d 'Bind engagements to task slots'
    complete -c shard -n __shard_use_subcommand -a task -d 'Alias for pentest'
    complete -c shard -n __shard_use_subcommand -a test -d 'Full workflow smoke test'
    complete -c shard -n __shard_use_subcommand -a purge -d 'Delete all persistent data'
    complete -c shard -n __shard_use_subcommand -a gc -d 'Clean up orphaned VM directories'
    complete -c shard -n __shard_use_subcommand -a backup -d 'Back up/restore VM volumes'
    complete -c shard -n "__fish_seen_subcommand_from backup; and not __fish_seen_subcommand_from create list restore delete" -a "create list restore delete"
    complete -c shard -n __shard_use_subcommand -a encrypt-setup -d 'Set up LUKS-encrypted home volume'
    complete -c shard -n __shard_use_subcommand -a help -d 'Show usage'
    complete -c shard -n __shard_use_subcommand -a generations -d "A VM's builds: list, switch, purge"
    complete -c shard -n "__shard_gen_at 2" -f -a "list switch purge gc help"
    complete -c shard -n "__shard_gen_at 3 list switch purge" -f -a "(__shard_vm_names)"
    complete -c shard -n "__shard_gen_at 4 switch purge" -f -a "(__shard_gen_numbers)"

    # VM-name completion: dynamic, read live from the registry every time (no
    # rebuild/session-restart needed when VMs are added). Fires after a
    # flag-prefixed first token, or after any still-word-based subcommand that
    # takes a VM name.
    complete -c shard -n __shard_first_is_flag -a "(__shard_vm_names)"
    complete -c shard -n "__fish_seen_subcommand_from status logs console app purge encrypt-setup backup test switch switch-status" -a "(__shard_vm_names)"
  '';
in
  pkgs.symlinkJoin {
    name = "shard";
    paths = [shardApp shardFishCompletion];
  }
