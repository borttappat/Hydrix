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

  # VMs built/declared during a fresh install (infrastructureOnly=true)
  infrastructureVMs = [ "microvm-router" "microvm-router-stable" "microvm-builder" ];

  # Merge: knownVms auto-enabled with defaults; explicit cfg.vms entries override.
  allVms =
    (lib.genAttrs cfg.knownVms (_: { enable = true; autostart = false; secrets = []; }))
    // cfg.vms;

  # Enabled VMs, optionally filtered to infrastructure-only during first install
  enabledVMs = lib.filterAttrs (_: v: v.enable) allVms;
  filteredVMs = if cfg.infrastructureOnly
    then lib.filterAttrs (name: _: builtins.elem name infrastructureVMs) enabledVMs
    else enabledVMs;

  # Filter VMs that have any secrets to provision
  vmsWithSecrets = lib.filterAttrs (_: v: v.enable && v.secrets != []) allVms;

  # Check if router microVM is enabled
  routerEnabled =
    (allVms ? "microvm-router" && allVms."microvm-router".enable);

  stableRouterEnabled =
    (allVms ? "microvm-router-stable" && allVms."microvm-router-stable".enable);

  # Stable router TAP → bridge mapping.
  # Derived from profileNetworks (uses vmRegistry for correct bridge names)
  # and extraNetworks (custom profiles + non-builtin infra VMs like files).
  # Only mv-rts-bldr is hardcoded: builder is a builtinVm not in either list.
  stableTaps =
    { "mv-rts-bldr" = "br-builder"; }
    // lib.listToAttrs (map (pn: {
      name  = if lib.hasPrefix "mv-router-" pn.routerTap
              then "mv-rts-" + lib.removePrefix "mv-router-" pn.routerTap
              else "mv-rts-${pn.name}";
      value = (config.hydrix.networking.vmRegistry.${pn.name} or {}).bridge
              or "br-${pn.name}";
    }) config.hydrix.networking.profileNetworks)
    // lib.listToAttrs (map (n: {
      name  = if lib.hasPrefix "mv-router-" n.routerTap
              then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
              else "mv-rts-${n.name}";
      value = "br-${n.name}";
    }) config.hydrix.networking.extraNetworks);

  # Router TAP interface to bridge mapping
  # TAP names must be max 15 chars (Linux limit)
  # Framework infrastructure TAPs are hardcoded; profile TAPs are generated
  # from config.hydrix.networking.profileNetworks (populated by flake.nix from
  # profiles/*/meta.nix) so new profiles are covered without editing this file.
  routerTaps =
    # Infrastructure TAPs — always present, not user-configurable
    {
      "mv-router-mgmt" = "br-mgmt";
      "mv-router-bldr" = "br-builder";
    }
    # Profile TAPs — generated from discovered profileNetworks.
    # profileNetworks has { name, subnet, routerTap } for every profile.
    # The bridge comes from vmRegistry[name].bridge when available;
    # falls back to "br-<name>" for robustness during initial bootstrap.
    // lib.listToAttrs (map (pn: {
      name  = pn.routerTap;
      value = (config.hydrix.networking.vmRegistry.${pn.name} or {}).bridge
              or "br-${pn.name}";
    }) config.hydrix.networking.profileNetworks)
    # Extra user-defined networks (custom profiles not in the framework 5)
    // lib.listToAttrs (map (n: {
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

    # Exit early if already attached to the correct bridge —
    # ip link set master fails with EBUSY on already-attached TAPs,
    # which would cause the retry loop to spin for 15s per TAP.
    current_master=$(${pkgs.iproute2}/bin/ip -o link show "$TAP" 2>/dev/null \
      | sed -n 's/.* master \([^ \\]*\).*/\1/p')
    [ "$current_master" = "$BRIDGE" ] && exit 0

    # Wait for bridge to exist
    for i in $(seq 1 $MAX_RETRIES); do
      if ${pkgs.iproute2}/bin/ip link show "$BRIDGE" &>/dev/null; then
        # Bridge exists, attach TAP and bring it up
        if ${pkgs.iproute2}/bin/ip link set "$TAP" master "$BRIDGE" 2>/dev/null; then
          ${pkgs.iproute2}/bin/ip link set "$TAP" up 2>/dev/null || true
          exit 0
        fi
      fi
      sleep $RETRY_DELAY
    done

    # Log failure (visible in journalctl)
    echo "Failed to attach $TAP to $BRIDGE after $MAX_RETRIES retries" >&2
    exit 1
  '';

  # Lookup the correct bridge for any mv-* TAP.
  # Generated at build time from all known mappings — exact matches first, then globs.
  # Returns empty string for unknown TAPs (no assignment).
  tapLookupScript = pkgs.writeShellScript "tap-bridge-lookup" ''
    case "$1" in
      # --- Framework infrastructure router TAPs (hardcoded, not user-configurable) ---
      mv-router-wan)  echo "br-wan" ;;
      mv-router-mgmt) echo "br-mgmt" ;;
      mv-router-bldr) echo "br-builder" ;;
      mv-rts-bldr)    echo "br-builder" ;;
      # Stable-router management TAP
      mv-rts-mgmt) echo "br-mgmt" ;;
      # --- Profile router TAPs — generated from profileNetworks ---
      # Each entry covers both the primary router (mv-router-*) and the
      # stable-router counterpart (mv-rts-*).
      ${lib.concatMapStrings (pn: let
        bridge = (config.hydrix.networking.vmRegistry.${pn.name} or {}).bridge
                 or "br-${pn.name}";
        sTap = if lib.hasPrefix "mv-router-" pn.routerTap
               then "mv-rts-" + lib.removePrefix "mv-router-" pn.routerTap
               else "mv-rts-${pn.name}";
      in ''
      ${pn.routerTap}) echo "${bridge}" ;;
      ${sTap}) echo "${bridge}" ;;
      '') config.hydrix.networking.profileNetworks}
      # --- Extra user-defined network router TAPs ---
      ${lib.concatMapStrings (n: let
        sTap = if lib.hasPrefix "mv-router-" n.routerTap
               then "mv-rts-" + lib.removePrefix "mv-router-" n.routerTap
               else "mv-rts-${n.name}";
      in ''
      ${n.routerTap}) echo "br-${n.name}" ;;
      ${sTap}) echo "br-${n.name}" ;;
      '') config.hydrix.networking.extraNetworks}
      # --- Infra VM TAPs (exact matches from tapBridges in meta.nix) ---
      ${lib.concatStringsSep "\n      " (lib.mapAttrsToList (tap: bridge:
        "${tap}) echo \"${bridge}\" ;;") infraTapBridges)}
      # --- Profile VM TAPs (glob patterns, covers tapId + per-task TAPs) ---
      # Derives the TAP prefix from the bridge name: "br-browse" → "mv-browse*".
      # This matches the tapId convention (tapId = "mv-<bridgeSuffix>") used by
      # both framework profiles and user-defined profiles, without needing tapId
      # to be exposed in profileNetworks or vmRegistry.
      ${lib.concatMapStrings (pn: let
        bridge = (config.hydrix.networking.vmRegistry.${pn.name} or {}).bridge
                 or "br-${pn.name}";
        tapPrefix = "mv-" + lib.removePrefix "br-" bridge;
      in ''
      ${tapPrefix}*) echo "${bridge}" ;;
      '') config.hydrix.networking.profileNetworks}
      # --- Extra network VM TAPs (glob patterns) ---
      ${lib.concatMapStrings (n:
        "mv-${n.name}*) echo \"br-${n.name}\" ;;\n      "
      ) config.hydrix.networking.extraNetworks}
      # --- Legacy/fixed infra globs ---
      mv-build*)   echo "br-builder" ;;
      mv-gitsyn*)  echo "br-builder" ;;
      mv-task-*)   echo "br-pentest" ;;
    esac
  '';

  # Assign a single TAP to its looked-up bridge (with retry on bridge not-yet-up)
  tapAssignScript = pkgs.writeShellScript "tap-assign" ''
    TAP="$1"
    BRIDGE=$(${tapLookupScript} "$TAP")
    [ -z "$BRIDGE" ] && exit 0
    ${attachTapScript} "$TAP" "$BRIDGE"
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
      # Stable router: always declared, never autostarts — manual "break glass" fallback only
      hydrix.microvmHost.vms."microvm-router-stable" = {
        enable = lib.mkDefault true;
        autostart = lib.mkDefault false;
      };
    })

    (lib.mkIf cfg.enable {
    # DON'T enable systemd-networkd - Hydrix uses NetworkManager
    # Instead, use a udev rule to attach TAP interfaces to bridges

    # Single catch-all udev rule: assign every mv-* TAP to its bridge at creation time.
    # tapAssignScript looks up the correct bridge from tapLookupScript (generated at build
    # time from all known router/infra/profile/extra-network mappings) and attaches with
    # retry. Covers new profiles automatically — no per-interface rules to maintain.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="net", KERNEL=="mv-*", RUN+="${tapAssignScript} %k"
      SUBSYSTEM=="vfio", MODE="0666"
    '';

    # Trust microVM TAP interfaces in firewall
    networking.firewall.trustedInterfaces = [ "mv-+" ];

    # VM registry: written at activation, read by scripts/polybar at runtime
    # Populated by flake.nix from discovered profile meta.nix files
    environment.etc."hydrix/vm-registry.json" = let
      combined = config.hydrix.networking.vmRegistry
              // config.hydrix.networking.infraVmRegistry;
    in lib.mkIf (combined != {}) {
      text = builtins.toJSON combined;
      mode = "0644";
    };

    # vsock port assignments — scripts read from here instead of hardcoding
    environment.etc."hydrix/ports.json" = {
      text = builtins.toJSON config.hydrix.networking.vsockPorts;
      mode = "0644";
    };

    # Host network config — scripts read from here instead of hardcoding
    environment.etc."hydrix/host-config.json" = {
      text = builtins.toJSON {
        hostIp     = config.hydrix.networking.hostIp;
        hostPrefix = 24;
      };
      mode = "0644";
    };

    # Ensure virtiofsd is available
    # Install custom microvm script with high priority to override upstream
    environment.systemPackages = [
      pkgs.virtiofsd
      pkgs.socat    # For microvm-router console access
      pkgs.openssl  # For microvm files passphrase generation
      # TAP→bridge lookup — wraps the build-time generated tapLookupScript so it
      # is on PATH. Dynamic: covers router, infra, profile, and extra-network TAPs.
      # Used by hydrix-switch for post-mode-switch TAP reattachment.
      (pkgs.writeShellScriptBin "microvm-tap-lookup" "exec ${tapLookupScript} \"$@\"")
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

    # Reattach existing mv-* TAPs to their correct bridges after every rebuild.
    # The udev rule only fires on TAP creation — VMs that were already running
    # during a host rebuild keep their old (possibly wrong) bridge assignment.
    # This activation script re-runs tapAssignScript for every live mv-* interface
    # so TAP→bridge mapping stays correct without restarting VMs.
    system.activationScripts.retapBridges = lib.stringAfter [ "specialfs" ] ''
      ${pkgs.iproute2}/bin/ip -o link show 2>/dev/null \
        | while read -r _idx name _rest; do
            name="''${name%%@*}"
            name="''${name%%:*}"
            case "$name" in
              mv-*) ${tapAssignScript} "$name" 2>/dev/null || true ;;
            esac
          done
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
    # hostsync virtiofs source — virtiofsd crashes if source path is missing at start.
    # Create unconditionally when hostsync VM is enabled so first boot always works.
    ++ lib.optionals (cfg.vms ? "microvm-hostsync" && cfg.vms."microvm-hostsync".enable) [
      "d /home/${username}/vm-inbox 0755 ${username} users -"
    ]
    # NOTE: Do NOT create /var/lib/microvms/<name> or subdirectories via tmpfiles.
    # The upstream microvm.nix install-microvm-<name> service uses
    # ConditionPathExists=!/var/lib/microvms/<name> to gate first-install
    # symlink creation. Pre-creating the directory (even implicitly via a
    # subdirectory) causes the condition to always fail, preventing the runner
    # symlink from being created on first boot.
    # The config subdirectory is created by hydrix-microvm-config-dirs below.
    # Pre-create secrets source dirs for all enabled VMs.
    # virtiofsd crashes if the source path is missing at start — pre-creating
    # for all enabled VMs means the share is always safe to add when secrets != [].
    ++ (lib.mapAttrsToList (name: _: "d /run/hydrix-secrets/${name}/ssh 0700 root root -")
      (lib.filterAttrs (_: v: v.enable) cfg.vms))
    # Create /run/secrets/github so the provisioning service always has a valid
    # source directory to check, even when sops is not configured.
    ++ lib.optionals (vmsWithSecrets != {}) [
      "d /run/secrets/github 0700 root root -"
    ];

    # Declare microVMs from hydrix.microvmHost.vms
    # VM names must match nixosConfigurations in the Hydrix flake
    microvm.vms = lib.mapAttrs (name: vmCfg: {
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
      (lib.mkIf routerEnabled {
        "microvm@microvm-router" = {
          serviceConfig = {
            User = lib.mkForce "root";
            Group = lib.mkForce "root";
          };
        };
      })

      # Stable router: root for VFIO, conflicts with main router (can't share WiFi card).
      # Never auto-starts — launch manually with: microvm start router-stable
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

          script = ''
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

          preStop = ''
            echo "Cleaning up stable router TAP interfaces..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (tap: _: ''
              if ip link show ${tap} &>/dev/null; then
                ip link del ${tap} 2>/dev/null || true
              fi
            '') stableTaps)}
          '';
        };
      })

      # Repair service: re-attach all existing mv-* TAPs to correct bridges.
      # Primary assignment happens via the udev catch-all rule at TAP creation time.
      # This service is a safety net for TAPs that already existed on the wrong bridge
      # (e.g. after a rebuild with VMs still running, or after bridge recreation).
      (lib.mkIf routerEnabled {
        microvm-tap-bridges = {
          description = "Ensure microVM TAP interfaces are attached to bridges";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" "microvm-router-taps.service" "microvm-router-stable-taps.service" ];
          # Re-run on every activation to fix TAPs detached by bridge recreation
          restartIfChanged = true;
          partOf = [ "network.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          script = ''
            echo "Ensuring TAP-to-bridge attachments..."
            for tap in $(${pkgs.iproute2}/bin/ip -o link show 2>/dev/null \
                | grep -oP 'mv-[a-z0-9-]+(?=[@:])' | sort -u); do
              ${tapAssignScript} "$tap" || true
            done
            echo "TAP-to-bridge attachments verified"
          '';
        };
      })

      # Secrets Provisioning for MicroVMs
      # Generated for ALL enabled VMs, not just those with secrets.
      # This guarantees /run/hydrix-secrets/<name>/ssh exists before virtiofsd
      # starts — virtiofsd crashes if its source path is missing and tmpfiles
      # has no strict ordering guarantee relative to virtiofsd.
      # For VMs with secrets: also copies decrypted keys.
      # For VMs without secrets: mkdir only — VM starts cleanly, just no SSH keys.
      # Key copy is guarded per-file, so machines without sops configured are safe.
      (lib.mapAttrs' (name: vmCfg: lib.nameValuePair "hydrix-secrets-${name}" {
        description = "Pre-create secrets dir and provision secrets for microVM ${name}";
        wantedBy = [ "microvm-virtiofsd@${name}.service" "microvm@${name}.service" ];
        before = [ "microvm-virtiofsd@${name}.service" "microvm@${name}.service" ];
        wants = lib.optionals (builtins.elem "github" vmCfg.secrets) [ "hydrix-github-secrets.service" ];
        after = [ "local-fs.target" ]
          ++ lib.optionals (builtins.elem "github" vmCfg.secrets) [ "hydrix-github-secrets.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          SECRETS_DIR="/run/hydrix-secrets/${name}/ssh"

          mkdir -p "$SECRETS_DIR"
          chmod 700 "$SECRETS_DIR"

          ${lib.concatMapStrings (secret:
            if secret == "github" then ''
              GITHUB_SECRETS="/run/secrets/github"
              if [ -f "$GITHUB_SECRETS/id_ed25519" ]; then
                cp "$GITHUB_SECRETS/id_ed25519" "$SECRETS_DIR/"
                chmod 600 "$SECRETS_DIR/id_ed25519"
              else
                echo "Warning: github id_ed25519 not found"
              fi
              if [ -f "$GITHUB_SECRETS/id_ed25519.pub" ]; then
                cp "$GITHUB_SECRETS/id_ed25519.pub" "$SECRETS_DIR/"
                chmod 644 "$SECRETS_DIR/id_ed25519.pub"
              else
                echo "Warning: github id_ed25519.pub not found"
              fi
            ''
            else ''
              echo "Warning: unknown secret type '${secret}' — skipping"
            ''
          ) vmCfg.secrets}

          echo "Secrets dir ready for ${name}"
        '';
      }) enabledVMs)

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
            '') filteredVMs)}

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
