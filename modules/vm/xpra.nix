# Xpra server configuration for VMs
# Enables seamless window forwarding to the host
{ config, pkgs, lib, ... }:

let
  # Get VM type for identification
  vmType = config.hydrix.vmType or "unknown";

  # Port based on VM type for easy identification
  xpraPort = {
    "pentest" = 14500;
    "browsing" = 14501;
    "office" = 14502;
    "comms" = 14503;
    "dev" = 14504;
  }.${vmType} or 14500;

  # Title prefix for origin indication
  titlePrefix = {
    "pentest" = "[PTX]";
    "browsing" = "[BRW]";
    "office" = "[OFC]";
    "comms" = "[COM]";
    "dev" = "[DEV]";
  }.${vmType} or "[VM]";

  # Apps to auto-start on Xpra display per VM type
  autoStartApps = {
    "browsing" = [ "firefox" "alacritty" ];
    "pentest" = [ "alacritty" ];
    "office" = [ "alacritty" ];
    "comms" = [ "alacritty" ];
    "dev" = [ "alacritty" ];
  }.${vmType} or [ "alacritty" ];

  # Xpra start script (daemon mode for service)
  xpraStartScript = pkgs.writeShellScript "xpra-start-daemon" ''
    # Check if xpra is already running on :100
    if ${pkgs.xpra}/bin/xpra list 2>/dev/null | grep -q ":100"; then
      echo "Xpra already running on :100"
      exit 0
    fi

    # Start xpra server in daemon mode
    ${pkgs.xpra}/bin/xpra start :100 \
      --bind-tcp=0.0.0.0:${toString xpraPort} \
      --daemon=yes \
      --no-mdns \
      --no-printing \
      --no-webcam \
      --exit-with-children=no \
      --html=off \
      --compress=0 \
      --speed=100 \
      --quality=100 \
      --min-quality=80 \
      --opengl=yes

    echo "Xpra server started on :100, port ${toString xpraPort}"
  '';

  # Xpra start script for manual use (foreground)
  xpraStartForeground = pkgs.writeShellScript "xpra-start-fg" ''
    # Check if xpra is already running on :100
    if ${pkgs.xpra}/bin/xpra list 2>/dev/null | grep -q ":100"; then
      echo "Xpra already running on :100"
      exit 0
    fi

    # Start xpra server in foreground
    ${pkgs.xpra}/bin/xpra start :100 \
      --bind-tcp=0.0.0.0:${toString xpraPort} \
      --no-daemon \
      --no-mdns \
      --no-printing \
      --no-webcam \
      --exit-with-children=no \
      --html=off \
      --compress=0 \
      --speed=100 \
      --quality=100 \
      --min-quality=80 \
      --opengl=yes
  '';

  # Xpra stop script
  xpraStopScript = pkgs.writeShellScript "xpra-stop" ''
    ${pkgs.xpra}/bin/xpra stop :100 2>/dev/null || true
  '';

  # Script to launch auto-start apps
  launchAppsScript = pkgs.writeShellScript "xpra-launch-apps" ''
    # Wait for Xpra to be fully ready
    for i in $(seq 1 30); do
      if ${pkgs.xpra}/bin/xpra list 2>/dev/null | grep -q ":100"; then
        break
      fi
      sleep 1
    done

    # Launch configured apps
    ${lib.concatMapStringsSep "\n" (app: ''
      echo "Launching ${app} on Xpra display..."
      DISPLAY=:100 ${app} &
      sleep 2
    '') autoStartApps}

    echo "Auto-start apps launched"
  '';
