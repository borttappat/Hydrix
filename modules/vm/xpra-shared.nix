# Unified Xpra Module - Seamless app forwarding for ALL VMs (libvirt + microVM)
#
# This module provides xpra server configuration that works identically for both
# libvirt VMs and microVMs via virtio-vsock.
#
# The host connects with: vm-app <vm-name> <command>
#
# Key design decisions:
#   - System service (not user service) for faster startup
#   - Runs as the configured user to access their home directory
#   - Uses vsock port 14500 for host connections
#   - PNG encoding for lossless compressed output (lower memory than raw RGB)
#
{ config, pkgs, lib, ... }:

let
  username = config.hydrix.username;

  # Check if this is a microVM (has microvm config) or libvirt VM
  isMicrovm = config.microvm or null != null;
in {
  # Vsock transport kernel module
  boot.kernelModules = [ "vmw_vsock_virtio_transport" ];

  environment.systemPackages = with pkgs; [ xpra ];

  # Xpra server as SYSTEM service (starts faster than user service)
  # Runs as the configured user to access their home directory
  systemd.services.xpra-vsock = {
    description = "Xpra seamless app server (vsock)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ]
      ++ lib.optionals isMicrovm [ "home.mount" ];
    wants = lib.optionals isMicrovm [ "home.mount" ];

    # System profile PATH so xpra child commands (sh, firefox, etc.) are found
    path = [ "/run/current-system/sw" ];

    environment = {
      HOME = "/home/${username}";
      USER = username;
      DISPLAY = ":100";  # Virtual display for xpra
      GDK_DPI_SCALE = "1.0";
      QT_SCALE_FACTOR = "1.0";
      WINIT_X11_SCALE_FACTOR = "1";
    };

    # CRITICAL: Don't restart during switch-to-configuration
    # Otherwise audio dies and client needs to reattach
    restartIfChanged = false;

    serviceConfig = {
      User = username;
      Group = "users";
      Type = "simple";
      WorkingDirectory = "/home/${username}";
      ExecStart = lib.concatStringsSep " " ([
        "${pkgs.xpra}/bin/xpra start :100"
        "--bind-vsock=auto:14500"
        "--no-daemon"
        "--start-new-commands=yes"
        "--vsock-auth=none"
        "--sharing=yes"
        # Quality settings - lossless but compressed to reduce memory/CPU
        "--encoding=png"
        "--quality=100"
        "--min-quality=90"
        "--speed=50"
        "--min-speed=30"
        # Audio forwarding
        "--pulseaudio=yes"
        "--speaker=yes"
        "--mdns=no"
        "--notifications=no"
        "--modal-windows=yes"
        "--input-method=none"
        "--systemd-run=no"
        "--video=auto"  # Allow video codecs for dynamic content (scrolling, etc.)
        "--sync-xvfb=auto"
      ]);
      Restart = "always";
      RestartSec = 2;
    };
  };

  # Reconnect xpra audio after a live rebuild.
  #
  # Problem: xpra-vsock has restartIfChanged=false to stay alive across rebuilds,
  # but PipeWire's user services DO restart when their config/package changes.
  # This kills xpra's PulseAudio socket connection, breaking audio.
  #
  # Solution: This companion service has restartIfChanged=true (the default),
  # so it re-runs after every rebuild and tells xpra to re-open its speaker
  # against the fresh PipeWire/PulseAudio socket.
  systemd.services.xpra-audio-reconnect = {
    description = "Reconnect xpra speaker after PipeWire restart";
    after = [ "xpra-vsock.service" ];
    requires = [ "xpra-vsock.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HOME = "/home/${username}";
      USER = username;
      DISPLAY = ":100";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = username;
      Group = "users";
      # Wait for PipeWire/PulseAudio socket to be ready, then cycle the speaker
      ExecStart = pkgs.writeShellScript "xpra-audio-reconnect" ''
        # Give PipeWire-pulse time to create its socket after restart
        sleep 3
        ${pkgs.xpra}/bin/xpra control :100 stop-speaker 2>/dev/null || true
        sleep 1
        ${pkgs.xpra}/bin/xpra control :100 start-speaker
      '';
    };
  };
}
