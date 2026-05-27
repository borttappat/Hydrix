# waypipe VM-side module
#
# Services (none auto-start — host pushes display mode at VM start via vsock:14509):
#
#   display-mode  (14509) — receives "xpra"/"waypipe"/"PING"/"STATUS" from host
#   waypipe-vsock          — waypipe client connecting to host (vsock:14507)
#   waypipe-launch(14508)  — receives app launch commands from host
#
# Flow:
#   microvm start <vm>  → host detects WM → "xpra"|"waypipe" → vsock:14509
#   VM display-mode     → starts xpra-vsock OR waypipe-vsock+waypipe-launch
#
#   waypipe client (VM): connects to host server on vsock:14507
#   waypipe server (HOST): listens on vsock:14507, forwards to Hyprland
#   Apps inside VM use WAYLAND_DISPLAY=waypipe-0
#
{ config, pkgs, lib, ... }:

let
  username = config.hydrix.username;
  audioEnabled = config.hydrix.microvm.audio.enable;
  # Derive title prefix from hostname: "microvm-lurking" → "lurking"
  titlePrefix = lib.removePrefix "microvm-" config.networking.hostName;
  titlePrefixArg = "--title-prefix \"[${titlePrefix}] \"";
  # Per-VM waypipe port derived from vsock CID: CID 106 → port 14606
  # Avoids collision when multiple VMs are connected simultaneously.
  waypipePort = toString (14600 + config.hydrix.microvm.vsockCid - 100);

  displayModeHandler = pkgs.writeShellScript "display-mode-handler" ''
    set -euo pipefail
    read -r cmd
    case "$cmd" in
      PING)
        echo "OK"
        ;;
      xpra)
        if systemctl list-unit-files xpra-vsock.service &>/dev/null; then
          systemctl stop waypipe-vsock waypipe-launch ${lib.optionalString audioEnabled "pulse-vsock"} 2>/dev/null || true
          systemctl start xpra-vsock
          echo "xpra"
        else
          echo "xpra-unavailable"
        fi
        ;;
      waypipe)
        systemctl stop xpra-vsock 2>/dev/null || true
        if systemctl is-active --quiet waypipe-vsock 2>/dev/null; then
          # Service running — check if socket actually exists (connection alive)
          if [[ ! -S "/run/user/1000/waypipe-0" ]]; then
            # Socket missing: vsock connection dead. Restart to reconnect to host.
            systemctl restart waypipe-vsock waypipe-launch 2>/dev/null || true
          fi
          # Socket exists and service active: leave running apps undisturbed.
          # waypipe-vsock will self-heal via Restart=always if connection drops.
        else
          systemctl start waypipe-vsock waypipe-launch 2>/dev/null || true
        fi
        ${lib.optionalString audioEnabled "systemctl start pulse-vsock 2>/dev/null || true"}
        echo "waypipe"
        ;;
      waypipe-reconnect)
        # Unconditional restart — used by waypipe-connect on startup/reconnect.
        # Unlike "waypipe", this always restarts regardless of socket state,
        # so a fresh host-side listener always gets a fresh VM connection.
        systemctl stop xpra-vsock 2>/dev/null || true
        systemctl restart waypipe-vsock waypipe-launch 2>/dev/null || true
        ${lib.optionalString audioEnabled "systemctl start pulse-vsock 2>/dev/null || true"}
        echo "waypipe"
        ;;
      STATUS)
        # Report "waypipe" only if both the socket exists AND waypipe-vsock is
        # active (not activating/restarting). A socket file alone is not enough —
        # it can persist from a previous session while the service is dead.
        if [[ -S "/run/user/1000/waypipe-0" ]] && \
           systemctl is-active --quiet waypipe-vsock 2>/dev/null; then
          echo "waypipe"
        elif systemctl is-active --quiet xpra-vsock 2>/dev/null; then
          echo "xpra"
        else
          echo "none"
        fi
        ;;
      TEST_VSOCK)
        # Test VM→HOST vsock: try connecting to host (CID 2) on port 14599
        if echo "PING" | ${pkgs.socat}/bin/socat -T3 - VSOCK-CONNECT:2:14599 2>/dev/null | grep -q "PONG"; then
          echo "VM_TO_HOST_OK"
        else
          echo "VM_TO_HOST_FAIL"
        fi
        ;;
      JOURNAL_WAYPIPE)
        journalctl -u waypipe-vsock -n 10 --no-pager 2>/dev/null || echo "no journal"
        ;;
      stop)
        # Stop all display services — host WM is exiting; next WM will push its mode on start.
        systemctl stop xpra-vsock waypipe-vsock waypipe-launch ${lib.optionalString audioEnabled "pulse-vsock"} 2>/dev/null || true
        echo "stopped"
        ;;
      LAUNCH_LOG)
        cat /tmp/waypipe-launch.log 2>/dev/null || echo "(no log)"
        ;;
      *)
        echo "unknown: $cmd"
        ;;
    esac
  '';