in
{
  # Open firewall port for Xpra
  networking.firewall.allowedTCPPorts = [ xpraPort ];

  # dconf for GTK apps (fixes dconf warnings)
  programs.dconf.enable = true;

  # Xpra dependencies for better performance
  environment.systemPackages = with pkgs; [
    xpra
    # Python deps that xpra complains about
    python3Packages.numpy
    python3Packages.pillow
    python3Packages.pygobject3
    # GTK/dbus deps for cleaner operation
    dconf
    glib
    libnotify

    # Script to start xpra server manually (foreground)
    (writeShellScriptBin "xpra-start" ''
      ${xpraStartForeground}
    '')

    # Script to stop xpra server
    (writeShellScriptBin "xpra-stop" ''
      ${xpraStopScript}
    '')

    # Script to run an app through Xpra (exported to host)
    (writeShellScriptBin "xpra-run" ''
      # Run an application through Xpra so it can be viewed on host
      # Usage: xpra-run firefox

      # Ensure xpra is running
      if ! ${pkgs.xpra}/bin/xpra list 2>/dev/null | grep -q ":100"; then
        echo "Starting Xpra server..."
        ${xpraStartScript} &
        sleep 2
      fi

      DISPLAY=:100 "$@" &
      echo "Started $1 on Xpra display :100"
      echo "Connect from host with: xpra attach tcp://<vm-ip>:${toString xpraPort}"
    '')

    # Script to show Xpra connection info
    (writeShellScriptBin "xpra-info" ''
      echo "=== Xpra Server Info ==="
      echo "VM Type: ${vmType}"
      echo "Title Prefix: ${titlePrefix}"
      echo "Xpra Port: ${toString xpraPort}"
      echo ""
      echo "Server Status:"
      ${pkgs.xpra}/bin/xpra list 2>/dev/null || echo "  Not running"
      echo ""
      echo "VM IP addresses:"
      ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'
      echo ""
      echo "To connect from host:"
      IP=$(ip -4 addr show | grep -oP '(?<=inet\s)192\.168\.\d+\.\d+' | head -1)
      echo "  xpra attach tcp://$IP:${toString xpraPort}"
      echo ""
      echo "To run apps through Xpra:"
      echo "  xpra-run firefox"
      echo "  xpra-run alacritty"
      echo "  xpra-run obsidian"
    '')

    # Script to restart xpra with fresh settings
    (writeShellScriptBin "xpra-restart" ''
      echo "Stopping Xpra..."
      ${xpraStopScript}
      sleep 1
      echo "Starting Xpra..."
      ${xpraStartScript} &
      sleep 2
      echo "Xpra restarted"
      ${pkgs.xpra}/bin/xpra list
    '')

    # Help/reference command
    (writeShellScriptBin "xpra-help" ''
      cat << 'EOF'
================================================================================
                        XPRA VM COMMANDS (${vmType} VM)
================================================================================

STARTING XPRA SERVER:
  xpra-start          Start the Xpra server on display :100
  xpra-stop           Stop the Xpra server
  xpra-restart        Restart the Xpra server
  xpra-info           Show server status and connection info

RUNNING APPS (exported to host):
  xpra-run <app>      Run an app through Xpra (visible on host)
                      Examples:
                        xpra-run firefox
                        xpra-run alacritty
                        xpra-run obsidian

CONNECTION INFO:
  VM Type:            ${vmType}
  Xpra Port:          ${toString xpraPort}
  Title Prefix:       ${titlePrefix}

NOTES:
  - Xpra auto-starts when X session begins (via .xinitrc)
  - Apps run with xpra-run appear on the host when attached
  - Use xpra-info to get the connection command for the host

================================================================================
EOF
    '')
  ];

  # Create marker file with xpra info for host scripts to read
  environment.etc."hydrix-xpra".text = ''
    VM_TYPE=${vmType}
    XPRA_PORT=${toString xpraPort}
    TITLE_PREFIX=${titlePrefix}
  '';

  # Systemd user service to auto-start Xpra server
  systemd.user.services.xpra-server = {
    description = "Xpra seamless window server";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "forking";
      ExecStart = "${xpraStartScript}";
      ExecStop = "${xpraStopScript}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Systemd user service to auto-launch apps on Xpra
  systemd.user.services.xpra-apps = {
    description = "Auto-launch apps on Xpra display";
    wantedBy = [ "graphical-session.target" ];
    after = [ "xpra-server.service" ];
    requires = [ "xpra-server.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${launchAppsScript}";
      RemainAfterExit = true;
    };
  };
}
