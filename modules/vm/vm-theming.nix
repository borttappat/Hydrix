# VM Theming Module - Colorscheme integration for microVMs
#
# This module provides colorscheme sync scripts for VMs that use xpra forwarding.
# It's separate from the full graphical module since microVMs don't need i3/polybar.
#
# Provides:
# - wal-sync: Sync colors from host (via 9p mount)
# - set-colorscheme-mode: Set inheritance mode (full/dynamic/none)
# - get-colorscheme-mode: Show current mode
# - refresh-colors: Apply current colors to running apps
#
# The host pushes colors via vsock (vm-colorscheme service in microvm-base.nix),
# but these scripts provide manual control and fallback mechanisms.
#
{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";
  colorschemeInheritance = config.hydrix.colorschemeInheritance or "dynamic";
  jq = "${pkgs.jq}/bin/jq";

  # Refresh colors in running apps (simplified for xpra VMs)
  refreshColorsScript = pkgs.writeShellScriptBin "refresh-colors" ''
    #!/usr/bin/env bash
    # Refresh color-aware applications from wal cache
    WAL_COLORS="$HOME/.cache/wal/colors.json"

    if [ ! -f "$WAL_COLORS" ]; then
      echo "No wal colors found at $WAL_COLORS"
      exit 1
    fi

    echo "Refreshing colors..."

    # Terminal sequences (updates open terminals)
    if [ -f "$HOME/.cache/wal/sequences" ]; then
      cat "$HOME/.cache/wal/sequences"
    fi

    # Firefox via pywalfox
    if command -v pywalfox >/dev/null 2>&1; then
      pywalfox update 2>/dev/null || true
    fi

    # Dunst notifications
    if command -v generate-dunstrc >/dev/null 2>&1; then
      generate-dunstrc 2>/dev/null || true
      ${pkgs.procps}/bin/pkill dunst 2>/dev/null || true
    fi

    # Xpra root window background
    BG=$(${jq} -r '.special.background // .colors.color0' "$WAL_COLORS" 2>/dev/null)
    if [ -n "$BG" ] && command -v xsetroot >/dev/null 2>&1; then
      xsetroot -solid "$BG" 2>/dev/null || true
    fi

    echo "Done"
  '';

  # Set colorscheme inheritance mode
  setColorschemeModeScript = pkgs.writeShellScriptBin "set-colorscheme-mode" ''
    #!/usr/bin/env bash
    MODE="$1"
    MODE_FILE="$HOME/.cache/wal/.colorscheme-mode"

    if [ -z "$MODE" ]; then
      echo "Usage: set-colorscheme-mode <mode>"
      echo "Modes:"
      echo "  full    - Use all host colors"
      echo "  dynamic - Host background + VM text colors (default)"
      echo "  none    - Ignore host colors"
      exit 1
    fi

    case "$MODE" in
      full|dynamic|none)
        mkdir -p "$(dirname "$MODE_FILE")"
        echo "$MODE" > "$MODE_FILE"
        echo "Colorscheme mode set to: $MODE"
        # Clear sync hash to force re-sync
        rm -f "$HOME/.cache/wal/.wal-sync-hash"
        # Trigger sync if available
        if command -v wal-sync >/dev/null 2>&1; then
          wal-sync
        fi
        ;;
      *)
        echo "Invalid mode: $MODE"
        echo "Valid modes: full, dynamic, none"
        exit 1
        ;;
    esac
  '';

  # Get current colorscheme mode
  getColorschemeModeScript = pkgs.writeShellScriptBin "get-colorscheme-mode" ''
    #!/usr/bin/env bash
    MODE_FILE="$HOME/.cache/wal/.colorscheme-mode"
    DEFAULT_MODE="${colorschemeInheritance}"

    if [ -f "$MODE_FILE" ]; then
      cat "$MODE_FILE"
    else
      echo "$DEFAULT_MODE"
    fi
  '';

  # Sync colors from host (via 9p mount)
  walSyncScript = pkgs.writeShellScriptBin "wal-sync" ''
    #!/usr/bin/env bash
    # Sync colorscheme from host's pywal cache

    HOST_WAL="/mnt/hydrix-config/wal"
    WAL_CACHE="$HOME/.cache/wal"
    HOST_COLORS="$HOST_WAL/colors.json"
    WAL_COLORS="$WAL_CACHE/colors.json"
    VM_COLORSCHEME_JSON="/etc/hydrix-colorscheme.json"
    LAST_SYNC_HASH="$WAL_CACHE/.wal-sync-hash"
    MODE_FILE="$WAL_CACHE/.colorscheme-mode"
    DEFAULT_MODE="${colorschemeInheritance}"

    # Get current mode
    MODE="$DEFAULT_MODE"
    if [ -f "$MODE_FILE" ]; then
      MODE=$(cat "$MODE_FILE")
    fi

    # Mode 'none' - ignore host colors
    if [ "$MODE" = "none" ]; then
      exit 0
    fi

    # Check if host colors available
    if [ ! -f "$HOST_COLORS" ]; then
      exit 0
    fi

    # Check if colors changed (hash-based)
    CURRENT_HASH=$(${pkgs.coreutils}/bin/sha256sum "$HOST_COLORS" 2>/dev/null | cut -d' ' -f1)
    if [ -f "$LAST_SYNC_HASH" ]; then
      LAST_HASH=$(cat "$LAST_SYNC_HASH")
      if [ "$CURRENT_HASH" = "$LAST_HASH" ]; then
        exit 0  # No change
      fi
    fi

    mkdir -p "$WAL_CACHE"

    if [ "$MODE" = "full" ]; then
      # Full mode: Use all host colors
      cp "$HOST_COLORS" "$WAL_COLORS"
    elif [ "$MODE" = "dynamic" ]; then
      # Dynamic mode: Host background + VM text colors
      if [ -f "$VM_COLORSCHEME_JSON" ]; then
        ${jq} -s '
          .[0] as $host | .[1] as $vm |
          $host | .colors = $vm.colors
        ' "$HOST_COLORS" "$VM_COLORSCHEME_JSON" > "$WAL_COLORS"
      else
        cp "$HOST_COLORS" "$WAL_COLORS"
      fi
    fi

    # Regenerate pywal cache files (sequences, Xresources, etc.) from merged colors
    ${pkgs.pywal}/bin/wal -q --theme "$WAL_COLORS" 2>&1 | grep -v "WARNING" || true

    # For dynamic mode, re-apply VM text colors after pywal regenerates
    # (pywal --theme overwrites colors.json with the theme file)
    if [ "$MODE" = "dynamic" ] && [ -f "$VM_COLORSCHEME_JSON" ]; then
      ${jq} -s '.[0] as $current | .[1] as $vm | $current | .colors = $vm.colors' \
        "$WAL_COLORS" "$VM_COLORSCHEME_JSON" > "$WAL_COLORS.tmp"
      mv "$WAL_COLORS.tmp" "$WAL_COLORS"
    fi

    # Save hash
    echo "$CURRENT_HASH" > "$LAST_SYNC_HASH"

    # Refresh apps
    refresh-colors 2>/dev/null || true
  '';

in {
  config = lib.mkIf isVM {
    environment.systemPackages = [
      refreshColorsScript
      setColorschemeModeScript
      getColorschemeModeScript
      walSyncScript
      pkgs.jq
      pkgs.pywal
      pkgs.xorg.xsetroot
    ];

    # Poll for host color changes (fallback if vsock push doesn't work)
    systemd.user.services.wal-sync = {
      description = "Sync colors from host";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${walSyncScript}/bin/wal-sync";
      };
    };

    systemd.user.timers.wal-sync = {
      description = "Periodic color sync from host";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5s";
        OnUnitActiveSec = "10s";  # Poll every 10s as fallback
        Unit = "wal-sync.service";
      };
    };
  };
}
