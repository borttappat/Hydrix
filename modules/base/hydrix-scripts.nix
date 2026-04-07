# Hydrix Scripts Module
#
# Wraps Hydrix shell scripts and adds them to the system PATH.
# Scripts are available system-wide without needing ./scripts/ prefix.
#
# ============================================================================
# SCRIPT REFERENCE
# ============================================================================
#
# BUILD & SYSTEM MANAGEMENT
# -------------------------
#   rebuild [mode]            Rebuild host system (auto-detects lockdown mode)
#                             Modes: lockdown (base), administrative, admin, fallback
#                             No args = rebuild current mode
#                             In lockdown: auto-uses builder VM (no host network)
#   rebuild-libvirt-router    Rebuild libvirt router (if libvirt router enabled)
#   new-profile [name]        Scaffold new VM profile from ~/hydrix-config/templates/
#                             Auto-discovers next free CID/workspace (CID=subnet=WS)
#                             Copies _template/, substitutes values, git-adds, rebuilds
#
# MICROVM MANAGEMENT
# ------------------
#   microvm <cmd> [name]      MicroVM CLI (see `microvm help`)
#     microvm list            List available microVMs
#     microvm status          Show running microVMs
#     microvm build <name>    Build/rebuild a microVM
#     microvm start <name>    Start a microVM (waits for xpra)
#     microvm stop <name>     Stop a microVM
#     microvm app <name> <cmd>  Launch app in microVM
#     microvm console <name>  Attach to microVM console
#
# LIBVIRT VM MANAGEMENT
# ---------------------
#   hydrix-tui                Unified VM management TUI
#   build-base --type <t>     Build VM base image (browsing, pentest, dev, comms)
#   deploy-vm --type <t>      Deploy VM from base image
#                             Options: --name, --user, --pass, --bridge, etc.
#
# PACKAGE SYNC (vm-dev workflow)
# ------------------------------
#   vm-sync <cmd>             Host-side package sync CLI
#     vm-sync list            List staged packages from VMs
#     vm-sync pull <pkg>      Pull package to profile
#     vm-sync status          Show packages per profile
#   vm-sync-tui               Interactive package sync TUI
#                             Hotkeys: [s]tage, [p]ull, [x]remove, [R]ebuild
#
# COLORSCHEME & THEMING
# ---------------------
#   walrgb <image>            Set wallpaper and generate pywal colors
#   randomwal                 Random wallpaper from ~/Pictures/wallpapers
#   save-colorscheme          Save current pywal scheme to colorschemes/
#   refresh-colors            Reload all color-aware apps from wal cache
#   restore-colorscheme       Revert to nix-configured colorscheme
#
# VPN MANAGEMENT
# --------------
#   vpn-assign <vm> <exit>    Assign Mullvad exit node to VM bridge
#   vpn-status                Show VPN status for all bridges
#
# MODE SWITCHING
# --------------
#   hydrix-switch <mode>      Live switch: lockdown, administrative, fallback
#                             lockdown <-> administrative = live (no reboot)
#                             to/from fallback = stages + requires reboot
#   hydrix-mode               Show current mode and available modes
#   router-status             Show router VM and bridge status
#
# UTILITIES
# ---------
#   hydrix-lock               Lock screen with i3lock-color
#   pyenvshell                Activate Python virtual environment
#   vm-status                 Show system status (bridges, VMs, etc.)
#   nixbuild                  Alias for rebuild (backwards compat)
#
# VM-ONLY COMMANDS (inside microVMs)
# ----------------------------------
#   vm-dev build <url>        Build package from GitHub URL
#   vm-dev run <name>         Run locally built package
#   vm-dev list               List local packages
#   vm-sync push --name <pkg> Stage package for host integration
#   set-colorscheme-mode <m>  Set color inheritance (full/dynamic/none)
#   get-colorscheme-mode      Show current color inheritance mode
#   wal-sync                  Sync colors from host
#
# ============================================================================

