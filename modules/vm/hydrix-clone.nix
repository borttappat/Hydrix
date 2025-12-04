# Hydrix repository cloning service
# Clones Hydrix from GitHub to /home/traum/Hydrix on first boot
{ config, pkgs, lib, ... }:

{
  # Systemd service to clone Hydrix repo on FIRST BOOT
  systemd.services.hydrix-clone = {
    description = "Clone Hydrix repository to user home directory";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "hydrix-hardware-setup.service" "hydrix-shape.service" ];

    # Only run once
    unitConfig = {
      ConditionPathExists = "!/home/traum/.hydrix-cloned";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      echo "=== Cloning Hydrix repository ==="

      # Clone Hydrix from GitHub
      ${pkgs.git}/bin/git clone https://github.com/borttappat/Hydrix.git /home/traum/Hydrix

      if [ -d /home/traum/Hydrix/.git ]; then
        echo "✓ Hydrix cloned successfully"

        # Set ownership
        chown -R traum:users /home/traum/Hydrix

        # Make scripts executable
        if [ -d /home/traum/Hydrix/scripts ]; then
          chmod +x /home/traum/Hydrix/scripts/*.sh 2>/dev/null || true
        fi

        # Mark as cloned
        touch /home/traum/.hydrix-cloned
        chown traum:users /home/traum/.hydrix-cloned
      else
        echo "✗ ERROR: Failed to clone Hydrix repository"
        exit 1
      fi
    '';
  };
}
