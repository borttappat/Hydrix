# VM shaping service - applies full profile based on hostname
{ config, pkgs, lib, ... }:

{
  # First-boot shaping service
  systemd.services.hydrix-shape = {
    description = "Hydrix VM first-boot shaping";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "hydrix-clone.service" "hydrix-hardware-setup.service" ];
    wants = [ "network-online.target" ];

    # Only run once
    unitConfig = {
      ConditionPathExists = "!/var/lib/hydrix-shaped";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "traum";
    };

    script = ''
      #!/usr/bin/env bash
      set -euo pipefail

      echo "=== Hydrix VM Shaping Started ==="

      # Extract VM type from hostname (e.g., "pentest-google" -> "pentest")
      HOSTNAME=$(${pkgs.hostname}/bin/hostname)
      VM_TYPE="''${HOSTNAME%%-*}"

      echo "Hostname: $HOSTNAME"
      echo "VM Type: $VM_TYPE"

      # Map VM type to flake entry
      case "$VM_TYPE" in
        pentest)
          FLAKE_ENTRY="vm-pentest"
          ;;
        comms)
          FLAKE_ENTRY="vm-comms"
          ;;
        browsing)
          FLAKE_ENTRY="vm-browsing"
          ;;
        dev)
          FLAKE_ENTRY="vm-dev"
          ;;
        *)
          echo "✗ ERROR: Unknown VM type: $VM_TYPE"
          echo "Expected: pentest, comms, browsing, or dev"
          exit 1
          ;;
      esac

      echo "Flake Entry: $FLAKE_ENTRY"

      # Hydrix should already be at /home/traum/Hydrix (copied by hydrix-embed service)
      HYDRIX_DIR="/home/traum/Hydrix"
      if [ ! -d "$HYDRIX_DIR" ]; then
        echo "✗ ERROR: Hydrix directory not found at $HYDRIX_DIR"
        exit 1
      fi

      echo "✓ Hydrix repository found at $HYDRIX_DIR"

      # Apply full VM profile using nixos-rebuild directly
      echo "Applying full profile: $FLAKE_ENTRY"
      cd "$HYDRIX_DIR"

      if sudo nixos-rebuild switch --flake ".#$FLAKE_ENTRY" --impure; then
        echo "✓ System rebuild completed"
        echo "✓ Marking VM as shaped"
        sudo touch /var/lib/hydrix-shaped
      else
        echo "✗ ERROR: System rebuild failed"
        exit 1
      fi

      echo "=== Hydrix VM Shaping Completed ==="
      echo "System will reboot in 5 seconds..."
      sleep 5
      sudo systemctl reboot
    '';
  };
}
