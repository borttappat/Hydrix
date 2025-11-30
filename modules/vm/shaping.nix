# VM shaping service - clones Hydrix repo and applies full profile
{ config, pkgs, lib, ... }:

{
  # First-boot shaping service
  systemd.services.hydrix-shape = {
    description = "Hydrix VM first-boot shaping";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      #!/usr/bin/env bash
      set -euo pipefail

      SHAPED_MARKER="/etc/nixos/.hydrix-shaped"

      # Skip if already shaped
      if [ -f "$SHAPED_MARKER" ]; then
        echo "VM already shaped, skipping..."
        exit 0
      fi

      echo "=== Hydrix VM Shaping Started ==="

      # Extract VM type from hostname (e.g., "pentest-google" -> "pentest")
      HOSTNAME=$(${pkgs.hostname}/bin/hostname)
      VM_TYPE="''${HOSTNAME%%-*}"

      echo "Hostname: $HOSTNAME"
      echo "VM Type: $VM_TYPE"

      # Clone or update Hydrix repository
      HYDRIX_DIR="/etc/nixos/hydrix"
      if [ -d "$HYDRIX_DIR/.git" ]; then
        echo "Hydrix repository exists, pulling latest changes..."
        cd "$HYDRIX_DIR"
        ${pkgs.git}/bin/git pull

        if [ $? -eq 0 ]; then
          echo "✓ Git repository updated successfully"
        else
          echo "✗ ERROR: Failed to pull latest changes"
          exit 1
        fi
      else
        echo "Cloning Hydrix repository..."
        ${pkgs.git}/bin/git clone https://github.com/borttappat/Hydrix.git "$HYDRIX_DIR"

        if [ -d "$HYDRIX_DIR/.git" ]; then
          echo "✓ Git repository cloned successfully"
        else
          echo "✗ ERROR: .git directory missing after clone"
          exit 1
        fi
      fi

      # Apply full VM profile using nixbuild-vm script
      echo "Applying full profile for VM type: $VM_TYPE"
      if ${pkgs.bash}/bin/bash /run/current-system/sw/bin/nixbuild-vm; then
        echo "✓ System rebuild completed"
      else
        echo "✗ ERROR: System rebuild failed"
        exit 1
      fi

      # Mark as shaped
      touch "$SHAPED_MARKER"
      echo "=== Hydrix VM Shaping Completed ==="
    '';
  };
}
