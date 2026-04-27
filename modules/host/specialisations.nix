# Specialisations - Boot modes for the host
#
# Architecture:
#   BASE CONFIG = LOCKDOWN (default boot)
#     - Bridges active, VFIO active, router VM running
#     - Host has NO default gateway (no internet access)
#     - Builder VM available for nix builds
#     - VMs access internet through router VM normally
#
#   ADMINISTRATIVE specialisation
#     - Adds default gateway through router VM
#     - Host has internet access via router
#     - Full package set, libvirtd, network tools
#
#   FALLBACK specialisation (requires REBOOT)
#     - Releases WiFi from VFIO, re-enables NetworkManager
#     - Removes bridges, disables router VM
#     - Emergency direct WiFi on host
#
# Live switching:
#   lockdown <-> administrative: supported (rebuild / rebuild administrative)
#   anything -> fallback: requires reboot (kernel parameter changes)
#   fallback -> anything: requires reboot
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  netCfg = cfg.networking;
in {
  config = lib.mkIf (cfg.vmType == "host" && cfg.router.type != "none") {

    # =========================================================================
    # BASE = LOCKDOWN (default boot mode)
    # =========================================================================

    system.nixos.label = lib.mkOverride 90 "lockdown";

    environment.etc."HYDRIX_MODE".text = lib.mkDefault ''
      MODE=lockdown
      DESCRIPTION="Hardened default - no host internet"
      INTERNET=disabled
      VMS=enabled
    '';

    # Builder VM for nix builds without host internet
    hydrix.builder.enable = lib.mkDefault true;

    # =========================================================================
    # ADMINISTRATIVE SPECIALISATION - Full functionality
    # =========================================================================

    specialisation.administrative.configuration = {
      system.nixos.label = lib.mkForce "administrative";

      environment.etc."HYDRIX_MODE".text = lib.mkForce ''
        MODE=administrative
        DESCRIPTION="Full functionality - router VM active"
        INTERNET=via-router-vm
        VMS=enabled
      '';

      # Host routes through router VM
      networking.defaultGateway = {
        address = netCfg.routerIp;
        interface = "br-mgmt";
      };

      # DNS through router
      networking.nameservers = [ netCfg.routerIp ];

      # Note: libvirtd is enabled in base config (modules/host/router.nix)
      # for libvirt pentest VMs in all modes

      # More permissive firewall for administrative work
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [
          5900 5901 5902 5903 5904  # VNC/Spice
          22                         # SSH
        ];
        trustedInterfaces = netCfg.bridges;
      };

      # Packages configured in user's hydrix-config/specialisations/administrative.nix
    };

    # =========================================================================
    # FALLBACK SPECIALISATION - Emergency direct WiFi (requires reboot)
    # =========================================================================

    specialisation.fallback.configuration = {
      system.nixos.label = lib.mkForce "fallback";

      environment.etc."HYDRIX_MODE".text = lib.mkForce ''
        MODE=fallback
        DESCRIPTION="Emergency mode - direct WiFi, no VMs"
        INTERNET=direct
        VMS=disabled
        WARNING="VM isolation bypassed"
      '';

      # Remove VFIO - release WiFi card
      boot.kernelParams = lib.mkOverride 10 [ "quiet" "loglevel=3" ];
      boot.kernelModules = lib.mkOverride 10 [];
      boot.blacklistedKernelModules = lib.mkOverride 10 [];

      # Re-enable NetworkManager for direct WiFi
      networking.networkmanager.enable = lib.mkOverride 10 true;
      networking.useDHCP = lib.mkOverride 10 true;

      # Remove bridges and routing
      networking.bridges = lib.mkOverride 10 {};
      networking.interfaces = lib.mkOverride 10 {};
      networking.defaultGateway = lib.mkOverride 10 null;

      # Disable router VM autostart and all VM declarations
      hydrix.router.autostart = lib.mkOverride 10 false;
      hydrix.microvmHost.enable = lib.mkOverride 10 false;

      # Simple firewall
      networking.firewall = lib.mkOverride 10 {
        enable = true;
        allowedTCPPorts = [ 22 ];
      };

      # Packages configured in user's hydrix-config/specialisations/fallback.nix
    };

    # =========================================================================
    # COMMON - Available in all modes
    # =========================================================================

    environment.systemPackages = with pkgs; [
      # Live mode switcher
      (writeShellScriptBin "hydrix-switch" ''
        set -uo pipefail

        # Colors
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        BOLD='\033[1m'
        NC='\033[0m'

        # Config from Nix options
        ROUTER_IP="${netCfg.routerIp}"
        # All bridges: built-in defaults + infra VM bridges + extra-network bridges.
        # Computed at build time so hydrix-switch can verify/recreate them all after
        # a mode switch without needing to know about each one individually.
        BRIDGES="${lib.concatStringsSep " " (
          netCfg.bridges
          ++ lib.unique (lib.attrValues netCfg.infraTapBridges)
          ++ map (n: "br-${n.name}") netCfg.extraNetworks
        )}"
        MGMT_SUBNET="${netCfg.subnets.mgmt or "192.168.100"}"
        SHARED_SUBNET="${netCfg.subnets.shared or "192.168.105"}"

        # Detect current mode
        get_current_mode() {
          if [[ -f /etc/HYDRIX_MODE ]]; then
            . /etc/HYDRIX_MODE
            echo "$MODE"
          else
            echo "unknown"
          fi
        }

        CURRENT=$(get_current_mode)

        # Toggle mode if no args (between lockdown and administrative)
        if [[ $# -eq 0 ]]; then
          case "$CURRENT" in
            administrative)
              TARGET="lockdown"
              echo -e "''${BOLD}Toggling: administrative → lockdown''${NC}"
              ;;
            lockdown)
              TARGET="administrative"
              echo -e "''${BOLD}Toggling: lockdown → administrative''${NC}"
              ;;
            *)
              echo -e "''${RED}Error: Unknown current mode $CURRENT''${NC}"
              echo "Usage: hydrix-switch [mode]"
              echo "Modes: lockdown, administrative"
              exit 1
              ;;
          esac
        else
          TARGET="$1"
        fi

        # Normalize shortcuts
        case "$TARGET" in
          admin) TARGET="administrative" ;;
          lock)  TARGET="lockdown" ;;
        esac

        # Validate
        case "$TARGET" in
          lockdown|administrative) ;;
          *)
            echo -e "''${RED}Error: Unknown mode $TARGET''${NC}"
            echo "Valid modes: lockdown, administrative"
            exit 1
            ;;
        esac

        # Already there?
        if [[ "$CURRENT" == "$TARGET" ]]; then
          echo -e "''${GREEN}Already in $TARGET mode''${NC}"
          exit 0
        fi

        # =====================================================================
        # LIVE SWITCHING: lockdown <-> administrative
        # =====================================================================

        echo -e "''${BOLD}Switching: $CURRENT → $TARGET''${NC}"
        echo ""

        if [[ "$TARGET" == "administrative" ]]; then
          echo "This will:"
          echo "  - Add default gateway through router VM ($ROUTER_IP)"
          echo "  - Enable host internet access"
          echo "  - VMs unaffected"
        else
          echo "This will:"
          echo "  - Remove host default gateway"
          echo "  - Block host internet access"
          echo "  - VMs unaffected (internet via router)"
        fi
        echo ""

        read -p "Proceed? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          echo "Cancelled"
          exit 0
        fi

        echo ""

        # Check if builder VM is running (affects nix-daemon management)
        BUILDER_RUNNING=false
        if systemctl is-active --quiet microvm@microvm-builder.service 2>/dev/null; then
          BUILDER_RUNNING=true
          echo "  Note: Builder VM running - nix-daemon will stay managed by builder"
        fi

        if [[ "$TARGET" == "administrative" ]]; then
          echo "Switching to administrative..."

          # Activate administrative specialisation
          if [[ -d /nix/var/nix/profiles/system/specialisation/administrative ]]; then
            sudo /nix/var/nix/profiles/system/specialisation/administrative/bin/switch-to-configuration switch
          else
            echo -e "''${RED}Error: Administrative specialisation not found''${NC}"
            echo "Run 'rebuild administrative' first to build it"
            exit 1
          fi

          # If builder was running, keep nix-daemon stopped
          if [[ "$BUILDER_RUNNING" == "true" ]]; then
            sudo systemctl stop nix-daemon.service nix-daemon.socket 2>/dev/null || true
          fi

          # Verify gateway is set
          if ! ip route show default 2>/dev/null | grep -q "$ROUTER_IP"; then
            sudo ip route add default via "$ROUTER_IP" dev br-mgmt 2>/dev/null || true
          fi

        else
          echo "Switching to lockdown..."

          # Activate base config (lockdown)
          sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch

          # If builder was running, keep nix-daemon stopped
          if [[ "$BUILDER_RUNNING" == "true" ]]; then
            sudo systemctl stop nix-daemon.service nix-daemon.socket 2>/dev/null || true
          fi

          # Ensure gateway is removed
          sudo ip route del default 2>/dev/null || true
        fi

        # Verify bridges are still up (switch-to-configuration can sometimes reset them)
        echo ""
        echo "Verifying bridges..."
        for br in $BRIDGES; do
          if ! ip link show "$br" &>/dev/null; then
            sudo ip link add name "$br" type bridge 2>/dev/null || true
            echo "  Recreated $br"
          fi
          sudo ip link set "$br" up 2>/dev/null || true
        done

        # Restore host IPs on management and shared bridges
        sudo ip addr add "''${MGMT_SUBNET}.1/24" dev br-mgmt 2>/dev/null || true
        sudo ip addr add "''${SHARED_SUBNET}.1/24" dev br-shared 2>/dev/null || true

        # Re-attach ALL TAPs to bridges (in case switch disrupted them)
        # microvm-tap-lookup is generated at build time from all known TAP→bridge
        # mappings (router, infra, profile, extra-network) — no hardcoded cases needed.
        # Unknown TAPs return empty string and are silently skipped.
        #
        # Previously this used a hardcoded case statement with a catch-all
        # (*) bridge="br-browse") that incorrectly assigned unknown TAPs (e.g.
        # usb-sandbox) to br-browse. Replaced with dynamic lookup so new infra
        # VMs are handled automatically without code changes here.
        for tap in $(ip -o link show 2>/dev/null | grep -oP 'mv-[a-z0-9-]+(?=[@:])' | sort -u); do
          bridge=$(microvm-tap-lookup "$tap")
          if [[ -n "''${bridge:-}" ]]; then
            sudo ip link set "$tap" master "$bridge" 2>/dev/null || true
            sudo ip link set "$tap" up 2>/dev/null || true
          fi
        done

        echo ""
        source /etc/HYDRIX_MODE 2>/dev/null || true
        echo -e "''${GREEN}Now in ''${MODE:-$TARGET} mode''${NC}"
        if [[ "$TARGET" == "administrative" ]]; then
          echo "Host internet: enabled (via $ROUTER_IP)"
        else
          echo "Host internet: disabled"
          echo "Builder VM: available for nix builds"
        fi
      '')

      # Mode detection
      (writeShellScriptBin "hydrix-mode" ''
        if [[ -f /etc/HYDRIX_MODE ]]; then
          source /etc/HYDRIX_MODE
          echo "Current mode: $MODE"
          echo "Description:  $DESCRIPTION"
          echo "Internet:     $INTERNET"
          echo "VMs:          $VMS"
          [[ -n "''${WARNING:-}" ]] && echo "WARNING:      $WARNING"
        else
          echo "Mode: unknown (no /etc/HYDRIX_MODE)"
        fi
        echo ""
        echo "Available modes:"
        echo "  rebuild                  -> lockdown (default)"
        echo "  rebuild administrative   -> full functionality"
        echo "  rebuild fallback         -> emergency WiFi (reboot required)"
      '')

      # Router status (works in all modes)
      (writeShellScriptBin "router-status" ''
        echo "Router Status"
        echo "============="
        echo "Type: ${cfg.router.type}"
        ${if cfg.router.type == "microvm" then ''
          echo "MicroVM: $(systemctl is-active microvm@microvm-router 2>/dev/null || echo 'inactive')"
        '' else ''
          echo "Libvirt: $(sudo virsh domstate router 2>/dev/null || echo 'not defined')"
        ''}
        echo ""
        echo "Bridges:"
        for br in ${lib.concatStringsSep " " (
          netCfg.bridges
          ++ lib.unique (lib.attrValues netCfg.infraTapBridges)
          ++ map (n: "br-${n.name}") netCfg.extraNetworks
        )}; do
          state=$(ip link show $br 2>/dev/null | grep -o 'state [A-Z]*' || echo 'NOT FOUND')
          echo "  $br: $state"
        done
        echo ""
        echo "Host gateway:"
        ip route show default 2>/dev/null || echo "  None (lockdown mode)"
      '')
    ];
  };
}
