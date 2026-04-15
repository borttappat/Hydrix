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

  stableRouterEnabled =
    (cfg.vms ? "microvm-router-stable" && cfg.vms."microvm-router-stable".enable);

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
    "mv-router-file" = "br-files";
  } // lib.listToAttrs (map (n: {
    name  = n.routerTap;
    value = "br-${n.name}";
  }) config.hydrix.networking.extraNetworks);

  # TAP → bridge mappings for infra VMs that use built-in subnets
  infraTapBridges = config.hydrix.networking.infraTapBridges;

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

    # Default: enable microvm-router and microvm-router-stable when microvmHost is enabled
    # Note: autostart is controlled by router.nix via hydrix.router.autostart
    (lib.mkIf cfg.enable {
      hydrix.microvmHost.vms."microvm-router" = {
        enable = lib.mkDefault true;
      };
      # Stable router: always declared, never autostarts — triggered by OnFailure on main router
      hydrix.microvmHost.vms."microvm-router-stable" = {
        enable = lib.mkDefault true;
        autostart = lib.mkDefault false;
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
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-wan",  RUN+="${attachTapScript} %k br-wan"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-mgmt", RUN+="${attachTapScript} %k br-mgmt"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-pent", RUN+="${attachTapScript} %k br-pentest"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-comm", RUN+="${attachTapScript} %k br-comms"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-lurk", RUN+="${attachTapScript} %k br-lurking"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-brow", RUN+="${attachTapScript} %k br-browse"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-dev", RUN+="${attachTapScript} %k br-dev"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-shar", RUN+="${attachTapScript} %k br-shared"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-router-bldr", RUN+="${attachTapScript} %k br-builder"

      # Stable router TAP interfaces — same bridges as main router, different prefix
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-mgmt", RUN+="${attachTapScript} %k br-mgmt"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-pent", RUN+="${attachTapScript} %k br-pentest"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-comm", RUN+="${attachTapScript} %k br-comms"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-lurk", RUN+="${attachTapScript} %k br-lurking"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-brow", RUN+="${attachTapScript} %k br-browse"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-dev",  RUN+="${attachTapScript} %k br-dev"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-shar", RUN+="${attachTapScript} %k br-shared"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-bldr", RUN+="${attachTapScript} %k br-builder"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-rts-file", RUN+="${attachTapScript} %k br-files"

      # Git-sync VM TAP → builder bridge (trusted utility VM, shares builder network)
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-gitsync", RUN+="${attachTapScript} %k br-builder"

      # Task pentest slot TAP interfaces (mv-task-*) → pentest bridge
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-task-*", RUN+="${attachTapScript} %k br-pentest"

      # VM TAP interfaces → explicit bridge mapping (no fallback — unknown TAPs stay unattached)
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-browse*",  RUN+="${attachTapScript} %k br-browse"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-pentest*", RUN+="${attachTapScript} %k br-pentest"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-dev*",     RUN+="${attachTapScript} %k br-dev"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-lurk*",    RUN+="${attachTapScript} %k br-lurking"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-comms*",   RUN+="${attachTapScript} %k br-comms"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-build*",   RUN+="${attachTapScript} %k br-builder"

# VFIO device permissions for microvm user (needed for PCI passthrough)
      # This allows the microvm user to access VFIO IOMMU group devices
      SUBSYSTEM=="vfio", MODE="0666"
    '' + lib.concatMapStrings (n: let
      stableTap = if lib.hasPrefix "mv-router-" n.routerTap
        then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
        else "mv-rts-${n.name}";
    in ''
      # Extra network: ${n.name} (br-${n.name}, subnet ${n.subnet}.0/24)
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="${n.routerTap}", RUN+="${attachTapScript} %k br-${n.name}"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="${stableTap}", RUN+="${attachTapScript} %k br-${n.name}"
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-${n.name}*",  RUN+="${attachTapScript} %k br-${n.name}"
    '') config.hydrix.networking.extraNetworks
    + lib.concatStringsSep "\n" (lib.mapAttrsToList (tap: bridge:
        "      ACTION==\"add\", SUBSYSTEM==\"net\", KERNEL==\"${tap}\", RUN+=\"${attachTapScript} %k ${bridge}\""
      ) infraTapBridges);

    # Trust microVM TAP interfaces in firewall
    networking.firewall.trustedInterfaces = [ "mv-+" ];

    # VM registry: written at activation, read by scripts/polybar at runtime
    # Populated by flake.nix from discovered profile meta.nix files
    environment.etc."hydrix/vm-registry.json" = lib.mkIf
      (config.hydrix.networking.vmRegistry != {}) {
        text = builtins.toJSON config.hydrix.networking.vmRegistry;
        mode = "0644";
      };

    # Ensure virtiofsd is available
    # Install custom microvm script with high priority to override upstream
    environment.systemPackages = [
      pkgs.virtiofsd
      pkgs.socat    # For microvm-router console access
      pkgs.openssl  # For microvm files passphrase generation
      # vsock-cmd: reliable AF_VSOCK client with proper SHUT_WR half-close.
      # socat closes the whole connection on stdin EOF, racing slow handlers.
      # Usage: echo "CMD args" | vsock-cmd <cid> <port> [timeout_secs]
      (pkgs.writeScriptBin "vsock-cmd" ''
        #!${pkgs.python3}/bin/python3
        import socket, sys

        cid          = int(sys.argv[1])
        port         = int(sys.argv[2])
        connect_timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0

        msg = sys.stdin.buffer.read()
        if not msg.endswith(b"\n"):
            msg += b"\n"

        sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        sock.settimeout(connect_timeout)
        sock.connect((cid, port))
        sock.settimeout(None)   # block until handler closes its end
        sock.sendall(msg)
        # No SHUT_WR: the handler uses `read` which stops at newline, not EOF.
        # Sending SHUT_WR causes socat on the VM to close the whole vsock
        # connection before the handler can write back.
        # We just read until the handler exits and socat closes its side.
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        sock.close()
      '')
      # The microvm script has built-in flake detection that checks:
      # 1. HYDRIX_FLAKE_DIR env var
      # 2. ~/hydrix-config/flake.nix
      # 3. ~/Hydrix/flake.nix
      (lib.hiPrio (pkgs.writeShellScriptBin "microvm"
        (builtins.readFile ../../scripts/microvm)
      ))
    ];

    # Allow wheel users to start/stop/restart microvm@ units without a password
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit").startsWith("microvm@") &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';

    # Ensure home directory is traversable after every activation
    # tmpfiles only runs at boot, so we need an activation script too
    system.activationScripts.microvmPermissions = lib.stringAfter [ "users" ] ''
      chmod 711 /home/${username}
    '';

    # Create config directories for microVMs
    # tmpfiles handles home directory mode declaratively (no activation script needed)
    systemd.tmpfiles.rules = [
      "d /var/lib/microvms 0755 root root -"
      # Mode 0711 = rwx--x--x: owner full access, others can traverse (needed for 9p mounts)
      "z /home/${username} 0711 ${username} users -"

      # Hydrix config directory (for scaling.json shared with VMs via 9p)
      # Must exist before microVMs start, otherwise QEMU fails to mount
      "d /home/${username}/.config/hydrix 0755 ${username} users -"

    ]
    # NOTE: Do NOT create /var/lib/microvms/<name> or subdirectories via tmpfiles.
    # The upstream microvm.nix install-microvm-<name> service uses
    # ConditionPathExists=!/var/lib/microvms/<name> to gate first-install
    # symlink creation. Pre-creating the directory (even implicitly via a
    # subdirectory) causes the condition to always fail, preventing the runner
    # symlink from being created on first boot.
    # The config subdirectory is created by hydrix-microvm-config-dirs below.
    # Always create secrets directories for all enabled VMs.
    # VM profiles may set hydrix.microvm.secrets.github = true (adding a
    # virtiofs share), but the host can't see VM-side options at eval time.
    # Virtiofsd crashes if the source path is missing, so pre-create for all.
    ++ (lib.mapAttrsToList (name: _: "d /run/hydrix-secrets/${name}/ssh 0700 root root -")
      (lib.filterAttrs (_: v: v.enable) cfg.vms))
    # Create /run/secrets/github so the provisioning service always has a valid
    # source directory to check, even when sops is not configured. Without this,
    # fresh installs without sops never get the dir and virtiofsd may fail.
    ++ lib.optionals (vmsWithGithubSecrets != {}) [
      "d /run/secrets/github 0700 root root -"
    ];

    # Declare microVMs from hydrix.microvmHost.vms
    # VM names must match nixosConfigurations in the Hydrix flake
    microvm.vms = let
      infrastructureVMs = [ "microvm-router" "microvm-router-stable" "microvm-builder" ];
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
      # Create config directories for microVMs after install-microvm-* has run.
      # Cannot use tmpfiles because creating /var/lib/microvms/<name>/config
      # would implicitly create the parent directory, which blocks the upstream
      # install-microvm-<name> ConditionPathExists=!/var/lib/microvms/<name>.
      (lib.listToAttrs (lib.mapAttrsToList (name: _: lib.nameValuePair "hydrix-microvm-config-dir-${name}" {
        description = "Create config directory for ${name}";
        after = [ "install-microvm-${name}.service" ];
        before = [ "microvm@${name}.service" ];
        wantedBy = [ "microvms.target" ];
        serviceConfig.Type = "oneshot";
        script = ''
          mkdir -p /var/lib/microvms/${name}/config
          chmod 755 /var/lib/microvms/${name}/config
        '';
      }) (lib.filterAttrs (_: v: v.enable) cfg.vms)))

      # Router MicroVM needs to run as root for VFIO PCI passthrough
      # Main router: triggers stable router on failure; conflicts with stable (VFIO)
      (lib.mkIf routerEnabled {
        "microvm@microvm-router" = {
          serviceConfig = {
            User = lib.mkForce "root";
            Group = lib.mkForce "root";
          };
          unitConfig = lib.mkIf stableRouterEnabled {
            OnFailure = "microvm@microvm-router-stable.service";
          };
        };
      })

      # Stable router: root for VFIO, conflicts with main router (can't share WiFi card)
      (lib.mkIf stableRouterEnabled {
        "microvm@microvm-router-stable" = {
          serviceConfig = {
            User = lib.mkForce "root";
            Group = lib.mkForce "root";
          };
          unitConfig = {
            Conflicts = "microvm@microvm-router.service";
            After = lib.mkForce [ "microvm-router-stable-taps.service" ];
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

      # Stable Router TAP Interface Setup
      # Creates mv-rts-* TAPs (same bridges as main router, different names)
      (lib.mkIf stableRouterEnabled {
        microvm-router-stable-taps = {
          description = "Create TAP interfaces for stable router microVM";
          requiredBy = [ "microvm@microvm-router-stable.service" ];
          before = [ "microvm@microvm-router-stable.service" ];
          after = [ "network.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          path = [ pkgs.iproute2 ];

          script = let
            stableTaps = {
              "mv-rts-pent" = "br-pentest";
              "mv-rts-comm" = "br-comms";
              "mv-rts-brow" = "br-browse";
              "mv-rts-dev"  = "br-dev";
              "mv-rts-shar" = "br-shared";
              "mv-rts-bldr" = "br-builder";
              "mv-rts-lurk" = "br-lurking";
              "mv-rts-file" = "br-files";
            } // lib.listToAttrs (map (n: {
              name  = if lib.hasPrefix "mv-router-" n.routerTap
                      then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
                      else "mv-rts-${n.name}";
              value = "br-${n.name}";
            }) config.hydrix.networking.extraNetworks);
          in ''
            set -e
            echo "Creating stable router TAP interfaces..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (tap: bridge: ''
              if ! ip link show ${tap} &>/dev/null; then
                ip tuntap add dev ${tap} mode tap
                echo "  Created ${tap}"
              fi
              ip link set ${tap} master ${bridge} 2>/dev/null || true
              ip link set ${tap} up
              echo "  ${tap} -> ${bridge}"
            '') stableTaps)}
            echo "Stable router TAP interfaces ready"
          '';

          preStop = let
            stableTaps = {
              "mv-rts-pent" = "br-pentest";
              "mv-rts-comm" = "br-comms";
              "mv-rts-brow" = "br-browse";
              "mv-rts-dev"  = "br-dev";
              "mv-rts-shar" = "br-shared";
              "mv-rts-bldr" = "br-builder";
              "mv-rts-lurk" = "br-lurking";
              "mv-rts-file" = "br-files";
            } // lib.listToAttrs (map (n: {
              name  = if lib.hasPrefix "mv-router-" n.routerTap
                      then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
                      else "mv-rts-${n.name}";
              value = "br-${n.name}";
            }) config.hydrix.networking.extraNetworks);
          in ''
            echo "Cleaning up stable router TAP interfaces..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (tap: _: ''
              if ip link show ${tap} &>/dev/null; then
                ip link del ${tap} 2>/dev/null || true
              fi
            '') stableTaps)}
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
          after = [ "network.target" "microvm-router-taps.service" "microvm-router-stable-taps.service" ];
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

            # Main router TAPs -> specific bridges
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (tap: bridge: ''
              if ip link show ${tap} &>/dev/null && ip link show ${bridge} &>/dev/null; then
                ip link set ${tap} master ${bridge} 2>/dev/null || true
                ip link set ${tap} up 2>/dev/null || true
              fi
            '') routerTaps)}

            # Stable router TAPs (mv-rts-*) -> same bridges
            for tap in $(ip -o link show 2>/dev/null | grep -oP 'mv-rts-[a-z0-9-]+(?=[@:])' | sort -u); do
              bridge=""
              case "$tap" in
                mv-rts-mgmt) bridge="br-mgmt" ;;
                mv-rts-pent) bridge="br-pentest" ;;
                mv-rts-comm) bridge="br-comms" ;;
                mv-rts-brow) bridge="br-browse" ;;
                mv-rts-dev)  bridge="br-dev" ;;
                mv-rts-shar) bridge="br-shared" ;;
                mv-rts-bldr) bridge="br-builder" ;;
                mv-rts-lurk) bridge="br-lurking" ;;
                mv-rts-file) bridge="br-files" ;;
                ${lib.concatStringsSep "\n                " (map (n: let
                  sTap = if lib.hasPrefix "mv-router-" n.routerTap
                    then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
                    else "mv-rts-${n.name}";
                in "${sTap}) bridge=\"br-${n.name}\" ;;") config.hydrix.networking.extraNetworks)}
              esac
              if [[ -n "$bridge" ]] && ip link show "$bridge" &>/dev/null; then
                ip link set "$tap" master "$bridge" 2>/dev/null || true
                ip link set "$tap" up 2>/dev/null || true
              fi
            done

            # VM TAPs -> default or profile-specific bridge
            for tap in $(ip -o link show 2>/dev/null | grep -oP 'mv-(?!router)[a-z-]+(?=[@:])' | sort -u); do
              bridge="${cfg.defaultBridge}"
              case "$tap" in
                mv-browse*)  bridge="br-browse" ;;
                mv-pentest*) bridge="br-pentest" ;;
                mv-dev*)     bridge="br-dev" ;;
                mv-lurk*)    bridge="br-lurking" ;;
                mv-comms*)   bridge="br-comms" ;;
                mv-build*)   bridge="br-builder" ;;
                mv-gitsyn*)  bridge="br-builder" ;;
                mv-task-*)   bridge="br-pentest" ;;
                ${lib.concatStringsSep "\n                " (
                  lib.mapAttrsToList (tap: bridge: "${tap}) bridge=\"${bridge}\" ;;") infraTapBridges
                  ++ map (n: "mv-${n.name}*) bridge=\"br-${n.name}\" ;;") config.hydrix.networking.extraNetworks
                )}
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
      # For each VM with secrets.github = true, create a service to:
      #   1. Ensure /run/hydrix-secrets/<name>/ssh exists before virtiofsd starts
      #      (virtiofsd crashes if its source path is missing — tmpfiles races it)
      #   2. Copy decrypted keys from /run/secrets/github/ before the VM boots
      # Runs unconditionally — handles missing keys gracefully so VMs start even
      # on fresh installs before sops is configured.
      (lib.mkIf (vmsWithGithubSecrets != {}) (
        lib.mapAttrs' (name: _: lib.nameValuePair "hydrix-secrets-${name}" {
          description = "Provision secrets for microVM ${name}";
          wantedBy = [ "microvm-virtiofsd@${name}.service" "microvm@${name}.service" ];
          before = [ "microvm-virtiofsd@${name}.service" "microvm@${name}.service" ];
          # Wait for hydrix-github-secrets to decrypt (or gracefully fail) before copying
          wants = [ "hydrix-github-secrets.service" ];
          after = [ "local-fs.target" "hydrix-github-secrets.service" ];

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

      # First-boot VM builder: builds unbuilt VMs and starts autostart VMs.
      # Closures are typically cached from the installer so builds are instant.
      # Runs once per install, gated by /var/lib/hydrix/.firstboot-vms-done.
      {
        hydrix-firstboot-vms = {
          description = "Build and start microVMs on first boot";
          wantedBy = [ "multi-user.target" ];
          after = [ "nix-daemon.socket" "local-fs.target" ];

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
            echo "First boot: building and starting microVMs..."

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: vmCfg: ''
              # Build and link if runner symlink doesn't exist yet
              if [ ! -e "/var/lib/microvms/${name}/current/bin/microvm-run" ]; then
                echo "Building ${name}..."
                out_link="/tmp/firstboot-${name}"
                if nix build "path:${configDir}#nixosConfigurations.${name}.config.microvm.declaredRunner" \
                    -o "$out_link" --print-build-logs 2>&1; then
                  # Create symlink (same as microvm build CLI)
                  store_path=$(readlink -f "$out_link")
                  mkdir -p "/var/lib/microvms/${name}/config"
                  chown microvm:kvm "/var/lib/microvms/${name}"
                  chown root:root "/var/lib/microvms/${name}/config"
                  chmod 755 "/var/lib/microvms/${name}" "/var/lib/microvms/${name}/config"
                  ln -sfn "$store_path" "/var/lib/microvms/${name}/current"
                  rm -f "$out_link"
                  echo "${name} built and linked: $store_path"
                else
                  echo "WARN: ${name} build failed"
                fi
              fi

              ${lib.optionalString vmCfg.autostart ''
              # Start if autostart and runner exists
              if [ -e "/var/lib/microvms/${name}/current/bin/microvm-run" ]; then
                if ! systemctl is-active --quiet "microvm@${name}.service"; then
                  echo "Starting ${name}..."
                  systemctl reset-failed "microvm@${name}.service" 2>/dev/null || true
                  systemctl start "microvm@${name}.service" || echo "WARN: ${name} start failed"
                fi
              fi
              ''}
            '') enabledVMs)}

            mkdir -p /var/lib/hydrix
            touch /var/lib/hydrix/.firstboot-vms-done
            echo "First-boot VM setup complete"
          '';
        };
      }
    ];
  })
  ];
}
