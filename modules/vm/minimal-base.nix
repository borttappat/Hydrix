# Minimal VM Base - Boot-time configuration approach
#
# Creates a base image that configures itself on first boot.
#
# Two modes:
#   - Minimal (~200MB): Just bootloader, kernel, activation service
#   - Golden (~1.5GB): Includes common desktop stack (i3, fish, fonts, firefox)
#
# The "golden" image pre-bakes packages shared by ALL VM profiles,
# so first-boot rebuilds only add profile-specific packages.
#
# The VM "shapes itself" on first boot by:
#   1. Reading the flake target from /mnt/vm-config/target (e.g., "vm-browsing")
#   2. Using the baked-in Hydrix flake to run nixos-rebuild
#   3. Rebooting into the fully configured system
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.vm.minimalBase;

  # Path where Hydrix repo is baked into the image
  hydrixPath = "/etc/hydrix";
in
{
  options.hydrix.vm.minimalBase = {
    enable = lib.mkEnableOption "minimal base VM with boot-time configuration";

    golden = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Include common desktop stack (i3, fish, fonts, firefox) in base image.
        This makes the image ~1.5GB but speeds up first-boot rebuilds significantly
        since profile-specific builds only need to add their unique packages.
        Set to false for a truly minimal ~200MB image.
      '';
    };

    configMountTag = lib.mkOption {
      type = lib.types.str;
      default = "vm-config";
      description = "9p mount tag for VM instance config (contains 'target' file)";
    };

    configMountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/vm-config";
      description = "Where to mount the VM instance configuration";
    };

    hydrixSource = lib.mkOption {
      type = lib.types.path;
      description = "Path to Hydrix repository to bake into the image";
    };
  };

  config = lib.mkIf cfg.enable {
    # ============================================
    # BOOT - Absolute minimum to get system running
    # ============================================

    boot = {
      loader.grub = {
        enable = true;
        device = "/dev/vda";
        efiSupport = false;
      };

      # Kernel modules needed for QEMU/virtio
      initrd.availableKernelModules = [
        # Virtio (required for QEMU)
        "virtio_pci"
        "virtio_blk"
        "virtio_scsi"
        "virtio_net"
        "virtio_balloon"
        "virtio_ring"
        "virtio_console"
        # virtiofs for shared store
        "virtiofs"
        # 9p for config mount
        "9p"
        "9pnet"
        "9pnet_virtio"
        # Storage
        "ahci"
        "sd_mod"
        "sr_mod"
      ];

      kernelModules = [ "kvm-intel" "kvm-amd" ];

      # Quiet boot for faster startup
      kernelParams = [ "console=ttyS0,115200" "quiet" ];
      # Note: loader.timeout is set by qcow format, don't override
    };

    # ============================================
    # FILESYSTEM - Root disk + shared store mount
    # ============================================

    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

    # Mount host's /nix/store as binary cache source (virtiofs for performance)
    fileSystems."/nix/.host-store" = {
      device = "nix-store";
      fsType = "virtiofs";
      options = [ "ro" "nofail" ];
    };

    # Mount VM instance config (just contains target name + credentials)
    fileSystems.${cfg.configMountPoint} = {
      device = cfg.configMountTag;
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "ro"
        "nofail"
        "x-systemd.automount"
      ];
      neededForBoot = false;
    };

    # ============================================
    # BAKE HYDRIX FLAKE INTO IMAGE
    # ============================================

    # Copy Hydrix repo into /etc/hydrix (read-only, will copy to /tmp for builds)
    environment.etc."hydrix".source = lib.cleanSourceWith {
      src = cfg.hydrixSource;
      filter = path: type:
        let
          baseName = baseNameOf path;
        in
        # Exclude build artifacts and git
        !(baseName == ".git" ||
          baseName == "result" ||
          lib.hasPrefix "result-" baseName ||
          baseName == "minimal-base-image" ||
          baseName == ".direnv" ||
          # Exclude local secrets - these come from vm-config mount
          baseName == "local");
    };

    # ============================================
    # NETWORKING - Basic DHCP
    # ============================================

    networking = {
      useDHCP = true;
      networkmanager.enable = false;
      firewall.enable = true;
      firewall.allowPing = true;
      # Hostname will be set by activation
      hostName = lib.mkDefault "minimal-vm";
    };

    # ============================================
    # NIX - Configure to use host store as cache
    # ============================================

    nix = {
      settings = {
        experimental-features = [ "nix-command" "flakes" ];
        # Use host store cache (served by nix-serve on boot)
        substituters = lib.mkBefore [ "http://localhost:5557" ];
        trusted-substituters = [ "http://localhost:5557" ];
        require-sigs = false;
      };
    };

    # nix-serve to serve host store as binary cache
    systemd.services.host-store-cache = {
      description = "Local binary cache from host /nix/store";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      unitConfig.ConditionPathIsMountPoint = "/nix/.host-store";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.nix-serve}/bin/nix-serve --port 5557 --store /nix/.host-store";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    # ============================================
    # BOOT-TIME ACTIVATION SERVICE
    # ============================================

    systemd.services.vm-first-boot-activation = {
      description = "Apply VM configuration on first boot";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "host-store-cache.service"
      ];
      wants = [ "network-online.target" ];

      # Only run if first-boot marker doesn't exist
      unitConfig = {
        ConditionPathExists = "!/var/lib/vm-configured";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      };

      script = ''
        set -euo pipefail

        echo "=== VM First Boot Activation ==="

        # Determine flake target
        if [ -f "${cfg.configMountPoint}/target" ]; then
          FLAKE_TARGET=$(cat ${cfg.configMountPoint}/target)
          echo "Target from config mount: $FLAKE_TARGET"
        else
          echo "ERROR: No target file found at ${cfg.configMountPoint}/target"
          echo "Expected file containing flake target (e.g., 'vm-browsing')"
          exit 1
        fi

        # Wait for host store cache
        for i in $(seq 1 30); do
          if ${pkgs.curl}/bin/curl -s http://localhost:5557/nix-cache-info >/dev/null 2>&1; then
            echo "Host store cache is ready"
            break
          fi
          echo "Waiting for host store cache... ($i/30)"
          sleep 2
        done

        # Copy baked Hydrix flake to writable location
        # Use -L to dereference symlinks (nix store paths are read-only)
        echo "Preparing Hydrix flake..."
        rm -rf /tmp/hydrix-build
        cp -rL ${hydrixPath} /tmp/hydrix-build
        chmod -R u+w /tmp/hydrix-build

        # Copy instance-specific config from mount (credentials, hostname, etc.)
        if [ -d "${cfg.configMountPoint}/local" ]; then
          echo "Copying instance config from mount..."
          cp -r ${cfg.configMountPoint}/local /tmp/hydrix-build/
          chmod -R u+w /tmp/hydrix-build/local
        fi

        # Stage local files for nix (flakes need tracked files)
        cd /tmp/hydrix-build
        ${pkgs.git}/bin/git init -q 2>/dev/null || true
        ${pkgs.git}/bin/git add -A 2>/dev/null || true

        # Build and switch
        echo "Building configuration: $FLAKE_TARGET"
        ${pkgs.nixos-rebuild}/bin/nixos-rebuild boot --flake ".#$FLAKE_TARGET"

        # Mark as configured
        mkdir -p /var/lib
        touch /var/lib/vm-configured
        echo "$FLAKE_TARGET" > /var/lib/vm-configured

        echo "=== Configuration applied, rebooting... ==="
        ${pkgs.systemd}/bin/systemctl reboot
      '';
    };

    # ============================================
    # PACKAGES
    # ============================================

    environment.systemPackages = with pkgs; [
      # Essentials for boot-time activation
      curl
      git
      nix-serve
      # Debugging
      vim
      htop
    ] ++ lib.optionals cfg.golden [
      # ---- i3 Desktop Stack ----
      i3
      i3lock-color
      i3status
      picom
      rofi
      polybar
      alacritty
      dunst
      libnotify
      flameshot
      feh
      arandr
      lxappearance
      pavucontrol

      # ---- Shell ----
      fish
      starship
      zoxide
      fzf
      tmux
      ranger

      # ---- Core Utilities ----
      wget
      unzip
      zip
      p7zip
      file
      tree
      ripgrep
      fd
      bat
      jq
      yq

      # ---- X11 ----
      xorg.xrandr
      xorg.xmodmap
      xorg.xinit
      xorg.xset
      xdotool
      xsel
    ] ++ config.hydrix.graphical.font.vmPackages ++ [
      # ---- Theming ----
      pywal
      wallust

      # ---- Browser ----
      firefox
    ];

    # Enable fontconfig for golden image
    fonts.fontconfig.enable = lib.mkIf cfg.golden true;

    # ============================================
    # SERVICES - Minimal set
    # ============================================

    services = {
      openssh = {
        enable = true;
        settings.PermitRootLogin = "yes";
      };
      qemuGuest.enable = true;
    };

    # ============================================
    # GOLDEN IMAGE - X11/Desktop services
    # ============================================

    # X11 and i3 for golden image
    services.xserver = lib.mkIf cfg.golden {
      enable = true;
      displayManager.startx.enable = true;
      windowManager.i3 = {
        enable = true;
        package = pkgs.i3;
      };
    };

    # Audio (pipewire) for golden image
    security.rtkit.enable = lib.mkIf cfg.golden true;
    services.pipewire = lib.mkIf cfg.golden {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    # Spice agent for clipboard/resolution in golden image
    services.spice-vdagentd.enable = lib.mkIf cfg.golden true;

    # Set fish as default shell for golden image
    programs.fish.enable = lib.mkIf cfg.golden true;

    # Temporary root password for initial access (should be overwritten by activation)
    users.users.root.initialPassword = "nixos";

    # ============================================
    # SYSTEM - NixOS version
    # ============================================

    system.stateVersion = "25.11";
  };
}
