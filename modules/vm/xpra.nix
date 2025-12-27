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
in
{
  # Open firewall port for Xpra
  networking.firewall.allowedTCPPorts = [ xpraPort ];

  # Xpra server systemd service
  # Starts after X is ready and listens for connections from host
  systemd.user.services.xpra-server = {
    description = "Xpra server for seamless window forwarding";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = ''
        ${pkgs.xpra}/bin/xpra start :100 \
          --bind-tcp=0.0.0.0:${toString xpraPort} \
          --no-daemon \
          --no-notifications \
          --no-mdns \
          --no-pulseaudio \
          --start-child='' \
          --exit-with-children=no \
          --html=off
      '';
      ExecStop = "${pkgs.xpra}/bin/xpra stop :100";
      Restart = "on-failure";
      RestartSec = "5s";
    };

    environment = {
      DISPLAY = ":0";
    };
  };

  # Helper scripts for Xpra
  environment.systemPackages = with pkgs; [
    # Script to run an app through Xpra (exported to host)
    (writeShellScriptBin "xpra-run" ''
      #!/usr/bin/env bash
      # Run an application through Xpra so it can be viewed on host
      # Usage: xpra-run firefox
      DISPLAY=:100 "$@" &
      echo "Started $1 on Xpra display :100"
      echo "Connect from host with: xpra attach tcp://<vm-ip>:${toString xpraPort}"
    '')

    # Script to show Xpra connection info
    (writeShellScriptBin "xpra-info" ''
      #!/usr/bin/env bash
      echo "=== Xpra Server Info ==="
      echo "VM Type: ${vmType}"
      echo "Xpra Port: ${toString xpraPort}"
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
    '')
  ];
}
