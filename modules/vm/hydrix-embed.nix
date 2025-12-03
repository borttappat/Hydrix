# Hydrix repository embedding and first-boot copy service
# Copies Hydrix from /etc/hydrix-template to /home/traum/Hydrix on first boot
{ config, pkgs, lib, ... }:

{
  # Systemd service to copy Hydrix repo to user home on FIRST BOOT
  systemd.services.hydrix-copy-to-home = {
    description = "Copy Hydrix repository to user home directory";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "hydrix-hardware-setup.service" ];  # Must run before hardware setup

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      if [ ! -f /home/traum/.hydrix-initialized ]; then
        echo "=== Copying Hydrix to /home/traum/Hydrix ==="

        # Create directory
        mkdir -p /home/traum/Hydrix

        # Copy from template
        ${pkgs.rsync}/bin/rsync -av /etc/hydrix-template/ /home/traum/Hydrix/

        # Set ownership
        chown -R traum:users /home/traum/Hydrix
        chmod -R u+w /home/traum/Hydrix

        # Make scripts executable
        if [ -d /home/traum/Hydrix/scripts ]; then
          chmod +x /home/traum/Hydrix/scripts/*.sh
        fi

        # Initialize as git repo (required for nixbuild to work)
        cd /home/traum/Hydrix
        ${pkgs.git}/bin/git init
        ${pkgs.git}/bin/git config user.name "Hydrix VM"
        ${pkgs.git}/bin/git config user.email "vm@hydrix.local"
        ${pkgs.git}/bin/git branch -M master
        ${pkgs.git}/bin/git add .
        ${pkgs.git}/bin/git commit -m "Initial Hydrix snapshot from VM build"
        chown -R traum:users /home/traum/Hydrix/.git

        # Run the links script to set up symlinks
        if [ -f /home/traum/Hydrix/scripts/links.sh ]; then
          ${pkgs.su}/bin/su - traum -c 'cd /home/traum/Hydrix && ./scripts/links.sh'
        fi

        # Mark as initialized
        touch /home/traum/.hydrix-initialized
        chown traum:users /home/traum/.hydrix-initialized

        echo "✓ Hydrix repository copied to /home/traum/Hydrix"
      else
        echo "Hydrix already initialized, skipping copy"
      fi
    '';
  };
}
