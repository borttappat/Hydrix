# MicroVM Builder Module - Builds packages and populates host's nix store
#
# This VM is designed for lockdown mode where the host has no internet.
# It gets internet through the router VM and writes directly to the host's
# /nix/store via virtiofs, allowing rebuilds without host internet access.
#
# Usage:
#   1. Enable in user's machine config:
#      hydrix.microvmHost.vms.microvm-builder.enable = true;
#   2. Rebuild host: hydrix-switch
#   3. Build the builder VM: shard build microvm-builder
#   4. Use the builder: builder start && builder build <flake> && builder stop
#
# Architecture:
#   - Builder gets R/W virtiofs mounts to /nix/store and /nix/var/nix
#   - Host nix-daemon MUST be stopped while builder runs (SQLite locking)
#   - Builder runs its own nix-daemon that writes to host's store
#   - After builder stops, host restarts its daemon and sees all new packages
#
# Security:
#   - Builder is on isolated br-builder bridge (no direct VM-to-VM access)
#   - Only communicates with: router (internet) and host (vsock + virtiofs)
#   - Host controls builder via vsock (ports 14510/14511)
#
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  # Host username for mounting hydrix-config (passed from mkMicrovmBuilder)
  hostUsername = config.hydrix.builder.hostUsername;
  vmName = config.networking.hostName;
  tier = config.hydrix.builder.storeTier;
  tierMode = tier != null;
  # A tier builder's own store: a copy of its closure from the host store (shard
  # builder_view_sync), never the whole host store.
  ownStoreView = "/var/lib/hydrix/stores/views/${vmName}/nix/store";
