# MicroVM Host Module - Integrates microvm.nix with Hydrix host
#
# This module:
# - Imports the microvm host module (manages virtiofsd, TAP interfaces)
# - Configures TAP interface bridge attachment via systemd-networkd
# - Declares microVMs for autostart
# - Special handling for router microVM (multiple TAP interfaces)
#
# Usage:
#   1. Enable in your machine config: hydrix.microvmHost.enable = true;
#   2. Rebuild host: rebuild
#   3. Build microVM: microvm build microvm-browsing
#   4. Start microVM: microvm start microvm-browsing
#   5. Or enable autostart: hydrix.microvmHost.vms."microvm-browsing".autostart = true;
#
{ config, lib, pkgs, self, ... }:

let
  cfg = config.hydrix.microvmHost;
  secretsCfg = config.hydrix.secrets;
  username = config.hydrix.username;

  # Filter VMs that need GitHub secrets
  vmsWithGithubSecrets = lib.filterAttrs (_: v: v.enable && v.secrets.github) cfg.vms;

  # Check if router microVM is enabled
  routerEnabled =
    (cfg.vms ? "microvm-router" && cfg.vms."microvm-router".enable);

  # Router TAP interface to bridge mapping
  # TAP names must be max 15 chars (Linux limit)
  routerTaps = {
    "mv-router-mgmt" = "br-mgmt";
    "mv-router-pent" = "br-pentest";
    "mv-router-comm" = "br-comms";
    "mv-router-lurk" = "br-lurking";
    "mv-router-brow" = "br-browse";
    "mv-router-dev" = "br-dev";
    "mv-router-shar" = "br-shared";
    "mv-router-bldr" = "br-builder";
  };

  # Helper script for attaching TAP interfaces to bridges with retry
  # Handles race condition where bridge may not exist yet during early boot
  attachTapScript = pkgs.writeShellScript "attach-tap-to-bridge" ''
    set -euo pipefail
    TAP="$1"
    BRIDGE="$2"
    MAX_RETRIES=30
    RETRY_DELAY=0.5

    # Wait for bridge to exist
    for i in $(seq 1 $MAX_RETRIES); do
      if ${pkgs.iproute2}/bin/ip link show "$BRIDGE" &>/dev/null; then
        # Bridge exists, attach TAP
        if ${pkgs.iproute2}/bin/ip link set "$TAP" master "$BRIDGE" 2>/dev/null; then
          exit 0
        fi
      fi
      sleep $RETRY_DELAY
    done

    # Log failure (visible in journalctl)
    echo "Failed to attach $TAP to $BRIDGE after $MAX_RETRIES retries" >&2
    exit 1
  '';
