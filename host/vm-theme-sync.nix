# VM Theme Sync Module
#
# Shares the host's entire wal cache directory to VMs via virtiofs,
# replacing the old model where the host pushes only a BG hex via vsock
# and each VM runs Python pywal (~500ms) to regenerate caches.
#
# ═══════════════════════════════════════════════════════════════════════
# COLOR FLOW — How colors reach VM terminals
# ═══════════════════════════════════════════════════════════════════════
#
# ┌─── HOST ────────────────────────────────────────────────────────────┐
# │ walrgb <image>                                                      │
# │   └→ pywal generates ~/.cache/wal/{colors.json, sequences, ...}     │
# │        └→ systemd path unit detects change to colors.json           │
# │             └→ wal-cache-notify sends "REFRESH" to VM vsock:14503   │
# └─────────────────────────────────────────────────────────────────────┘
#          │ virtiofs share (wal-cache tag)
#          ▼
# ┌─── VM ──────────────────────────────────────────────────────────────┐
# │ /mnt/wal-cache  ←  host's ~/.cache/wal (read-only virtiofs)         │
# │   └→ ~/.cache/wal  real directory, populated by wal-cache-link svc  │
# │      (never a symlink — VM wal cache is isolated from host)         │
# │                                                                     │
# │ STARTUP (boot-time, before any terminal opens):                     │
# │   wal-cache-link service:                                           │
# │     1. Ensures ~/.cache/wal is a real directory (removes symlink    │
# │        if present from older installs)                              │
# │     2. Copies /mnt/wal-cache/* → ~/.cache/wal/ (host colors)        │
# │     3. Generates ~/.config/alacritty/colors-runtime.toml via jq     │
# │                                                                     │
# │ TERMINAL OPEN:                                                      │
# │   alacritty starts → reads alacritty.toml (nix store, immutable)    │
# │     └→ general.import = ["~/.config/alacritty/colors-runtime.toml"] │
# │          └→ all 16 ANSI colors + primary fg/bg loaded from TOML     │
# │   fish starts → NO escape sequences applied (Stylix fish disabled,  │
# │                  wal sequences not sourced — VMs use config import) │
# │   starship renders prompt                                           │
# │                                                                     │
# │ RUNTIME REFRESH (host changes wallpaper while VM is running):       │
# │   vm-colorscheme-refresh vsock handler receives "REFRESH"           │
# │     1. Re-generates colors-runtime.toml from updated wal cache      │
# │        (new terminals will pick up new colors on start)             │
# │     2. Runs refresh-colors script for existing terminals:           │
# │        - OSC escape sequences to running terminals                  │
# │        - pywalfox, dunst updates                                    │
# │        Note: SIGUSR1 to alacritty is NOT used (unreliable)          │
# └─────────────────────────────────────────────────────────────────────┘
#
# ═══════════════════════════════════════════════════════════════════════
# WHAT THIS MODULE DISABLES (and why)
# ═══════════════════════════════════════════════════════════════════════
#
# Old pipeline (replaced):
#   vm-colorscheme (vsock:14503)  — received BG hex, ran pywal to regen
#   wal-sync timer                — polled host colors every 10s
#   init-wal-cache                — ran wal -q --theme on login, destroyed
#                                   our symlink and regenerated with nord
#
# Stylix conflicts (disabled):
#   stylix.targets.fish (system)  — base16-untitled.fish sourced in
#                                   /etc/fish/config.fish, applied OSC
#                                   escape sequences on every interactive
#                                   shell start, overriding alacritty's
#                                   config-based colors with build-time
#                                   Stylix palette. The home-manager
#                                   stylix.targets.fish.enable = false
#                                   only affects HM-level config, not
#                                   the system /etc/fish/config.fish.
#
# ═══════════════════════════════════════════════════════════════════════
# HOST-SIDE SERVICES
# ═══════════════════════════════════════════════════════════════════════
#
#   wal-cache-ensure    — oneshot: mkdir ~/.cache/wal (virtiofs needs it)
#   wal-cache-init      — oneshot: pre-populate wal cache from wallpaper/colorscheme
#   wal-cache-notify    — path unit watches colors.json, service sends
#                         REFRESH to vsock:14503 on all known VM CIDs
#   hydrix-focus        — CLI: toggle per-VM override colors (on/off/toggle/status)
#
# ═══════════════════════════════════════════════════════════════════════
# VM-SIDE SERVICES
# ═══════════════════════════════════════════════════════════════════════
#
#   wal-cache-link          — oneshot: copies host colors into VM's own
#                             ~/.cache/wal + generates colors-runtime.toml
#   vm-colorscheme-refresh  — vsock listener: copies updated host colors,
#                             re-generates TOML + refreshes running apps
#
# ═══════════════════════════════════════════════════════════════════════
# OPTIONS
# ═══════════════════════════════════════════════════════════════════════
#
#   hydrix.vmThemeSync.enable           — bool, default false
#   hydrix.vmThemeSync.useHostWal       — bool, default true
#     true:  copy host colors into VM's own ~/.cache/wal on boot + refresh
#            VM has an isolated local wal cache; /mnt/wal-cache is read-only
#     false: VM keeps own colorscheme, no virtiofs share
#   hydrix.vmThemeSync.focusDaemon.dynamicColorMap — attrs
#     Maps VM types to wal color keys (e.g. pentest → color1)
#
# ═══════════════════════════════════════════════════════════════════════
# NIXOS MODULE SYSTEM NOTES
# ═══════════════════════════════════════════════════════════════════════
#
# microvm.shares guard: uses plain `if hasMicrovmShares` (not mkIf)
#   because mkIf false does NOT prevent option path resolution —
#   the host has microvm.* options (from microvm.nixosModules.host)
#   but NOT microvm.shares (that's only in the guest module).
#   Plain `if` on `options ? microvm && options.microvm ? shares`
#   avoids the "option does not exist" error at evaluation time.
#
# Infinite recursion: the plain `if` guard must NOT reference config.*
#   values (like isVM), only options-level checks. Config values inside
#   are wrapped in mkIf for proper lazy evaluation.
#
{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  cfg = config.hydrix.vmThemeSync;
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "" && vmType != "host";
  isHost = !isVM;
  hasMicrovmShares = (options ? microvm) && (options.microvm ? shares);
  # Same plain-`if` guard as hasMicrovmShares above (not mkIf) for the same
  # reason: mkIf false does not prevent "option does not exist" errors.
  hasStylix = options ? stylix;
  jq = "${pkgs.jq}/bin/jq";

  # Script to generate colors-runtime.toml from host wal colors
  # Used by both boot-time init and vsock refresh handler
  generateAlacrittyColors = pkgs.writeShellScript "generate-alacritty-colors" ''
    USERNAME="${username}"
    RUNTIME_TOML="/home/$USERNAME/.config/alacritty/colors-runtime.toml"
    WAL_COLORS="/home/$USERNAME/.cache/wal/colors.json"

    if [ ! -f "$WAL_COLORS" ]; then
      echo "No wal colors at $WAL_COLORS"
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$RUNTIME_TOML")"
    ${jq} -r '
      "[colors.primary]\n" +
      "background = \"" + (.special.background // .colors.color0) + "\"\n" +
      "foreground = \"" + (.special.foreground // .colors.color7) + "\"\n\n" +
      "[colors.cursor]\n" +
      "cursor = \"" + (.special.cursor // .special.foreground // .colors.color7) + "\"\n" +
      "text = \"CellBackground\"\n\n" +
      "[colors.normal]\n" +
      "black = \"" + .colors.color0 + "\"\n" +
      "red = \"" + .colors.color1 + "\"\n" +
      "green = \"" + .colors.color2 + "\"\n" +
      "yellow = \"" + .colors.color3 + "\"\n" +
      "blue = \"" + .colors.color4 + "\"\n" +
      "magenta = \"" + .colors.color5 + "\"\n" +
      "cyan = \"" + .colors.color6 + "\"\n" +
      "white = \"" + .colors.color7 + "\"\n\n" +
      "[colors.bright]\n" +
      "black = \"" + .colors.color8 + "\"\n" +
      "red = \"" + (.colors.color9 // .colors.color1) + "\"\n" +
      "green = \"" + (.colors.color10 // .colors.color2) + "\"\n" +
      "yellow = \"" + (.colors.color11 // .colors.color3) + "\"\n" +
      "blue = \"" + (.colors.color12 // .colors.color4) + "\"\n" +
      "magenta = \"" + (.colors.color13 // .colors.color5) + "\"\n" +
      "cyan = \"" + (.colors.color14 // .colors.color6) + "\"\n" +
      "white = \"" + (.colors.color15 // .colors.color7) + "\""
    ' "$WAL_COLORS" > "$RUNTIME_TOML.tmp"
    ${pkgs.coreutils}/bin/mv "$RUNTIME_TOML.tmp" "$RUNTIME_TOML"
    ${pkgs.coreutils}/bin/chown $USERNAME:users "$RUNTIME_TOML"
  '';
in {
  options.hydrix.vmThemeSync = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable VM theme sync via shared wal cache";
    };

    useHostWal = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Copy host wal colors into VM's own local cache (false = VM uses own colorscheme)";
    };

    focusDaemon = {
      dynamicColorMap = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          pentest = "color1";
          browsing = "color2";
          comms = "color3";
          dev = "color5";
          lurking = "color6";
        };
        description = "Map VM types to wal color keys for dynamic mode";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # =========================================================================
    # HOST-SIDE CONFIGURATION
    # =========================================================================
    (lib.mkIf isHost {
      # 1. Ensure wal cache dir exists at boot (before VMs start)
      # Virtiofsd crashes if the source path doesn't exist, and VMs start
      # at multi-user.target — before the user session creates the dir.
      systemd.tmpfiles.rules = [
        "d /home/${username}/.cache/wal 0755 ${username} users -"
      ];

      # Also keep the user service for redundancy
      systemd.user.services.wal-cache-ensure = {
        description = "Ensure wal cache directory exists for VM virtiofs";
        wantedBy = ["default.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/mkdir -p /home/${username}/.cache/wal";
        };
      };

      # 2. Pre-populate wal cache on first boot if empty
      systemd.user.services.wal-cache-init = {
        description = "Initialize wal cache from declared colorscheme";
        wantedBy = ["default.target"];
        after = ["wal-cache-ensure.service"];
        before = ["wal-cache-notify.path"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [pkgs.pywal];
        script = let
          colorscheme = config.hydrix.colorscheme;
          configDir = config.hydrix.paths.configDir;
        in ''
          WAL_COLORS="/home/${username}/.cache/wal/colors.json"
          if [ -f "$WAL_COLORS" ]; then
            echo "wal cache already populated, skipping"
            exit 0
          fi
          echo "Generating wal cache from colorscheme: ${colorscheme}"
          SCHEME=""
          if [ -f "${configDir}/colorschemes/${colorscheme}.json" ]; then
            SCHEME="${configDir}/colorschemes/${colorscheme}.json"
          fi
          if [ -n "$SCHEME" ]; then
            wal -q --theme "$SCHEME"
          else
            echo "Colorscheme file not found: ${colorscheme}"
            exit 1
          fi
        '';
      };

      # 3. Path watcher for automatic VM notification on color changes
      systemd.user.paths.wal-cache-notify = {
        description = "Watch wal cache for color changes";
        wantedBy = ["default.target"];
        pathConfig = {
          PathChanged = "/home/${username}/.cache/wal/colors.json";
          Unit = "wal-cache-notify.service";
        };
      };

      # 3. Notify all running VMs to refresh colors
      systemd.user.services.wal-cache-notify = {
        description = "Notify VMs of color change via vsock";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = let
            notifyScript = pkgs.writeShellScript "notify-vms-colorscheme" ''
              PORT=14503
              LOG="/tmp/notify-vms-colorscheme.log"
              VM_REGISTRY="/etc/hydrix/vm-registry.json"
              log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

              if [[ -f "$VM_REGISTRY" ]]; then
                while IFS= read -r key; do
                  [[ -z "$key" ]] && continue
                  vm=$(${pkgs.jq}/bin/jq -r --arg k "$key" '.[$k].vmName // empty' "$VM_REGISTRY")
                  cid=$(${pkgs.jq}/bin/jq -r --arg k "$key" '.[$k].cid // empty' "$VM_REGISTRY")
                  [[ -z "$vm" || -z "$cid" ]] && continue
                  if systemctl is-active --quiet "microvm@$vm.service" 2>/dev/null; then
                    result=$(echo "REFRESH" | ${pkgs.socat}/bin/socat -t1 - "VSOCK-CONNECT:$cid:$PORT" 2>/dev/null || echo "FAIL")
                    log "$vm (cid=$cid): $result"
                  fi
                done < <(${pkgs.jq}/bin/jq -r 'keys[]' "$VM_REGISTRY")
              fi
            '';
          in
            notifyScript;
        };
      };

      # 4. hydrix-focus CLI for toggling per-VM override colors
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "hydrix-focus" ''
          MARKER="$HOME/.cache/hydrix/focus-override-active"
          HB_STATE="$HOME/.config/hypr/vm-borders-enabled"
          HB_CONF="$HOME/.config/hypr/vm-borders.conf"
          mkdir -p "$(dirname "$MARKER")"

          status() {
            if [ -f "$MARKER" ]; then
              echo "Focus override: ON"
            else
              echo "Focus override: OFF"
            fi
          }

          # Hyprland: immediately re-apply border color for the focused window
          # using the new override state. The daemon checks the marker on every
          # subsequent focus event, so only the current window needs a nudge.
          signal_hyprland() {
            if [[ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
              hypr-focus-daemon reapply 2>/dev/null || true
            fi
          }

          case "''${1:-toggle}" in
            on)
              touch "$MARKER"
              echo "Focus override: ON"
              signal_hyprland
              ;;
            off)
              rm -f "$MARKER"
              echo "Focus override: OFF"
              signal_hyprland
              ;;
            toggle)
              if [ -f "$MARKER" ]; then
                rm -f "$MARKER"
                echo "Focus override: OFF"
              else
                touch "$MARKER"
                echo "Focus override: ON"
              fi
              signal_hyprland
              ;;
            status)
              status
              ;;
            *)
              echo "Usage: hydrix-focus [on|off|toggle|status]"
              exit 1
              ;;
          esac
        '')
      ];
    })

    # =========================================================================
    # VM-SIDE CONFIGURATION (useHostWal = true)
    # =========================================================================

    # 5. Virtiofs share for host wal cache
    # Uses plain `if` on hasMicrovmShares (doesn't depend on config, avoids infinite recursion)
    # The mkIf inside guards on actual config values
    (
      if hasMicrovmShares
      then {
        microvm.shares = lib.mkIf (isVM && cfg.useHostWal) [
          {
            tag = "wal-cache";
            source = "/home/${username}/.cache/wal";
            mountPoint = "/mnt/wal-cache";
            proto = "virtiofs";
            readOnly = true;
          }
        ];
      }
      else {}
    )

    (lib.mkIf (isVM && cfg.useHostWal) {
      # 6. Copy host wal cache into VM's own local directory
      # The VM has an isolated ~/.cache/wal — writes from restore-colorscheme,
      # wal-sync, pywal, etc. stay inside the VM and never reach the host.
      # /mnt/wal-cache (host's cache, read-only virtiofs) is the source of truth;
      # we copy from it at boot and on every REFRESH signal from the host.
      systemd.services.wal-cache-link = {
        description = "Copy host wal cache into VM local directory";
        wantedBy = ["multi-user.target"];
        after = ["local-fs.target"] ++ lib.optionals (hasMicrovmShares && config.hydrix.microvm.persistence.enable) ["home.mount"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [pkgs.util-linux pkgs.coreutils];
        script = ''
          USER_HOME="/home/${username}"
          WAL_DIR="$USER_HOME/.cache/wal"

          if ! mountpoint -q /mnt/wal-cache 2>/dev/null; then
            echo "wal-cache mount not present, skipping"
            exit 0
          fi

          mkdir -p "$USER_HOME/.cache"
          chown ${username}:users "$USER_HOME/.cache"

          # Remove any legacy symlink from older installs and create a real directory
          if [ -L "$WAL_DIR" ]; then
            rm "$WAL_DIR"
          fi
          mkdir -p "$WAL_DIR"
          chown ${username}:users "$WAL_DIR"

          # Copy host wal cache files into VM's own directory
          cp -f /mnt/wal-cache/* "$WAL_DIR/" 2>/dev/null || true
          chown ${username}:users "$WAL_DIR/"* 2>/dev/null || true

          # Generate colors-runtime.toml for alacritty from copied host colors
          WAL_COLORS="$WAL_DIR/colors.json"
          ALACRITTY_DIR="$USER_HOME/.config/alacritty"
          if [ -f "$WAL_COLORS" ]; then
            mkdir -p "$USER_HOME/.config"
            chown ${username}:users "$USER_HOME/.config"
            mkdir -p "$ALACRITTY_DIR"
            chown ${username}:users "$ALACRITTY_DIR"
            ${generateAlacrittyColors}
            echo "Generated colors-runtime.toml from host wal cache"

            # Generate GTK wal colors for file picker theming
            GEN_GTK="/run/current-system/sw/bin/generate-gtk-colors"
            if [ -x "$GEN_GTK" ]; then
              ${pkgs.sudo}/bin/sudo -u ${username} HOME="/home/${username}" "$GEN_GTK" 2>/dev/null || true
              echo "Generated gtk-wal.css from host wal cache"
            fi
          fi
        '';
      };

      # 7. Refresh server on vsock port 14503
      systemd.services.vm-colorscheme-refresh = {
        description = "VM colorscheme refresh server (vsock)";
        wantedBy = ["multi-user.target"];
        after = ["network.target" "wal-cache-link.service"];
        serviceConfig = {
          Type = "simple";
          ExecStart = let
            server = pkgs.writeShellScript "vm-colorscheme-refresh-server" ''
              while true; do
                ${pkgs.socat}/bin/socat VSOCK-LISTEN:14503,reuseaddr,fork EXEC:"${handler}",nofork
              done
            '';
            handler = pkgs.writeShellScript "vm-colorscheme-refresh-handler" ''
              # Read and discard the incoming message (REFRESH or BG hex)
              ${pkgs.coreutils}/bin/cat > /dev/null

              # Copy updated host colors from read-only virtiofs mount into VM's local cache
              WAL_DIR="/home/${username}/.cache/wal"
              if ${pkgs.util-linux}/bin/mountpoint -q /mnt/wal-cache 2>/dev/null; then
                ${pkgs.coreutils}/bin/cp -f /mnt/wal-cache/* "$WAL_DIR/" 2>/dev/null || true
                ${pkgs.coreutils}/bin/chown ${username}:users "$WAL_DIR/"* 2>/dev/null || true
              fi

              # Regenerate colors-runtime.toml from updated local wal cache
              ${generateAlacrittyColors}

              # Push wal sequences to all of the user's open terminal pts devices.
              # Running as root lets us write to any pts regardless of ownership.
              # This updates ANSI palette (starship, fastfetch, cursor color) in all
              # running terminals without requiring alacritty live_config_reload.
              SEQ_FILE="/home/${username}/.cache/wal/sequences"
              if [ -f "$SEQ_FILE" ]; then
                for pts in /dev/pts/[0-9]*; do
                  if [ "$(${pkgs.coreutils}/bin/stat -c %U "$pts" 2>/dev/null)" = "${username}" ]; then
                    ${pkgs.coreutils}/bin/cat "$SEQ_FILE" > "$pts" 2>/dev/null || true
                  fi
                done
              fi

              # Run refresh-colors for pywalfox, dunst, xsetroot (user-level apps)
              REFRESH="/run/current-system/sw/bin/refresh-colors"
              if [ -x "$REFRESH" ]; then
                UID_NUM=$(${pkgs.coreutils}/bin/id -u "${username}" 2>/dev/null || echo 1000)
                ${pkgs.sudo}/bin/sudo -u "${username}" \
                  HOME="/home/${username}" \
                  DISPLAY=:100 \
                  XDG_RUNTIME_DIR="/run/user/$UID_NUM" \
                  "$REFRESH" 2>/dev/null &
              fi

              echo "OK: refreshed"
            '';
          in
            server;
          Restart = "always";
          RestartSec = 5;
        };
      };

      # 8. Override scripts installed by vm-theming.nix with VM-local-cache versions
      environment.systemPackages = [
        # wal-sync: pull host colors into VM's local cache (manual trigger)
        (lib.hiPrio (pkgs.writeShellScriptBin "wal-sync" ''
          WAL_DIR="$HOME/.cache/wal"
          if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/wal-cache 2>/dev/null; then
            echo "Host wal cache not mounted at /mnt/wal-cache — run walrgb on the host first"
            exit 1
          fi
          mkdir -p "$WAL_DIR"
          ${pkgs.coreutils}/bin/cp -f /mnt/wal-cache/* "$WAL_DIR/" 2>/dev/null || true
          echo "Host colors synced to VM cache"
          refresh-colors
        ''))

        # write-alacritty-colors: regenerate colors-runtime.toml from local wal cache
        (pkgs.writeShellScriptBin "write-alacritty-colors" ''
          WAL_COLORS="''${1:-$HOME/.cache/wal/colors.json}"
          ALACRITTY_COLORS="$HOME/.config/alacritty/colors-runtime.toml"
          if [ ! -f "$WAL_COLORS" ]; then exit 0; fi
          mkdir -p "$(dirname "$ALACRITTY_COLORS")"
          ${jq} -r '
            "[colors.primary]\n" +
            "background = \"" + (.special.background // .colors.color0) + "\"\n" +
            "foreground = \"" + (.special.foreground // .colors.color7) + "\"\n\n" +
            "[colors.cursor]\n" +
            "cursor = \"" + (.special.cursor // .special.foreground // .colors.color7) + "\"\n" +
            "text = \"CellBackground\"\n\n" +
            "[colors.normal]\n" +
            "black = \"" + .colors.color0 + "\"\n" +
            "red = \"" + .colors.color1 + "\"\n" +
            "green = \"" + .colors.color2 + "\"\n" +
            "yellow = \"" + .colors.color3 + "\"\n" +
            "blue = \"" + .colors.color4 + "\"\n" +
            "magenta = \"" + .colors.color5 + "\"\n" +
            "cyan = \"" + .colors.color6 + "\"\n" +
            "white = \"" + .colors.color7 + "\"\n\n" +
            "[colors.bright]\n" +
            "black = \"" + .colors.color8 + "\"\n" +
            "red = \"" + (.colors.color9 // .colors.color1) + "\"\n" +
            "green = \"" + (.colors.color10 // .colors.color2) + "\"\n" +
            "yellow = \"" + (.colors.color11 // .colors.color3) + "\"\n" +
            "blue = \"" + (.colors.color12 // .colors.color4) + "\"\n" +
            "magenta = \"" + (.colors.color13 // .colors.color5) + "\"\n" +
            "cyan = \"" + (.colors.color14 // .colors.color6) + "\"\n" +
            "white = \"" + (.colors.color15 // .colors.color7) + "\""
          ' "$WAL_COLORS" > "$ALACRITTY_COLORS.tmp" && \
          ${pkgs.coreutils}/bin/mv "$ALACRITTY_COLORS.tmp" "$ALACRITTY_COLORS"
        '')

        # refresh-colors: regenerate TOML + push OSC sequences to all running terminals.
        # Replaces the vm-theming.nix version which only writes to current stdout.
        (lib.hiPrio (pkgs.writeShellScriptBin "refresh-colors" ''
          WAL_COLORS="$HOME/.cache/wal/colors.json"
          if [ ! -f "$WAL_COLORS" ]; then
            echo "No wal colors at $WAL_COLORS"
            exit 1
          fi

          # Regenerate colors-runtime.toml so new terminals get the right colors
          write-alacritty-colors

          # Push wal sequences to all owned terminal pts devices
          WAL_SEQUENCES="$HOME/.cache/wal/sequences"
          if [ -f "$WAL_SEQUENCES" ]; then
            for pts in /dev/pts/[0-9]*; do
              if [ -O "$pts" ] 2>/dev/null; then
                ${pkgs.coreutils}/bin/cat "$WAL_SEQUENCES" > "$pts" 2>/dev/null || true
              fi
            done
          fi

          # pywalfox
          if command -v pywalfox >/dev/null 2>&1; then
            pywalfox update 2>/dev/null || true
          fi

          # GTK wal colors
          if command -v generate-gtk-colors >/dev/null 2>&1; then
            generate-gtk-colors 2>/dev/null || true
          fi

          # dunst
          if command -v generate-dunstrc-colors >/dev/null 2>&1; then
            generate-dunstrc-colors 2>/dev/null || true
            ${pkgs.procps}/bin/pkill dunst 2>/dev/null || true
          fi
        ''))
      ];

      # 10. Disable conflicting services
      systemd.services.vm-colorscheme.enable = lib.mkForce false;
      systemd.user.timers.wal-sync.enable = lib.mkForce false;

      # Disable init-wal-cache — it rm -rf's ~/.cache/wal and regenerates
      # from the VM's own colorscheme, overwriting the host colors we copied in
      home-manager.users.${username} = {...}: {
        systemd.user.services.init-wal-cache = lib.mkForce {
          Unit.Description = "Initialize pywal cache (disabled by vm-theme-sync)";
          Service = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
          Install.WantedBy = ["default.target"];
        };
      };
    })

    # 9. Disable Stylix fish target (system-level). See "Stylix (opt-in
    # theming)" in DOCUMENTATION.md for the hasStylix/exclusive pattern.
    (
      if hasStylix
      then {
        stylix.targets.fish.enable = lib.mkIf (isVM && cfg.useHostWal && !config.hydrix.graphical.stylix.exclusive) (lib.mkForce false);
      }
      else {}
    )

    # =========================================================================
    # VM-SIDE: useHostWal = false (keep existing behavior)
    # =========================================================================
    (lib.mkIf (isVM && !cfg.useHostWal) {
      # No virtiofs share, no symlink
      # Existing init-wal-cache handles wal generation from /etc/hydrix-colorscheme.json
      # Disable the old vsock BG-hex handler too (module handles its own colors)
      systemd.services.vm-colorscheme.enable = lib.mkForce false;
      systemd.user.timers.wal-sync.enable = lib.mkForce false;
    })
  ]);
}
