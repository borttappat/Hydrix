# waypipe VM-side module
#
# Services (none auto-start — host pushes display mode at VM start via vsock:14509):
#
#   display-mode  (14509) — receives "waypipe"/"PING"/"STATUS" from host
#   waypipe-vsock          — waypipe client connecting to host (vsock:14507)
#   waypipe-launch(14508)  — receives app launch commands from host
#
# Flow:
#   shard start <vm>  → host pushes "waypipe" → vsock:14509
#   VM display-mode     → starts waypipe-vsock+waypipe-launch
#
#   waypipe client (VM): connects to host server on vsock:14507
#   waypipe server (HOST): listens on vsock:14507, forwards to Hyprland
#   Apps inside VM use WAYLAND_DISPLAY=waypipe-0
#
{
  config,
  pkgs,
  lib,
  ...
}: let
  username = config.hydrix.username;
  audioEnabled = config.hydrix.microvm.audio.enable or false;
  notifyForwardEnabled = config.hydrix.microvm.notifyForward.enable or false;
  notifyForwardPort = 14518;
  # Derive title prefix from vmType (e.g. "browsing"), not storeName/hostname:
  # vmType is set directly by each profile's own default.nix, independent of the
  # per-machine-suffixed flake-attribute name (storeName) or any custom hostname
  # a task slot might set for engagement stealth naming, so it always matches the
  # registry key Hyprland's windowrules are generated from (see hydrix.networking
  # .vmRegistry / theming/wm/hyprland/hyprland.nix).
  titlePrefix = config.hydrix.vmType;
  titlePrefixArg = "--title-prefix \"[${titlePrefix}] \"";
  # Per-VM waypipe port derived from vsock CID: CID 106 → port 14606
  # Avoids collision when multiple VMs are connected simultaneously.
  # Falls back to 0 (port 14500) in non-microVM contexts (waypipe unused there).
  waypipePort = toString (14600 + (config.hydrix.microvm.vsockCid or 0) - 100);

  notifyPython = pkgs.python3.withPackages (ps: [ps.dbus-python ps.pygobject3]);
  notifyRelayScript = pkgs.writeTextFile {
    name = "notify-relay.py";
    text = ''
      import json
      import socket
      import dbus
      import dbus.service
      import dbus.mainloop.glib
      from gi.repository import GLib

      VM_NAME = "${titlePrefix}"
      HOST_CID = 2
      HOST_PORT = ${toString notifyForwardPort}
      URGENCY_NAMES = {0: "low", 1: "normal", 2: "critical"}


      class NotificationRelay(dbus.service.Object):
          def __init__(self, bus):
              super().__init__(bus, "/org/freedesktop/Notifications")
              self._next_id = 1

          @dbus.service.method(
              "org.freedesktop.Notifications",
              in_signature="susssasa{sv}i",
              out_signature="u",
          )
          def Notify(self, app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout):
              nid = replaces_id or self._next_id
              self._next_id += 1

              urgency = URGENCY_NAMES.get(int(hints.get("urgency", 1)), "normal")
              payload = json.dumps(
                  {
                      "vm": VM_NAME,
                      "app_name": str(app_name),
                      "summary": str(summary),
                      "body": str(body),
                      "urgency": urgency,
                  }
              )
              try:
                  with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as s:
                      s.settimeout(3)
                      s.connect((HOST_CID, HOST_PORT))
                      s.sendall((payload + "\n").encode())
              except OSError:
                  pass  # host relay unreachable — nothing else to fall back to

              return nid

          @dbus.service.method("org.freedesktop.Notifications", out_signature="as")
          def GetCapabilities(self):
              return ["body"]

          @dbus.service.method("org.freedesktop.Notifications", in_signature="u")
          def CloseNotification(self, nid):
              pass

          @dbus.service.method("org.freedesktop.Notifications", out_signature="ssss")
          def GetServerInformation(self):
              return ("notify-relay", "hydrix", "1.0", "1.2")

          # GDBus-based clients (GLib's GDBusProxy) call Properties.GetAll while
          # constructing a proxy, before ever calling Notify() — without a
          # handler here that fails with UnknownMethod and the proxy never gets
          # created. The Notifications interface has no real properties, so an
          # empty dict is the spec-correct answer.
          @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
          def Get(self, interface_name, property_name):
              raise dbus.exceptions.DBusException(
                  "No such property", name="org.freedesktop.DBus.Error.UnknownProperty"
              )

          @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
          def GetAll(self, interface_name):
              return dbus.Dictionary({}, signature="sv")

          @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ssv")
          def Set(self, interface_name, property_name, new_value):
              pass


      dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
      bus = dbus.SessionBus()
      name = dbus.service.BusName("org.freedesktop.Notifications", bus)
      NotificationRelay(bus)
      GLib.MainLoop().run()
    '';
  };

  displayModeHandler = pkgs.writeShellScript "display-mode-handler" ''
    set -euo pipefail
    read -r cmd
    case "$cmd" in
      PING)
        echo "OK"
        ;;
      waypipe)
        if systemctl is-active --quiet waypipe-vsock 2>/dev/null; then
          # Service running — check if socket actually exists (connection alive)
          if [[ ! -S "/run/user/1000/waypipe-0" ]]; then
            # Socket missing: vsock connection dead. Restart to reconnect to host.
            ${pkgs.util-linux}/bin/flock -n /run/waypipe-reconnect.lock -c \
              'systemctl restart waypipe-vsock waypipe-launch' 2>/dev/null || true
          fi
          # Socket exists and service active: leave running apps undisturbed.
          # waypipe-vsock will self-heal via Restart=always if connection drops.
        else
          ${pkgs.util-linux}/bin/flock -n /run/waypipe-reconnect.lock -c \
            'systemctl start waypipe-vsock waypipe-launch' 2>/dev/null || true
        fi
        ${lib.optionalString audioEnabled "systemctl start pulse-vsock 2>/dev/null || true"}
        echo "waypipe"
        ;;
      waypipe-reconnect)
        # Unconditional restart — used by waypipe-connect on startup/reconnect.
        # Unlike "waypipe", this always restarts regardless of socket state,
        # so a fresh host-side listener always gets a fresh VM connection.
        # flock -n: the host can have more than one reconnect trigger in
        # flight for the same VM (its own start-up reconnect plus a
        # long-running waypipe-connect-all poller both reacting to the same
        # boot). Without this, overlapping restarts stack and can pull the
        # socket out from under an app that just launched. A second
        # concurrent reconnect while one is already running is redundant, so
        # it's dropped rather than queued.
        ${pkgs.util-linux}/bin/flock -n /run/waypipe-reconnect.lock -c \
          'systemctl restart waypipe-vsock waypipe-launch' 2>/dev/null || true
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
        systemctl stop waypipe-vsock waypipe-launch ${lib.optionalString audioEnabled "pulse-vsock"} 2>/dev/null || true
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
  boot.kernelModules = ["vmw_vsock_virtio_transport"];

  environment.systemPackages = [
    pkgs.waypipe
    pkgs.socat
    pkgs.wl-clipboard
    pkgs.wayland-utils
    (pkgs.writeShellScriptBin "clip-test" ''
      export WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-waypipe-0}"
      echo "=== VM Clipboard Event Monitor ==="
      echo "Wayland display: $WAYLAND_DISPLAY"
      echo ""
      echo "--- Clipboard-related globals this session actually advertises ---"
      ${pkgs.wayland-utils}/bin/wayland-info 2>&1 \
        | ${pkgs.gnugrep}/bin/grep -iE "data.control|data_device|primary.selection|primary_selection" \
        || echo "(none found -- wayland-info unavailable or waypipe isn't forwarding these globals)"
      echo ""
      echo "Note: only data-control-protocol changes (below) are passively"
      echo "observable by a bystander process like this one. Regular Ctrl+C/"
      echo "Ctrl+V (wl_data_device) is only ever pushed to whichever client"
      echo "currently has keyboard focus -- a Wayland protocol limitation, not"
      echo "something a watcher can see around. Use clip-monitor-host on the"
      echo "HOST for full visibility into every clipboard interaction,"
      echo "including the interactive protocol and every allow/block decision."
      echo ""
      echo "--- Watching data-control selection + primary selection ---"
      echo "Press Ctrl+C to stop."
      echo ""
      watch_selection() {
        ${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.bash}/bin/bash -c '
          TS=$(date +%H:%M:%S.%3N)
          TYPES=$(${pkgs.wl-clipboard}/bin/wl-paste --list-types 2>/dev/null | tr "\n" ", ")
          CONTENT=$(${pkgs.wl-clipboard}/bin/wl-paste --no-newline 2>/dev/null | head -c 200)
          LEN=''${#CONTENT}
          echo "[$TS] SELECTION: ''${LEN}B types=[$TYPES] content=\"''${CONTENT:0:80}\"..."
        '
        echo "[selection watcher exited -- data-control (regular clipboard) unavailable in this session]"
      }
      watch_primary() {
        ${pkgs.wl-clipboard}/bin/wl-paste --primary --watch ${pkgs.bash}/bin/bash -c '
          TS=$(date +%H:%M:%S.%3N)
          CONTENT=$(${pkgs.wl-clipboard}/bin/wl-paste --primary --no-newline 2>/dev/null | head -c 200)
          LEN=''${#CONTENT}
          echo "[$TS] PRIMARY: ''${LEN}B content=\"''${CONTENT:0:80}\"..."
        '
        echo "[primary watcher exited -- primary-selection data-control unavailable in this session]"
      }
      watch_selection &
      SEL_PID=$!
      watch_primary &
      PRI_PID=$!
      trap "kill $SEL_PID $PRI_PID 2>/dev/null; echo 'Stopped.'; exit 0" INT TERM
      wait
    '')
  ];

  # XDG desktop portal — resolves file picker D-Bus calls immediately.
  # Without this, apps timeout (5-25s) waiting for a portal before falling back.
  # gtk backend handles FileChooser without needing a Wayland compositor.
  xdg.portal = {
    enable = true;
    extraPortals = [pkgs.xdg-desktop-portal-gtk];
    config.common.default = ["gtk"];
  };

  # D-Bus-activated services don't inherit the user session environment,
  # so WAYLAND_DISPLAY is unset when xdg-desktop-portal-gtk starts.
  # GTK fails to initialize without a display → portal crashes → Firefox
  # waits out the full D-Bus timeout (~10s) before degrading.
  # Inject the known-fixed display name so the portal starts cleanly.
  systemd.user.services.xdg-desktop-portal.serviceConfig.Environment = ["WAYLAND_DISPLAY=waypipe-0" "XDG_RUNTIME_DIR=/run/user/1000"];
  systemd.user.services.xdg-desktop-portal-gtk.serviceConfig.Environment = ["WAYLAND_DISPLAY=waypipe-0" "XDG_RUNTIME_DIR=/run/user/1000"];

  # Force Electron apps (Signal, VS Code, etc.) to use native Wayland.
  # Without this, Electron defaults to Xwayland which bypasses waypipe's
  # title-prefix injection, so Hyprland's windowrule never matches and
  # windows land on the wrong workspace (or don't appear at all).
  environment.sessionVariables = {
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
  };

  # ── display-mode (14509) ──────────────────────────────────────────────────
  # Runs as root so it can start/stop system services.
  # Responds to PING so microvm-start can detect VM readiness.
  systemd.services.display-mode = {
    description = "VM display mode selector (vsock:14509)";
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
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
    after = ["network.target"];
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
          --compress none \
          --threads 4 \
          --video h264,sw \
          --display waypipe-0 \
          ${titlePrefixArg} \
          server -- sleep infinity
      '';
    };
  };

  # ── pulse-vsock — on-demand, started by display-mode in waypipe mode ───────
  # Bridges host PipeWire audio to VMs via vsock:14505.
  # waypipe carries Wayland display only; this is the parallel audio channel.
  # Started alongside waypipe-vsock.
  #
  # Uses /run/user/1000/pulse/host-native (not the standard pulse/native) to
  # avoid conflict with the VM's own pipewire-pulse which owns that path.
  # Apps launched via waypipe-launch get PULSE_SERVER pointing here.
  #
  # Flow: VM app → /run/user/1000/pulse/host-native → vsock:2:14505 → host PipeWire
  #
  # Disabled when hydrix.microvm.audio.enable = false (e.g. pentest, lurking).
  # mkMerge: always suppress auto-start by default; only
  # define the actual service when audio is enabled.
  systemd.services.pulse-vsock = lib.mkMerge [
    {wantedBy = lib.mkForce [];}
    (lib.mkIf audioEnabled {
      description = "PulseAudio vsock bridge to host (port 14505)";
      after = ["network.target"];
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

  # ── notify-relay — claims org.freedesktop.Notifications, forwards to host ──
  # The VM has no notification daemon otherwise (notify-send fails with
  # NameHasNoOwner). Forwards each Notify() call to the host over vsock
  # instead of rendering anything locally. Host side listens unconditionally
  # (see theming/wm/hyprland/waypipe.nix) — this option only controls whether
  # the VM sends.
  systemd.user.services.notify-relay = lib.mkIf notifyForwardEnabled {
    description = "Notification relay to host (vsock:${toString notifyForwardPort})";
    wantedBy = ["default.target"];
    serviceConfig = {
      ExecStart = "${notifyPython}/bin/python3 ${notifyRelayScript}";
      Restart = "always";
      RestartSec = "3s";
    };
  };

  # ── waypipe-launch (14508) — on-demand, started by display-mode ──────────
  # Receives app launch commands from host, runs them with waypipe display.
  systemd.services.waypipe-launch = {
    description = "waypipe app launch receiver (vsock:14508)";
    after = ["waypipe-vsock.service"];
    wants = ["waypipe-vsock.service"];
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
