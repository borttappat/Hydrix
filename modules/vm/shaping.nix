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

      # Extract VM type from hostname (e.g., "pentest-grief" -> "pentest")
      HOSTNAME=$(${pkgs.hostname}/bin/hostname)
      VM_TYPE="''${HOSTNAME%%-*}"

      echo "Hostname: $HOSTNAME"
      echo "VM Type: $VM_TYPE"

      # Clone Hydrix repository with git history
      HYDRIX_DIR="/etc/nixos/hydrix"
      if [ ! -d "$HYDRIX_DIR/.git" ]; then
        echo "Cloning Hydrix repository..."
        ${pkgs.git}/bin/git clone https://github.com/borttappat/Hydrix.git "$HYDRIX_DIR"

        if [ -d "$HYDRIX_DIR/.git" ]; then
          echo "✓ Git repository cloned successfully"
        else
          echo "✗ ERROR: .git directory missing after clone"
          exit 1
        fi
      fi

      # Apply full VM profile
      echo "Applying full profile for VM type: vm-$VM_TYPE"
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake "$HYDRIX_DIR#vm-$VM_TYPE"

      # Mark as shaped
      touch "$SHAPED_MARKER"
      echo "=== Hydrix VM Shaping Completed ==="
    '';
  };
}