{ config, lib, pkgs, ... }:

let
  username = config.hydrix.username;

  # Package all Hydrix scripts into a derivation
  # This ensures scripts are available even when Hydrix is imported from GitHub
  hydrixScriptsPackage = pkgs.stdenvNoCC.mkDerivation {
    name = "hydrix-scripts";
    src = ../../scripts;
    installPhase = ''
      mkdir -p $out/scripts
      cp -r $src/* $out/scripts/
      chmod +x $out/scripts/*
    '';
  };

  # Helper to create a wrapper script that auto-detects the flake location
  # Supports both architectures:
  #   - ~/hydrix-config (user mode - imports Hydrix from GitHub)
  #   - ~/Hydrix (developer mode - local clone)
  mkHydrixScript = name: script: pkgs.writeShellScriptBin name ''
    # Auto-detect flake location
    if [[ -f "$HOME/hydrix-config/flake.nix" ]]; then
      HYDRIX_FLAKE_DIR="$HOME/hydrix-config"
    elif [[ -f "$HOME/Hydrix/flake.nix" ]]; then
      HYDRIX_FLAKE_DIR="$HOME/Hydrix"
    else
      echo "Error: No Hydrix config found at ~/hydrix-config or ~/Hydrix" >&2
      exit 1
    fi

    export HYDRIX_FLAKE_DIR
    cd "$HYDRIX_FLAKE_DIR"

    # Run script from local flake (for development) or from Nix store (user mode)
    # Priority: user config scripts > local Hydrix dev > Nix store
    if [[ -x "$HYDRIX_FLAKE_DIR/scripts/${script}" ]]; then
      exec "$HYDRIX_FLAKE_DIR/scripts/${script}" "$@"
    elif [[ -x "$HOME/Hydrix/scripts/${script}" ]]; then
      # Developer mode: use local Hydrix scripts for immediate changes
      exec "$HOME/Hydrix/scripts/${script}" "$@"
    else
      exec ${hydrixScriptsPackage}/scripts/${script} "$@"
    fi
  '';

  # Scripts that need to run from Hydrix directory
  hydrixScripts = {
    # ===== BUILD & SYSTEM =====
    rebuild = "rebuild";
    new-profile = "new-profile";
    # Note: rebuild-libvirt-router is provided by modules/host/libvirt-router-host.nix

    # ===== MICROVM MANAGEMENT =====
    # Note: 'microvm' command is added in microvm-host.nix with path substitution
    # For interactive microVM management, use 'microvm' CLI directly:
    #   microvm list/status/build/start/stop/app
    # The hydrix-tui handles libvirt VMs, not microVMs

    # ===== LIBVIRT VM MANAGEMENT =====
    hydrix-tui = "hydrix-tui.sh";
    build-base = "build-base.sh";
    deploy-vm = "deploy-vm.sh";

    # ===== PACKAGE SYNC =====
    vm-sync = "vm-sync.sh";
    vm-sync-tui = "vm-sync-tui.sh";

    # ===== COLORSCHEME & THEMING =====
    walrgb = "walrgb.sh";
    randomwal = "randomwalrgb.sh";
    save-colorscheme = "save-colorscheme.sh";

    # ===== VPN =====
    vpn-assign = "vpn-assign.sh";
    vpn-status = "vpn-status.sh";

    # ===== UTILITIES =====
    hydrix-lock = "lock.sh";
    pyenvshell = "pyenvshell.sh";
    hardware-identify = "hardware-identify.sh";
    float-window = "float_window.sh";
    i3launch = "i3launch.sh";
  };

  scriptPackages = lib.mapAttrsToList mkHydrixScript hydrixScripts;

in {
  config = lib.mkIf (config.hydrix.vmType == "host" || config.hydrix.vmType == null) {
    environment.systemPackages = scriptPackages ++ [
      # Backwards compatibility alias
      (pkgs.writeShellScriptBin "nixbuild" ''
        exec rebuild "$@"
      '')
    ];
  };
}