in {
  imports = [
    # The host cache is unsigned now (read with ?trusted=1, see nix.settings below)
    (lib.mkRemovedOptionModule ["hydrix" "builder" "hostCachePublicKey"] ''
      The host cache is no longer signed: a tier builder reads it read-only and trusted
      (file:///mnt/cache-host?trusted=1). Remove the setting; no key is needed.
    '')
    ../../options.nix
    # QEMU Guest profile for virtio modules
    (modulesPath + "/profiles/qemu-guest.nix")
    # Live NixOS switch via vsock:14504 (shard switch)
    ./vm-switch.nix
    # Serial console follows the attached terminal's size
    ../../common/serial-console.nix
  ];

  # Builder-specific options
  options.hydrix.builder = {
    hostUsername = lib.mkOption {
      type = lib.types.str;
      description = "Username on the host machine (for mounting ~/hydrix-config)";
    };
    localInputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["/home/user/Hydrix"];
      description = ''
        Absolute host paths of local flake inputs (path: or git+file:), shared
        read-only at the same path so the flake at /mnt/hydrix resolves them
        exactly as the host does. Every listed path must exist on the host.
      '';
    };
    storeTier = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "profile";
      description = ''
        Build into a tier store instead of the host store. The builder then sees a copy of
        its own closure from the host store, read-only (shard builder_view_sync, at
        /var/lib/hydrix/stores/views/<builder>), builds into the host directory
        /var/lib/hydrix/stores/<tier> (a chroot store at /mnt/store) and never needs the
        host nix-daemon stopped. VMs read the tier store through hydrix.microvm.storeSource.
      '';
    };
    tapId = lib.mkOption {
      type = lib.types.str;
      default = "mv-builder";
      description = "TAP interface (max 15 chars; mv-build* attaches to br-builder).";
    };
    tapMac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:02:10:01";
      description = "MAC address of the TAP interface, unique per builder.";
    };
  };

  # Builder uses "builder" username by default
  config = {
    # Set builder-specific defaults
    hydrix.username = lib.mkDefault "builder";
    # ===== Basic Identity =====
    networking.hostName = lib.mkDefault "microvm-builder";
    system.stateVersion = "25.05";
    nixpkgs.config.allowUnfree = true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== MicroVM Configuration =====
    microvm = {
      hypervisor = "qemu";
      # Verified working on gitsync/router-stable before promoting here.
      qemu.machine = "microvm";
      # microvm.nix's own qemu.serialConsole (default true) unconditionally
      # adds its own "-serial chardev:stdio" on top of the console.sock one
      # below - two legacy serial ports, only "pc" tolerated that cleanly.
      # Only ever needed the one console.sock port to begin with.
      qemu.serialConsole = false;

      # High resources for builds - override in infra/builder/default.nix
      vcpu = lib.mkDefault 8;
      mem = lib.mkDefault 16384; # 16GB for large builds

      # No squashfs store - we mount host's store directly
      storeDiskType = "none";

      # Disable virtiofsd sandbox to allow writes to /nix/store
      # Builder needs direct R/W access to host's nix store
      virtiofsd.extraArgs = lib.mkDefault ["--sandbox" "none" "--cache" "always" "--thread-pool-size" "16"];

      # Headless operation
      graphics.enable = false;
      qemu.extraArgs = [
        "-vga"
        "none"
        "-display"
        "none"
        # Serial console via unix socket for interactive access
        # Connect with: shard console microvm-builder
        "-chardev"
        "socket,id=console,path=/var/lib/microvms/${vmName}/console.sock,server=on,wait=off"
        "-serial"
        "chardev:console"
      ];

      # Tier builder: own system from its store view (read-only), overlay upper on tmpfs
      writableStoreOverlay = lib.mkIf tierMode "/nix/.rw-store";
      # microvm.nix takes only a share from "/nix/store" for the store; the view is not one.
      storeOnDisk = lib.mkIf tierMode (lib.mkForce false);

      # ===== Shared Filesystems =====
      # Host store mode: R/W mounts of the host's actual nix store; the host
      # nix-daemon MUST be stopped while the builder is running.
      shares =
        (
          if tierMode
          then
            [
              {
                tag = "host-nix-store";
                source = ownStoreView;
                mountPoint = "/nix/.ro-store";
                proto = "virtiofs";
                readOnly = true;
              }
              # Chroot store: /mnt/store/nix/{store,var/nix}
              {
                tag = "tier-store";
                source = "/var/lib/hydrix/stores/${tier}";
                mountPoint = "/mnt/store";
                proto = "virtiofs";
                extraArgs = config.hydrix.microvm.writableShareArgs;
              }
            ]
            # The host's cache (shard cache export), read-only: caches only flow down
            ++ [
              {
                tag = "host-cache";
                source = "/var/lib/hydrix/caches/host";
                mountPoint = "/mnt/cache-host";
                proto = "virtiofs";
                readOnly = true;
              }
            ]
          else [
            # Host /nix/store - R/W access for building
            {
              tag = "host-nix-store";
              source = "/nix/store";
              mountPoint = "/nix/store";
              proto = "virtiofs";
              extraArgs = config.hydrix.microvm.writableShareArgs;
            }
            # Host /nix/var/nix - R/W access for nix database
            {
              tag = "host-nix-var";
              source = "/nix/var/nix";
              mountPoint = "/nix/var/nix";
              proto = "virtiofs";
              extraArgs = config.hydrix.microvm.writableShareArgs;
            }
          ]
        )
        # User's hydrix-config - READ-ONLY for security
        # Builder can evaluate flakes but cannot modify source code
        # Uses hostUsername passed from mkMicrovmBuilder
        # A tier builder gets neither: the host evaluates and exports the derivations, so
        # the config never reaches a tier store (BUILDDRV below).
        ++ lib.optionals (!tierMode) ([
            {
              tag = "hydrix-config";
              source = "/home/${hostUsername}/hydrix-config";
              mountPoint = "/mnt/hydrix";
              proto = "virtiofs";
              readOnly = true;
            }
          ]
          ++ map (path: {
            tag = "input-${baseNameOf path}";
            source = path;
            mountPoint = path;
            proto = "virtiofs";
            readOnly = true;
          })
          config.hydrix.builder.localInputs);

      # ===== EXCEPTION: intentional persistent volume =====
      # Everything else about this VM is ephemeral (tmpfs root; host /nix/store
      # and /nix/var/nix are mounted directly, not copied - nothing built here
      # needs its own cache since it's already the host's actual store). This
      # eval-cache volume is kept persistent on purpose: pure performance
      # (avoids 2+ min cold eval per builder start), zero secrets/security
      # sensitivity.
      volumes = [
        {
          image = "builder-cache.img";
          mountPoint = "/root/.cache/nix";
          size = 8192; # 8GB for eval cache + narinfo cache
          fsType = "ext4";
          autoCreate = true;
        }
      ];

      # ===== Network Interface =====
      interfaces = [
        {
          type = "tap";
          id = config.hydrix.builder.tapId;
          mac = config.hydrix.builder.tapMac;
        }
      ];

      # ===== Vsock for host communication =====
      # lib.mkDefault: user can override via infra/builder/default.nix
      vsock.cid = lib.mkDefault 210;
    };

    # ===== Nix Configuration =====
    # Builder runs its own nix-daemon that writes to host's store
    nix = {
      enable = true;
      settings = {
        # root only: the build service runs as root; the console user (builder)
        # can build but cannot pass options such as --option sandbox false.
        trusted-users = lib.mkDefault ["root"];
        auto-optimise-store = lib.mkDefault false; # Host manages optimization
        max-jobs = lib.mkDefault "auto";
        cores = lib.mkDefault 0; # Use all available
        # Every build runs sandboxed: only its declared inputs, no network
        # (except fixed-output fetches), no view of /mnt/hydrix or other builds.
        # This VM holds the host store read-write, so a build that reached root
        # here would reach the host.
        sandbox = lib.mkDefault true;
        sandbox-fallback = false;
        # Enable flakes and nix-command
        experimental-features = lib.mkDefault ["nix-command" "flakes"];
        # Use substituters for faster builds
        substituters = lib.mkDefault [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ];
        # Cache negative narinfo results permanently (reduces redundant DB lookups)
        narinfo-cache-negative-ttl = lib.mkDefault 0;
        # Parallel substituter downloads
        http-connections = lib.mkDefault 128;
        max-substitution-jobs = lib.mkDefault 32;
        trusted-public-keys = lib.mkDefault [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
        # The host cache, unsigned and trusted: only host root writes it, and it reaches
        # this VM through a read-only share enforced on the host. A signature would add
        # nothing here (its key would sit next to the cache) and cost a key per machine.
        # cache.nixos.org keeps requiring its signature.
        extra-substituters = lib.optional tierMode "file:///mnt/cache-host?trusted=1";
      };
      # Don't run GC in builder - host manages GC
      gc.automatic = lib.mkDefault false;
    };

    # Increase file descriptor limits for nix builds
    # Nix builds can open thousands of files simultaneously
    systemd.services.nix-daemon.serviceConfig = {
      LimitNOFILE = 1048576;
    };

    # Explicitly enable nix-daemon socket and service
    # (microvm module may disable it when detecting shared store)
    systemd.sockets.nix-daemon = {
      enable = true;
      wantedBy = ["sockets.target"];
    };
    systemd.services.nix-daemon = {
      enable = true;
    };

    # ===== Local Socket Directory =====
    # /nix/var/nix is mounted via virtiofs from host, but Unix domain sockets
    # don't work over virtiofs (they're kernel objects, not files).
    # Mount a local tmpfs over the daemon-socket directory so the socket works.
    fileSystems."/nix/var/nix/daemon-socket" = lib.mkIf (!tierMode) {
      device = "tmpfs";
      fsType = "tmpfs";
      options = ["mode=0755"];
    };

    # Tier builder: the overlay's lower is its store view (see storeOnDisk above).
    fileSystems."/nix/.ro-store" = lib.mkIf tierMode {neededForBoot = true;};
    fileSystems."/nix/store" = lib.mkIf tierMode {overlay.lowerdir = lib.mkForce ["/nix/.ro-store"];};

    # ===== Writable Nix Store =====
    # By default NixOS remounts /nix/store as read-only for security
    # Builder needs write access to populate host's store
    boot.nixStoreMountOpts = lib.mkIf (!tierMode) ["rw" "relatime"];

    # ===== Kernel Configuration =====
    boot.initrd.availableKernelModules = [
      "virtio_balloon"
      "virtio_blk"
      "virtio_pci"
      "virtio_ring"
      "virtio_net"
      "virtio_scsi"
      "virtio_mmio"
      "9p"
      "9pnet"
      "9pnet_virtio"
    ];

    boot.kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "random.trust_cpu=on"
    ];

    boot.kernelModules = [
      "virtio_blk"
      "virtio_pci"
      "virtio_rng"
      "vmw_vsock_virtio_transport" # vsock for host communication
    ];

    # ===== Networking =====
    # Simple DHCP - gets IP from router via br-builder
    # network-online.target waits for a DHCP lease (microvm.nix's optimize turns this off);
    # the vsock servers order after it. 30s keeps it under the host's readiness timeout.
    systemd.network.wait-online = {
      enable = true;
      timeout = 30;
    };
    networking = {
      useDHCP = true;
      enableIPv6 = false;
      networkmanager.enable = false;
      firewall.enable = false; # Builder doesn't need firewall
    };

    # ===== Services =====
    services.openssh.enable = lib.mkDefault false; # No SSH - vsock only
    services.qemuGuest.enable = lib.mkDefault true;
    services.getty.autologinUser = lib.mkDefault "builder";
    services.haveged.enable = lib.mkDefault true;

    # ===== User Configuration =====
    users.users.builder = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      password = "builder"; # Simple password for console access
    };
    security.sudo.wheelNeedsPassword = false;

    # ===== Packages =====
    environment.systemPackages = lib.mkDefault (with pkgs; [
      git
      vim
      htop
      socat
      # Nix tools
      nix-tree
      nix-diff
    ]);

    # ===== Git Configuration =====
    # Trust the mounted repos despite different ownership (virtiofs UID mapping)
    # mkIf on the whole entry: on .text alone, a tier builder would get an empty gitconfig entry.
    environment.etc."gitconfig" = lib.mkIf (!tierMode) {
      text = ''
        [safe]
          directory = /mnt/hydrix
        ${lib.concatMapStrings (path: "  directory = ${path}\n") config.hydrix.builder.localInputs}'';
    };

    # ===== Read-Only Mounts for Security =====
    # Builder can evaluate flakes but cannot modify source code
    fileSystems."/mnt/hydrix" = lib.mkIf (!tierMode) {options = lib.mkAfter ["ro"];};

    # ===== Vsock Build Server =====
    # Listens on port 14510 for build commands from host
    systemd.services.builder-vsock = {
      description = "Builder vsock server for host commands";
      wantedBy = ["multi-user.target"];
      # Nix checks for network once per run and disables downloads without it, so the
      # build server (and the PING gate below) only start once DHCP has an address.
      after = ["network-online.target" "nix-daemon.service"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          buildServer = pkgs.writeShellScript "builder-vsock-server" ''
            # Build server - receives commands from host via vsock
            # -t600: wait up to 600s for handler output after client closes write direction
            # Without this, default -t0.5 kills the handler 0.5s after client sends EOF
            while true; do
              ${pkgs.socat}/bin/socat -t600 VSOCK-LISTEN:14510,reuseaddr,fork EXEC:"${buildHandler}"
            done
          '';
          buildHandler = pkgs.writeShellScript "builder-vsock-handler" ''
            # Ensure PATH includes required tools (socat EXEC has minimal environment)
            export PATH="${pkgs.coreutils}/bin:${pkgs.glibc.bin}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:$PATH"

            # Read command line
            read -r cmd rest

            case "$cmd" in
              BUILD)
                ${
              if tierMode
              then ''
                # The host evaluates for a tier builder: this VM has no flake to evaluate.
                echo "ERROR a tier builder builds exported derivations only: BUILDDRV <name> <drv>"
              ''
              else ''
                flake="$rest"
                echo "OK building $flake"

                # Brief pause for network stack, then let nix handle retries
                sleep 2

                # Run nix build - stream progress to vsock for the host to render with nom.
                # --log-format internal-json -v: what nom --json parses (as nh uses it).
                # 2>&1: merge stderr (nix progress) into stdout so socat carries it all.
                if ${pkgs.nix}/bin/nix build "$flake" --no-link --no-write-lock-file \
                     --log-format internal-json -v 2>&1; then
                  echo "DONE"
                else
                  echo "ERROR build failed"
                fi
              ''
            }
                ;;

              ${lib.optionalString tierMode ''
              BUILDDRV)
                # BUILDDRV <name> <drv>: the host evaluated <name> and exported <drv> with its
                # recipe closure to the host cache. Copy the recipes into the tier store, build
                # them, and keep the result as GC root <name> in the tier store.
                read -r name drv <<< "$rest"
                if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ || ! "$drv" =~ ^/nix/store/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+\.drv$ ]]; then
                  echo "ERROR usage: BUILDDRV <name> </nix/store/...drv>"
                  exit 0
                fi
                echo "OK building $drv"
                sleep 2
                mkdir -p /mnt/store/nix/var/nix/gcroots/hydrix
                # The recipe copy logs one line per path (over 11k into an empty store): keep it
                # out of the stream, report the count, and show its end only if it fails.
                echo "Copying the build recipes from the host cache"
                copylog=$(mktemp)
                if ! ${pkgs.nix}/bin/nix copy --derivation --from 'file:///mnt/cache-host?trusted=1' --to /mnt/store "$drv" \
                     > "$copylog" 2>&1; then
                  tail -n 20 "$copylog"
                  rm -f "$copylog"
                  echo "ERROR copying the build recipes failed"
                else
                  copied=$(grep -o 'copying [0-9]* paths' "$copylog" | head -n 1)
                  rm -f "$copylog"
                  echo "Build recipes: ''${copied:-all already in the tier store}"
                  if ${pkgs.nix}/bin/nix build --store /mnt/store "$drv^*" \
                       --out-link "/mnt/store/nix/var/nix/gcroots/hydrix/$name" \
                       --log-format internal-json -v 2>&1; then
                    echo "DONE"
                  else
                    echo "ERROR build failed"
                  fi
                fi
                ;;

              GC)
                # Garbage collection in the tier store. Its roots are this builder's out-links
                # and the host's generation roots (gcroots/hydrix/<vm>-gen<N>, shard -g), so
                # only builds no generation holds go. VM views are hardlinks: they keep theirs.
                echo "OK collecting garbage in the tier store"
                gclog=$(mktemp)
                if ${pkgs.nix}/bin/nix-store --store /mnt/store --gc > "$gclog" 2>&1; then
                  tail -n 1 "$gclog"
                  echo "DONE"
                else
                  tail -n 20 "$gclog"
                  echo "ERROR garbage collection failed"
                fi
                rm -f "$gclog"
                ;;
            ''}
              PREFETCH)
                flake="$rest"
                echo "OK prefetching $flake"

                # Fetch all dependencies without building.
                # --log-format raw: plain streaming output, no ANSI.
                if ${pkgs.nix}/bin/nix flake prefetch "$flake" --no-write-lock-file \
                     --log-format raw 2>&1; then
                  echo "DONE prefetch complete"
                else
                  echo "ERROR prefetch failed"
                fi
                ;;

              ${lib.optionalString (!tierMode) ''
              UPDATE)
                # UPDATE [input ...]: lock the flake at /mnt/hydrix anew (every input, or the
                # named ones). /mnt/hydrix is read-only here: the new lock goes into the store
                # (shared with the host) and its path is sent back, and the host checks and
                # writes it. The fetched sources land in the host store and database too, so
                # the host evaluates offline.
                if [[ -n "$rest" && ! "$rest" =~ ^[A-Za-z0-9_-]+( [A-Za-z0-9_-]+)*$ ]]; then
                  echo "ERROR usage: UPDATE [input ...]"
                  exit 0
                fi
                echo "OK updating ''${rest:-every input}"
                lockdir=$(mktemp -d)
                # $rest unquoted: one argument per input name (checked above)
                # shellcheck disable=SC2086
                if ${pkgs.nix}/bin/nix flake update $rest --flake /mnt/hydrix \
                     --output-lock-file "$lockdir/flake.lock" --log-format internal-json -v 2>&1; then
                  if [[ -s "$lockdir/flake.lock" ]]; then
                    echo "LOCK $(${pkgs.nix}/bin/nix store add --mode flat --name flake.lock "$lockdir/flake.lock")"
                  else
                    echo "UNCHANGED"
                  fi
                  echo "DONE"
                else
                  echo "ERROR flake update failed"
                fi
                rm -rf "$lockdir"
                ;;
              FETCH)
                # FETCH <kind>=<ref> ...: sources the host's profiles pin by narHash but fetch
                # only during evaluation (builtins.getFlake, builtins.fetchTree), so no lock
                # file lists them (flake-input-roots.py --list-fetch). Each goes into the store
                # shared with the host, which then evaluates those profiles offline: a pinned
                # flake with every input of its own lock (nix flake archive), anything else as
                # a source tree (nix flake prefetch). github refs with a full rev only.
                if [[ -z "$rest" ]]; then
                  echo "ERROR usage: FETCH flake=<ref>|tree=<ref> ..."
                  exit 0
                fi
                failed=0
                # $rest unquoted: one argument per ref (each checked below)
                # shellcheck disable=SC2086
                for item in $rest; do
                  if [[ ! "$item" =~ ^(flake|tree)=github:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/[0-9a-f]{40}\?narHash=sha256-[A-Za-z0-9%]+$ ]]; then
                    echo "ERROR not a pinned github source: $item"
                    failed=1
                    continue
                  fi
                  kind=''${item%%=*}
                  ref=''${item#*=}
                  echo "OK fetching $ref"
                  if [[ "$kind" == flake ]]; then
                    ${pkgs.nix}/bin/nix flake archive "$ref" --log-format internal-json -v 2>&1 || failed=1
                  else
                    ${pkgs.nix}/bin/nix flake prefetch "$ref" --log-format internal-json -v 2>&1 || failed=1
                  fi
                done
                if [[ $failed -eq 0 ]]; then
                  echo "DONE"
                else
                  echo "ERROR fetching pinned sources failed"
                fi
                ;;
            ''}
              PING)
                echo "PONG"
                ;;

              *)
                echo "ERROR unknown command: $cmd"
                echo "Commands: ${
              if tierMode
              then "BUILDDRV <name> <drv>, GC"
              else "BUILD <flake>, PREFETCH <flake>, UPDATE [input ...], FETCH <kind>=<ref> ..."
            }, PING"
                ;;
            esac
          '';
        in
          buildServer;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== Vsock Status Server =====
    # Listens on port 14511 for status queries. The host's readiness gate (PING), so it
    # waits for the network like the build server.
    systemd.services.builder-status = {
      description = "Builder status server";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          statusServer = pkgs.writeShellScript "builder-status-server" ''
            while true; do
              ${pkgs.socat}/bin/socat VSOCK-LISTEN:14511,reuseaddr,fork EXEC:"${statusHandler}"
            done
          '';
          statusHandler = pkgs.writeShellScript "builder-status-handler" ''
            read -r cmd

            case "$cmd" in
              STATUS)
                # Check if any nix-build processes are running
                if pgrep -x "nix" > /dev/null || pgrep -x "nix-build" > /dev/null; then
                  # Try to get what's being built
                  building=$(ps aux | grep -E "nix (build|flake)" | grep -v grep | head -1 | sed 's/.*nix /nix /' | cut -c1-60)
                  echo "BUILDING $building"
                else
                  echo "IDLE"
                fi
                ;;

              PING)
                echo "PONG"
                ;;

              *)
                echo "IDLE"
                ;;
            esac
          '';
        in
          statusServer;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== Tmpfiles =====
    systemd.tmpfiles.rules = [
      "d /tmp/builds 1777 root root -"
    ];

    # ===== Locale =====
    # Inherited from shared/common.nix passed via mkMicrovmBuilder modules argument
    # (ensures timezone and keymap match the host for interactive shell access)

    # ===== MOTD =====
    users.motd = ''

      +-------------------------------------------------+
      |  HYDRIX BUILDER VM                              |
      +-------------------------------------------------+
      |  This VM builds packages for the host's store   |
      |  Host nix-daemon is STOPPED while this runs     |
      |                                                 |
      |  Commands from host (via vsock):                |
      |    builder build <flake>  - Build a flake       |
      |    builder status         - Check status        |
      |    builder stop           - Stop builder VM     |
      +-------------------------------------------------+

    '';

    # ===== Startup Banner =====
    systemd.services.builder-banner = {
      description = "Display builder status";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo ""
        echo "Builder VM started"
        echo "  vsock CID: ${toString config.microvm.vsock.cid}"
        echo "  Build port: 14510"
        echo "  Status port: 14511"
        echo ""
        echo "${
          if tierMode
          then "Building into the ${tier} tier store (/mnt/store)"
          else "Nix store mounted from host (R/W)"
        }"
        echo "Ready for build commands"
      '';
    };
  };
}
