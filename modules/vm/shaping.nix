# VM shaping service - applies full profile based on hostname
{ config, pkgs, lib, ... }:

{
  # First-boot shaping service
  systemd.services.hydrix-shape = {
    description = "Hydrix VM first-boot shaping";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "hydrix-copy-to-home.service" "hydrix-hardware-setup.service" ];
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

      # Hydrix should already be at /home/traum/Hydrix (copied by hydrix-embed service)
      HYDRIX_DIR="/home/traum/Hydrix"
      if [ ! -d "$HYDRIX_DIR" ]; then
        echo "✗ ERROR: Hydrix directory not found at $HYDRIX_DIR"
        exit 1
      fi

      echo "✓ Hydrix repository found at $HYDRIX_DIR"

      # Apply full VM profile using nixbuild-vm script
      echo "Applying full profile for VM type: $VM_TYPE"
      cd "$HYDRIX_DIR"

      if ${pkgs.bash}/bin/bash /run/current-system/sw/bin/nixbuild-vm; then
        echo "✓ System rebuild completed"
      else
        echo "✗ ERROR: System rebuild failed"
        exit 1
      fi

      echo "=== Hydrix VM Shaping Completed ==="
    '';

    # Mark as complete after successful run
    postStop = ''
      ${pkgs.coreutils}/bin/touch /var/lib/hydrix-shaped
    '';
  };
}
