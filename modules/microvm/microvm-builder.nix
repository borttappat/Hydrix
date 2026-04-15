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
#   3. Build the builder VM: microvm build microvm-builder
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
  # Access locale settings from central options
  locale = config.hydrix.locale;
  # Host username for mounting hydrix-config (passed from mkMicrovmBuilder)
  hostUsername = config.hydrix.builder.hostUsername;
  # Optional local Hydrix path for developers
  localHydrixPath = config.hydrix.builder.localHydrixPath;
  vmName = config.networking.hostName;
in {
  imports = [
    # Central options for locale settings
    ../options.nix
    # QEMU Guest profile for virtio modules
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Builder-specific options
  options.hydrix.builder = {
    hostUsername = lib.mkOption {
      type = lib.types.str;
      description = "Username on the host machine (for mounting ~/hydrix-config)";
    };
    localHydrixPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional path to local Hydrix clone for developers.
        When set, builder mounts this path so flake can use path: inputs.
        This enables local development: edit in ~/Hydrix, test via ~/hydrix-config.
      '';
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
      qemu.machine = "pc"; # Standard PC for full PCI support

      # High resources for builds
      vcpu = 8;
      mem = 16384; # 16GB for large builds

      # No squashfs store - we mount host's store directly
      storeDiskType = "none";

      # Disable virtiofsd sandbox to allow writes to /nix/store
      # Builder needs direct R/W access to host's nix store
      virtiofsd.extraArgs = ["--sandbox" "none" "--cache" "always" "--thread-pool-size" "16"];

      # Headless operation
      graphics.enable = false;
      qemu.extraArgs = [
        "-vga"
        "none"
        "-display"
        "none"
        # Serial console via unix socket for interactive access
        # Connect with: microvm console microvm-builder
        "-chardev"
        "socket,id=console,path=/var/lib/microvms/microvm-builder/console.sock,server=on,wait=off"
        "-serial"
        "chardev:console"
      ];

      # ===== Shared Filesystems =====
      # CRITICAL: These are R/W mounts to host's actual nix store
      # Host nix-daemon MUST be stopped while builder is running
      shares =
        [
          # Host /nix/store - R/W access for building
          {
            tag = "host-nix-store";
            source = "/nix/store";
            mountPoint = "/nix/store";
            proto = "virtiofs";
          }
          # Host /nix/var/nix - R/W access for nix database
          {
            tag = "host-nix-var";
            source = "/nix/var/nix";
            mountPoint = "/nix/var/nix";
            proto = "virtiofs";
          }
          # User's hydrix-config - READ-ONLY for security
          # Builder can evaluate flakes but cannot modify source code
          # Uses hostUsername passed from mkMicrovmBuilder
          {
            tag = "hydrix-config";
            source = "/home/${hostUsername}/hydrix-config";
            mountPoint = "/mnt/hydrix";
            proto = "virtiofs";
          }
        ]
        ++ lib.optionals (localHydrixPath != null) [
          # Local Hydrix repo for developers - READ-ONLY for security
          # Enables path: flake inputs to work inside builder VM
          # Mount at same path so path references resolve correctly
          {
            tag = "local-hydrix";
            source = localHydrixPath;
            mountPoint = localHydrixPath;
            proto = "virtiofs";
          }
        ];

      # Persistent eval cache - survives builder restarts, avoids 2+ min cold eval
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
          id = "mv-builder";
          mac = "02:00:00:02:10:01"; # Unique MAC for builder
        }
      ];

      # ===== Vsock for host communication =====
      vsock.cid = 210;
    };

    # ===== Nix Configuration =====
    # Builder runs its own nix-daemon that writes to host's store
    nix = {
      enable = true;
      settings = {
        trusted-users = ["root" "builder"];
        auto-optimise-store = false; # Host manages optimization
        max-jobs = "auto";
        cores = 0; # Use all available
        # Disable sandbox - doesn't work well with virtiofs store mount
        sandbox = false;
        # Enable flakes and nix-command
        experimental-features = ["nix-command" "flakes"];
        # Use substituters for faster builds
        substituters = [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ];
        # Cache negative narinfo results permanently (reduces redundant DB lookups)
        narinfo-cache-negative-ttl = 0;
        # Parallel substituter downloads
        http-connections = 128;
        max-substitution-jobs = 32;
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
      };
      # Don't run GC in builder - host manages GC
      gc.automatic = false;
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
    fileSystems."/nix/var/nix/daemon-socket" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = ["mode=0755"];
    };

    # ===== Writable Nix Store =====
    # By default NixOS remounts /nix/store as read-only for security
    # Builder needs write access to populate host's store
    boot.nixStoreMountOpts = ["rw" "relatime"];

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
    networking = {
      useDHCP = true;
      enableIPv6 = false;
      networkmanager.enable = false;
      firewall.enable = false; # Builder doesn't need firewall
    };

    # ===== Services =====
    services.openssh.enable = false; # No SSH - vsock only
    services.qemuGuest.enable = true;
    services.getty.autologinUser = "builder";
    services.haveged.enable = true;

    # ===== User Configuration =====
    users.users.builder = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      password = "builder"; # Simple password for console access
    };
    security.sudo.wheelNeedsPassword = false;

    # ===== Packages =====
    environment.systemPackages = with pkgs; [
      git
      vim
      htop
      socat
      # Nix tools
      nix-tree
      nix-diff
    ];

    # ===== Git Configuration =====
    # Trust the mounted repos despite different ownership (virtiofs UID mapping)
    environment.etc."gitconfig".text =
      ''
        [safe]
          directory = /mnt/hydrix
      ''
      + lib.optionalString (localHydrixPath != null) ''
        directory = ${localHydrixPath}
      '';

    # ===== Read-Only Mounts for Security =====
    # Builder can evaluate flakes but cannot modify source code
    fileSystems."/mnt/hydrix".options = lib.mkAfter ["ro"];
    fileSystems.${localHydrixPath} = lib.mkIf (localHydrixPath != null) {
      options = lib.mkAfter ["ro"];
    };

    # ===== Vsock Build Server =====
    # Listens on port 14510 for build commands from host
    systemd.services.builder-vsock = {
      description = "Builder vsock server for host commands";
      wantedBy = ["multi-user.target"];
      after = ["network.target" "nix-daemon.service"];

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
            export PATH="${pkgs.coreutils}/bin:${pkgs.glibc.bin}/bin:${pkgs.gnugrep}/bin:$PATH"

            # Read command line
            read -r cmd rest

            case "$cmd" in
              BUILD)
                flake="$rest"
                echo "OK building $flake"

                # Brief pause for network stack, then let nix handle retries
                sleep 2

                # Run nix build - stream output directly to vsock
                # nix has built-in retry logic for network issues
                if ${pkgs.nix}/bin/nix build "$flake" --no-link --print-out-paths 2>&1; then
                  echo "DONE"
                else
                  echo "ERROR build failed"
                fi
                ;;

              PREFETCH)
                flake="$rest"
                echo "OK prefetching $flake"

                # Just fetch dependencies without building
                if ${pkgs.nix}/bin/nix flake prefetch "$flake" 2>&1; then
                  echo "DONE prefetch complete"
                else
                  echo "ERROR prefetch failed"
                fi
                ;;

              PING)
                echo "PONG"
                ;;

              *)
                echo "ERROR unknown command: $cmd"
                echo "Commands: BUILD <flake>, PREFETCH <flake>, PING"
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
    # Listens on port 14511 for status queries
    systemd.services.builder-status = {
      description = "Builder status server";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];

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
    time.timeZone = locale.timezone;
    i18n.defaultLocale = locale.language;
    console.keyMap = locale.consoleKeymap;

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
        echo "  vsock CID: 210"
        echo "  Build port: 14510"
        echo "  Status port: 14511"
        echo ""
        echo "Nix store mounted from host (R/W)"
        echo "Ready for build commands"
      '';
    };
  };
}