in {
  # Note: microvm.nixosModules.host is imported by mkHost in lib/default.nix
  # Options for hydrix.microvmHost are declared in modules/options.nix

  config = lib.mkMerge [
    # Custom microvm CLI — always available regardless of microvmHost.enable
    # so fallback mode and fresh installs can still manage VMs
    {
      environment.systemPackages = [
        (lib.hiPrio (pkgs.writeShellScriptBin "microvm"
          (builtins.readFile ../../scripts/microvm)
        ))
      ];
    }

    # Default: enable microvm-router when microvmHost is enabled
    # Note: autostart is controlled by router.nix via hydrix.router.autostart
    (lib.mkIf cfg.enable {
      hydrix.microvmHost.vms."microvm-router" = {
        enable = lib.mkDefault true;
      };
    })

    (lib.mkIf cfg.enable {
    # DON'T enable systemd-networkd - Hydrix uses NetworkManager
    # Instead, use a udev rule to attach TAP interfaces to bridges

    # Udev rules to add microVM TAP interfaces to bridges
    # Router TAPs go to specific bridges, other TAPs go to default bridge
    services.udev.extraRules = ''
      # Router microVM TAP interfaces - each goes to specific bridge
      # Uses retry script to handle race condition with bridge creation
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-mgmt", RUN+="${attachTapScript} %k br-mgmt"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-pent", RUN+="${attachTapScript} %k br-pentest"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-comm", RUN+="${attachTapScript} %k br-comms"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-lurk", RUN+="${attachTapScript} %k br-lurking"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-brow", RUN+="${attachTapScript} %k br-browse"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-dev", RUN+="${attachTapScript} %k br-dev"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-shar", RUN+="${attachTapScript} %k br-shared"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-bldr", RUN+="${attachTapScript} %k br-builder"

      # Git-sync VM TAP → builder bridge (trusted utility VM, shares builder network)
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-gitsync", RUN+="${attachTapScript} %k br-builder"

      # Other microVM TAP interfaces (mv-*) go to default bridge
      # Exclude router interfaces which are handled above
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-*", KERNEL!="mv-router-*", KERNEL!="mv-gitsync", RUN+="${attachTapScript} %k ${cfg.defaultBridge}"

      # VFIO device permissions for microvm user (needed for PCI passthrough)
      # This allows the microvm user to access VFIO IOMMU group devices
      SUBSYSTEM=="vfio", MODE="0666"
    '';

    # Trust microVM TAP interfaces in firewall
    networking.firewall.trustedInterfaces = [ "mv-+" ];

    # Ensure virtiofsd is available
    # Install custom microvm script with high priority to override upstream
    environment.systemPackages = [
      pkgs.virtiofsd
      pkgs.socat  # For microvm-router console access
      # The microvm script has built-in flake detection that checks:
      # 1. HYDRIX_FLAKE_DIR env var
      # 2. ~/hydrix-config/flake.nix
      # 3. ~/Hydrix/flake.nix
      (lib.hiPrio (pkgs.writeShellScriptBin "microvm"
        (builtins.readFile ../../scripts/microvm)
      ))
    ];

    # Ensure home directory is traversable after every activation
    # tmpfiles only runs at boot, so we need an activation script too
    system.activationScripts.microvmPermissions = lib.stringAfter [ "users" ] ''
      chmod 711 /home/${username}

      # Set default ACLs on persist directories so files created via 9p are world-writable
      # This fixes the issue where files created by QEMU (microvm:kvm) aren't writable by VM user
      for dir in /home/${username}/persist/*/dev /home/${username}/persist/*/staging; do
        if [ -d "$dir" ]; then
          # Set default ACL: new files/dirs get rwx for everyone
          ${pkgs.acl}/bin/setfacl -d -m o::rwx "$dir" 2>/dev/null || true
          ${pkgs.acl}/bin/setfacl -d -m g::rwx "$dir" 2>/dev/null || true
          ${pkgs.acl}/bin/setfacl -d -m u::rwx "$dir" 2>/dev/null || true
          # Also fix existing files
          ${pkgs.acl}/bin/setfacl -R -m o::rwx "$dir" 2>/dev/null || true
          chmod -R a+rw "$dir" 2>/dev/null || true
        fi
      done
    '';

    # Create config directories for microVMs
    # Also ensure user's home directory is traversable (o+x) for 9p mounts
    systemd.tmpfiles.rules = [
      "d /var/lib/microvms 0755 root root -"
      # Allow microvm user to traverse into user's home for 9p shares
      # Mode 0711 = rwx--x--x (owner full, others can traverse)
      "z /home/${username} 0711 ${username} users -"

      # Create persist directories for host-mapped VM storage
      # ~/persist/<vmType>/ is shared to VMs as ~/persist/ via 9p
      # Mode 0777 because 9p is served by QEMU (microvm user) which needs write access
      # Security: acceptable since ~/persist is inside user home which requires traversal (0711)
      # IMPORTANT: Pre-create subdirectories (dev/, staging/) because mkdir via 9p
      # creates them owned by microvm:kvm, making them unwritable by VM user
      "d /home/${username}/persist 0755 ${username} users -"
      "d /home/${username}/persist/browsing 0777 ${username} users -"
      "d /home/${username}/persist/browsing/dev 0777 ${username} users -"
      "d /home/${username}/persist/browsing/staging 0777 ${username} users -"
      "d /home/${username}/persist/pentest 0777 ${username} users -"
      "d /home/${username}/persist/pentest/dev 0777 ${username} users -"
      "d /home/${username}/persist/pentest/staging 0777 ${username} users -"
      "d /home/${username}/persist/dev 0777 ${username} users -"
      "d /home/${username}/persist/dev/dev 0777 ${username} users -"
      "d /home/${username}/persist/dev/staging 0777 ${username} users -"
      "d /home/${username}/persist/comms 0777 ${username} users -"
      "d /home/${username}/persist/comms/dev 0777 ${username} users -"
      "d /home/${username}/persist/comms/staging 0777 ${username} users -"

      # Hydrix config directory (for scaling.json shared with VMs via 9p)
      # Must exist before microVMs start, otherwise QEMU fails to mount
      "d /home/${username}/.config/hydrix 0755 ${username} users -"

    ] ++ (lib.concatLists (lib.mapAttrsToList (name: vmCfg:
      lib.optionals vmCfg.enable [
        # microvm service runs as microvm:kvm, needs write access for booted symlink
        "d /var/lib/microvms/${name} 0755 microvm kvm -"
        "d /var/lib/microvms/${name}/config 0755 root root -"
      ]
    ) cfg.vms))
    # Always create secrets directories for all enabled VMs.
    # VM profiles may set hydrix.microvm.secrets.github = true (adding a
    # virtiofs share), but the host can't see VM-side options at eval time.
    # Virtiofsd crashes if the source path is missing, so pre-create for all.
    ++ (lib.mapAttrsToList (name: _: "d /run/hydrix-secrets/${name}/ssh 0700 root root -")
      (lib.filterAttrs (_: v: v.enable) cfg.vms));

    # Declare microVMs from hydrix.microvmHost.vms
    # VM names must match nixosConfigurations in the Hydrix flake
    microvm.vms = let
      infrastructureVMs = [ "microvm-router" "microvm-builder" ];
      enabledVMs = lib.filterAttrs (_: v: v.enable) cfg.vms;
      filteredVMs = if cfg.infrastructureOnly
        then lib.filterAttrs (name: _: builtins.elem name infrastructureVMs) enabledVMs
        else enabledVMs;
    in lib.mapAttrs (name: vmCfg: {
      inherit (vmCfg) autostart;
      # Use the Hydrix flake itself as the source
      flake = self;
      # Allow updates via `microvm -u <name>` (uses user's hydrix-config)
      updateFlake = "path:${config.hydrix.paths.configDir}";
    }) filteredVMs;

    # ===== Systemd Services =====
    # Combines router TAP setup and secrets provisioning
    systemd.services = lib.mkMerge [
      # Router MicroVM needs to run as root for VFIO PCI passthrough
      (lib.mkIf routerEnabled {
        "microvm@microvm-router" = {
          serviceConfig = {
            User = lib.mkForce "root";
            Group = lib.mkForce "root";
          };
        };
      })

      # Router MicroVM TAP Interface Setup
      # Creates TAP interfaces for the router before QEMU starts
      # The primary TAP (mv-router-mgmt) is handled by microvm.nix
      # Additional TAPs added via qemu.extraArgs need manual creation
      (lib.mkIf routerEnabled {
        microvm-router-taps = {
          description = "Create TAP interfaces for router microVM";
          requiredBy = [ "microvm@microvm-router.service" ];
          before = [ "microvm@microvm-router.service" ];
          after = [ "network.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          path = [ pkgs.iproute2 ];

          script = ''
            set -e
            echo "Creating router microVM TAP interfaces..."

            # Create TAP interfaces for router (except primary which microvm.nix handles)
            # Format: tap name -> bridge
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (tap: bridge: ''
              if ! ip link show ${tap} &>/dev/null; then
                ip tuntap add dev ${tap} mode tap
                echo "  Created ${tap}"
              fi
              ip link set ${tap} master ${bridge} 2>/dev/null || true
              ip link set ${tap} up
              echo "  ${tap} -> ${bridge}"
            '') (lib.filterAttrs (tap: _: tap != "mv-router-mgmt") routerTaps))}

            echo "Router TAP interfaces ready"
          '';

          preStop = ''
            echo "Cleaning up router microVM TAP interfaces..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (tap: _: ''
              if ip link show ${tap} &>/dev/null; then
                ip link del ${tap} 2>/dev/null || true
              fi
            '') (lib.filterAttrs (tap: _: tap != "mv-router-mgmt") routerTaps))}
          '';
        };
      })

      # Ensure all TAP interfaces are attached to correct bridges
      # Runs on every activation (including specialisation switches)
      # Handles the case where bridges are recreated but TAPs already exist
      (lib.mkIf routerEnabled {
        microvm-tap-bridges = {
          description = "Ensure microVM TAP interfaces are attached to bridges";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "microvm-router-taps.service" ];
          # Re-run on every activation (rebuild/switch) to fix TAPs detached by bridge recreation
          restartIfChanged = true;
          # Trigger restart whenever network target is re-reached (bridges recreated)
          partOf = [ "network.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          path = [ pkgs.iproute2 ];

          script = ''
            echo "Ensuring TAP-to-bridge attachments..."

            # Router TAPs -> specific bridges
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (tap: bridge: ''
              if ip link show ${tap} &>/dev/null && ip link show ${bridge} &>/dev/null; then
                ip link set ${tap} master ${bridge} 2>/dev/null || true
                ip link set ${tap} up 2>/dev/null || true
              fi
            '') routerTaps)}

            # VM TAPs -> default or profile-specific bridge
            for tap in $(ip -o link show 2>/dev/null | grep -oP 'mv-(?!router)[a-z-]+(?=[@:])' | sort -u); do
              bridge="${cfg.defaultBridge}"
              case "$tap" in
                mv-browse*)  bridge="br-browse" ;;
                mv-pentest*) bridge="br-pentest" ;;
                mv-hack*)    bridge="br-pentest" ;;
                mv-dev*)     bridge="br-dev" ;;
                mv-lurk*)    bridge="br-lurking" ;;
                mv-comms*)   bridge="br-comms" ;;
                mv-build*)   bridge="br-builder" ;;
                mv-gitsyn*)  bridge="br-builder" ;;
              esac
              if ip link show "$bridge" &>/dev/null; then
                ip link set "$tap" master "$bridge" 2>/dev/null || true
                ip link set "$tap" up 2>/dev/null || true
              fi
            done

            echo "TAP-to-bridge attachments verified"
          '';
        };
      })

      # Secrets Provisioning for MicroVMs
      # For each VM with secrets.github = true, create a service to copy
      # decrypted keys from /run/secrets/github/
      (lib.mkIf (secretsCfg.enable && secretsCfg.github.enable) (
        lib.mapAttrs' (name: _: lib.nameValuePair "hydrix-secrets-${name}" {
          description = "Provision secrets for microVM ${name}";
          wantedBy = [ "microvm@${name}.service" ];
          before = [ "microvm@${name}.service" ];
          # sops-nix decrypts via activation script, secrets exist by local-fs.target
          after = [ "local-fs.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          script = ''
            set -e

            SECRETS_DIR="/run/hydrix-secrets/${name}/ssh"
            GITHUB_SECRETS="/run/secrets/github"

            # Create secrets directory
            mkdir -p "$SECRETS_DIR"
            chmod 700 "$SECRETS_DIR"

            # Copy GitHub SSH keys if they exist
            if [ -f "$GITHUB_SECRETS/id_ed25519" ]; then
              cp "$GITHUB_SECRETS/id_ed25519" "$SECRETS_DIR/"
              chmod 600 "$SECRETS_DIR/id_ed25519"
            else
              echo "Warning: GitHub private key not found at $GITHUB_SECRETS/id_ed25519"
            fi

            if [ -f "$GITHUB_SECRETS/id_ed25519.pub" ]; then
              cp "$GITHUB_SECRETS/id_ed25519.pub" "$SECRETS_DIR/"
              chmod 644 "$SECRETS_DIR/id_ed25519.pub"
            else
              echo "Warning: GitHub public key not found at $GITHUB_SECRETS/id_ed25519.pub"
            fi

            echo "Secrets provisioned for ${name}"
          '';
        }) vmsWithGithubSecrets
      ))

      # First-boot VM builder: builds any declared VMs that haven't been built yet
      # Runs once after install — subsequent boots find VMs already built
      {
        hydrix-firstboot-vms = {
          description = "Build microVMs on first boot";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" "nix-daemon.socket" ];
          wants = [ "network-online.target" ];

          # Only run if at least one VM is missing its runner
          unitConfig.ConditionPathExists = "!/var/lib/hydrix/.firstboot-vms-done";

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          path = [ pkgs.nix pkgs.git pkgs.coreutils pkgs.systemd ];

          script = let
            configDir = config.hydrix.paths.configDir;
            enabledVMs = lib.filterAttrs (_: v: v.enable) cfg.vms;
          in ''
            set -euo pipefail
            echo "Checking for unbuilt microVMs..."

            BUILT=0
            FAILED=0

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
              if [ ! -e "/var/lib/microvms/${name}/current/bin/microvm-run" ]; then
                echo "Building ${name}..."
                if nix build "path:${configDir}#nixosConfigurations.${name}.config.microvm.declaredRunner" \
                    --no-link --print-build-logs 2>&1; then
                  echo "${name} built successfully"
                  # Reset failed state and start if autostart
                  systemctl reset-failed "microvm@${name}.service" 2>/dev/null || true
                  BUILT=$((BUILT + 1))
                else
                  echo "${name} build FAILED"
                  FAILED=$((FAILED + 1))
                fi
              else
                echo "${name} already built, skipping"
              fi
            '') enabledVMs)}

            echo "First-boot VM build complete: $BUILT built, $FAILED failed"
            mkdir -p /var/lib/hydrix
            touch /var/lib/hydrix/.firstboot-vms-done
          '';
        };
      }
    ];
  })
  ];
}
