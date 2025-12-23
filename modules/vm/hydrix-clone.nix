# Hydrix repository cloning service
# Clones Hydrix from GitHub to /home/user/Hydrix on first boot
# Uses "user" - the standard VM user from users-vm.nix
{ config, pkgs, lib, ... }:

{
  # Systemd service to clone Hydrix repo on FIRST BOOT
  systemd.services.hydrix-clone = {
    description = "Clone Hydrix repository to user home directory";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nss-lookup.target" ];
    wants = [ "network-online.target" ];
    requires = [ "network-online.target" ];
    before = [ "hydrix-hardware-setup.service" "hydrix-shape.service" ];

    # Only run once
    unitConfig = {
      ConditionPathExists = "!/home/user/.hydrix-cloned";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      echo "=== Cloning Hydrix repository ==="

      # Wait for network to be fully ready
      for i in {1..30}; do
        if ${pkgs.curl}/bin/curl -s --connect-timeout 2 https://github.com >/dev/null 2>&1; then
          echo "✓ Network is ready"
          break
        fi
        echo "Waiting for network... ($i/30)"
        sleep 2
      done

      # Clone Hydrix from GitHub
      echo "Cloning from GitHub..."
      ${pkgs.git}/bin/git clone https://github.com/borttappat/Hydrix.git /home/user/Hydrix

      if [ -d /home/user/Hydrix/.git ]; then
        echo "✓ Hydrix cloned successfully"

        # Set ownership
        chown -R user:users /home/user/Hydrix

        # Make scripts executable
        if [ -d /home/user/Hydrix/scripts ]; then
          chmod +x /home/user/Hydrix/scripts/*.sh 2>/dev/null || true
        fi

        # Mark as cloned
        touch /home/user/.hydrix-cloned
        chown user:users /home/user/.hydrix-cloned
      else
        echo "✗ ERROR: Failed to clone Hydrix repository"
        exit 1
      fi
    '';
  };
}