in {
  boot.kernelModules = [ "vmw_vsock_virtio_transport" ];

  environment.systemPackages = [ pkgs.waypipe pkgs.socat ];

  # XDG desktop portal — resolves file picker D-Bus calls immediately.
  # Without this, apps timeout (5-25s) waiting for a portal before falling back.
  # gtk backend handles FileChooser without needing a Wayland compositor.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "gtk" ];
  };

  # D-Bus-activated services don't inherit the user session environment,
  # so WAYLAND_DISPLAY is unset when xdg-desktop-portal-gtk starts.
  # GTK fails to initialize without a display → portal crashes → Firefox
  # waits out the full D-Bus timeout (~10s) before degrading.
  # Inject the known-fixed display name so the portal starts cleanly.
  systemd.user.services.xdg-desktop-portal.serviceConfig.Environment =
    [ "WAYLAND_DISPLAY=waypipe-0" "XDG_RUNTIME_DIR=/run/user/1000" ];
  systemd.user.services.xdg-desktop-portal-gtk.serviceConfig.Environment =
    [ "WAYLAND_DISPLAY=waypipe-0" "XDG_RUNTIME_DIR=/run/user/1000" ];

  # Force Electron apps (Signal, VS Code, etc.) to use native Wayland.
  # Without this, Electron defaults to Xwayland which bypasses waypipe's
  # title-prefix injection, so Sway's for_window rules never match and
  # windows land on the wrong workspace (or don't appear at all).
  environment.sessionVariables = {
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
  };

  # xpra auto-start suppression — only needed when i3.enable = true (xpra-shared.nix active)
  systemd.services.xpra-vsock.wantedBy = lib.mkIf config.hydrix.i3.enable (lib.mkForce []);
  systemd.services.xpra-audio-reconnect.wantedBy = lib.mkIf config.hydrix.i3.enable (lib.mkForce []);

  # ── display-mode (14509) ──────────────────────────────────────────────────
  # Runs as root so it can start/stop system services.
  # Responds to PING so microvm-start can detect VM readiness.
  systemd.services.display-mode = {
    description = "VM display mode selector (vsock:14509)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    startLimitIntervalSec = 0;

    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "2s";
      ExecStart = pkgs.writeShellScript "display-mode-start" ''
        exec ${pkgs.socat}/bin/socat \
          VSOCK-LISTEN:14509,reuseaddr,fork \
          EXEC:${displayModeHandler},nofork
      '';
    };
  };

  # ── waypipe-vsock — on-demand, started by display-mode ───────────────────
  # waypipe server connects to host (CID 2) client on vsock:14507.
  # Host runs: waypipe --vsock --socket 14507 client  (listens, forwards to Hyprland)
  # VM→HOST vsock works because vhost_vsock is loaded on host.
  # Apps inside VM use WAYLAND_DISPLAY=waypipe-0
  systemd.services.waypipe-vsock = {
    description = "waypipe Wayland compositor proxy (vsock:14507)";
    after = [ "network.target" ];
    restartIfChanged = false;
    startLimitIntervalSec = 0;

    serviceConfig = {
      User = username;
      Type = "simple";
      WorkingDirectory = "/home/${username}";
      Restart = "always";
      RestartSec = "5s";

      ExecStartPre = [
        "+${pkgs.coreutils}/bin/install -d -m 0700 -o ${username} /run/user/1000"
        "+${pkgs.coreutils}/bin/rm -f /run/user/1000/waypipe-0"
      ];
      ExecStart = pkgs.writeShellScript "waypipe-vsock-start" ''
        export XDG_RUNTIME_DIR="/run/user/1000"
        # Connect to host waypipe client listening on vsock:14507.
        # Per waypipe docs: from guest, use just port (not CID:port)
        # "sleep infinity" keeps waypipe alive; apps connect via WAYLAND_DISPLAY=waypipe-0
        exec ${pkgs.waypipe}/bin/waypipe \
          --vsock --socket ${waypipePort} \
          --display waypipe-0 \
          ${titlePrefixArg} \
          server -- sleep infinity
      '';
    };
  };

  # ── pulse-vsock — on-demand, started by display-mode in waypipe mode ───────
  # Bridges host PipeWire audio to VMs via vsock:14505.
  # waypipe carries Wayland display only; this is the parallel audio channel.
  # Started alongside waypipe-vsock, stopped when switching to xpra (which
  # handles audio internally via xpra's own PulseAudio forwarding).
  #
  # Uses /run/user/1000/pulse/host-native (not the standard pulse/native) to
  # avoid conflict with the VM's own pipewire-pulse which owns that path.
  # Apps launched via waypipe-launch get PULSE_SERVER pointing here.
  #
  # Flow: VM app → /run/user/1000/pulse/host-native → vsock:2:14505 → host PipeWire
  #
  # Disabled when hydrix.microvm.audio.enable = false (e.g. pentest, lurking).
  # mkMerge: always suppress auto-start (covers xpra's pulse-vsock too); only
  # define the actual service when audio is enabled.
  systemd.services.pulse-vsock = lib.mkMerge [
    { wantedBy = lib.mkForce []; }
    (lib.mkIf audioEnabled {
    description = "PulseAudio vsock bridge to host (port 14505)";
    after = [ "network.target" ];
    startLimitIntervalSec = 0;

    serviceConfig = {
      User = username;
      Type = "simple";
      Restart = "always";
      RestartSec = "3s";

      ExecStartPre = [
        "+${pkgs.coreutils}/bin/install -d -m 0700 -o ${username} /run/user/1000/pulse"
        "+${pkgs.coreutils}/bin/rm -f /run/user/1000/pulse/host-native"
      ];
      ExecStart = pkgs.writeShellScript "pulse-vsock-start" ''
        export XDG_RUNTIME_DIR="/run/user/1000"
        # Wait for pipewire-pulse to create its native socket — this signals that
        # the user session (and XDG_RUNTIME_DIR) is fully initialised. Starting
        # before this point means systemd --user may wipe our socket on setup.
        until [[ -S /run/user/1000/pulse/native ]]; do sleep 1; done
        rm -f /run/user/1000/pulse/host-native
        exec ${pkgs.socat}/bin/socat \
          UNIX-LISTEN:/run/user/1000/pulse/host-native,fork,mode=0600,unlink-early \
          VSOCK-CONNECT:2:14505
      '';
      ExecStopPost = "+${pkgs.coreutils}/bin/rm -f /run/user/1000/pulse/host-native";
    };
  })
  ];

  # ── waypipe-launch (14508) — on-demand, started by display-mode ──────────
  # Receives app launch commands from host, runs them with waypipe display.
  systemd.services.waypipe-launch = {
    description = "waypipe app launch receiver (vsock:14508)";
    after = [ "waypipe-vsock.service" ];
    wants = [ "waypipe-vsock.service" ];
    startLimitIntervalSec = 0;

    serviceConfig = {
      User = username;
      Type = "simple";
      WorkingDirectory = "/home/${username}";
      Restart = "always";
      RestartSec = "2s";

      ExecStartPre = "+${pkgs.coreutils}/bin/install -d -m 0700 -o ${username} /run/user/1000";
      ExecStart = pkgs.writeShellScript "waypipe-launch-start" ''
        export XDG_RUNTIME_DIR="/run/user/1000"
        export WAYLAND_DISPLAY=waypipe-0
        exec ${pkgs.socat}/bin/socat \
          VSOCK-LISTEN:14508,reuseaddr,fork \
          EXEC:'${pkgs.writeShellScript "launch-handler" ''
            export XDG_RUNTIME_DIR="/run/user/1000"
            export WAYLAND_DISPLAY=waypipe-0
            read -r -a ARGS
            if [[ ''${#ARGS[@]} -eq 0 ]]; then
              echo "waypipe-launch: empty command" >&2
              exit 1
            fi
            # Wait for waypipe socket to be ready (service active ≠ socket exists yet)
            for _i in 1 2 3 4 5; do
              [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] && break
              sleep 1
            done
            if [[ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
              echo "waypipe-launch: socket $WAYLAND_DISPLAY not ready" >&2
              exit 1
            fi
            # Detach from socat connection so closing it doesn't kill the app
            export HOME="/home/${username}"
            export USER="${username}"
            export PATH="/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
            export ELECTRON_OZONE_PLATFORM_HINT=auto
            ${lib.optionalString audioEnabled ''export PULSE_SERVER="unix:/run/user/1000/pulse/host-native"''}
            ${pkgs.util-linux}/bin/setsid "''${ARGS[@]}" </dev/null >>/tmp/waypipe-launch.log 2>&1 &
            echo "launched: ''${ARGS[*]}"
          ''}',nofork
      '';
    };
  };
}
