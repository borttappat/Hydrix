# VM Base Module - Central configuration for all VMs (except router)
#
# This module consolidates all common VM configuration:
# - Hardware configuration (kernel modules, boot loader, filesystem)
# - Common imports (qemu-guest, shared-store, bake-config, etc.)
# - Parameterized rebuild script
#
# By default, libvirt VMs run headless like microVMs (hydrix.vm.desktopEnvironment
# = "none"). Set hydrix.vm.desktopEnvironment = "xfce" or "hyprland" for a VM with
# its own desktop, viewable via virt-manager's SPICE/VNC console.
#
# "xfce" is the recommended choice: a real X11 session manager with native XDG
# autostart, so spice-vdagent (clipboard sync, display resize) just works with
# zero extra wiring. "hyprland" reuses the same Wayland/waypipe stack microVMs
# use, but it's a bare WM with no session manager, which showed real friction in
# practice: spice-vdagent is X11-native and needs manual exec-once wiring to
# reach XWayland at all, and greetd needs its own login screen (greetd.nix is
# imported below purely for this path, normally only pulled in by the host-only
# theming/default.nix). Prefer "xfce" unless you specifically need the Hydrix
# Hyprland/waypipe stack running standalone inside the guest.
#
# Profiles should import this module and only set profile-specific config:
# - hydrix.vmType
# - hydrix.colorscheme
# - hydrix.vm.defaultHostname
# - Profile-specific packages and services
#
{ config, pkgs, lib, modulesPath, ... }:

let
  cfg = config.hydrix;

  # Get hostname from options
  vmHostname = config.hydrix.vm.defaultHostname;

  # Rebuild target for the script (e.g., "vm-pentest")
  rebuildTarget = config.hydrix.vm.rebuildTarget;

in {
  imports = [
    # QEMU guest profile from nixpkgs
    (modulesPath + "/profiles/qemu-guest.nix")

    # Hydrix options (single source of truth)
    ../options.nix

    # Base system modules
    ../common/users-vm.nix
    ../../host/base/networking.nix

    # Minimal CLI environment (always included)
    ./vm-minimal.nix

    # VM theming scripts (wal-sync, set-colorscheme-mode, refresh-colors)
    ../theming/vm-theming.nix

    # VM-specific modules
    ../common/qemu-guest.nix
    ../common/shared-store.nix
    ./bake-config.nix
    ../display/waypipe-vm.nix   # waypipe display mode handler (vsock:14509)
    ../dev/vm-dev.nix       # vm-dev, vm-sync scripts for package development

    # Core desktop environment
    # Only activates when hydrix.graphical.enable = true
    ../../shared/core

    # Unified graphical environment (Stylix + Home Manager)
    # Only activates when hydrix.graphical.enable = true
    ../../theming/graphical

    # Login manager for standalone desktop mode
    # Only activates when hydrix.greetd.enable = true
    ../../theming/dm/greetd.nix
  ];

  options.hydrix.vm = {
    defaultHostname = lib.mkOption {
      type = lib.types.str;
      default = "${config.hydrix.vmType or "unknown"}-vm";
      description = "Default VM hostname";
    };

    rebuildTarget = lib.mkOption {
      type = lib.types.str;
      default = "vm-${config.hydrix.vmType or "unknown"}";
      description = "Flake target for rebuild script (e.g., vm-pentest)";
    };

    desktopEnvironment = lib.mkOption {
      type = lib.types.enum [ "none" "xfce" "hyprland" ];
      default = "none";
      description = ''
        Desktop environment for a standalone libvirt VM, viewable via
        virt-manager's SPICE/VNC console. "none" (default) keeps the VM
        headless, same as a microVM. "xfce" gets a real X11 session with
        working spice-vdagent clipboard/resize out of the box. "hyprland"
        activates the same Hydrix Hyprland/waypipe stack microVMs use, but
        needs manual spice-vdagent wiring to get clipboard sync working.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.vm.desktopEnvironment == "hyprland") {
      hydrix.graphical.enable = true;
      hydrix.graphical.standalone = true;
      hydrix.hyprland.enable = true;
      hydrix.greetd.enable = true;
    })

    (lib.mkIf (cfg.vm.desktopEnvironment == "xfce") {
      services.xserver.enable = true;
      services.xserver.desktopManager.xfce.enable = true;
      services.displayManager.sddm.enable = true;
      services.displayManager.autoLogin = {
        enable = lib.mkDefault true;
        user = lib.mkDefault config.hydrix.username;
      };
      # home-manager requires this; theming/graphical/home.nix normally sets it
      # but that module only activates for hydrix.graphical.enable (Hyprland).
      home-manager.users.${config.hydrix.username}.home.stateVersion =
        lib.mkDefault config.system.stateVersion;
    })

    {

    # ===== Entropy generation =====
    # Ensures reliable entropy for VMs (fixes potential stalls)
    services.haveged.enable = true;

    # ===== Hardware configuration for QEMU VMs =====
    # QEMU hardware is always the same - no hardware-configuration.nix needed
    boot.initrd.availableKernelModules = [
      "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
      "virtio_net" "virtio_scsi" "virtio_console"
      "ahci" "xhci_pci" "sd_mod" "sr_mod"
    ];
    # 9p modules must be loaded early for config mount
    boot.initrd.kernelModules = [ "9p" "9pnet" "9pnet_virtio" ];
    boot.kernelModules = [ "kvm-intel" "kvm-amd" "virtio_rng" ];

    # Entropy settings to prevent VM hangs during image build
    boot.kernelParams = [
      "random.trust_cpu=on"
      "rng_core.default_quality=1000"
    ];
    boot.extraModulePackages = [ ];

    # Boot loader
    boot.loader.grub = {
      enable = true;
      device = lib.mkDefault "/dev/vda";
      efiSupport = false;
      useOSProber = false;
    };

    # Filesystem - nixos-generators creates disk with label "nixos"
    fileSystems."/" = lib.mkDefault {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

    swapDevices = [ ];

    # ===== Host profiles writeback mount =====
    # Allows VM to edit its profile on the host for live development
    # Mounted via 9p from deploy-vm.sh (target: hydrix-profiles)
    fileSystems."/mnt/hydrix-profiles" = {
      device = "hydrix-profiles";
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "rw"
        "nofail"  # Don't fail boot if not present (e.g., manually created VMs)
      ];
    };

    # ===== Host scaling config mount =====
    # Shares ~/.config/hydrix/ from host for dynamic DPI scaling
    # VM reads scaling.json to use same font sizes as host
    fileSystems."/mnt/hydrix-config" = {
      device = "hydrix-config";
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "ro"
        "nofail"
      ];
    };

    # ===== Host persist directory mount =====
    # Shares ~/persist/<vmType>/ from host for vm-dev/vm-sync workflow
    # Enables bidirectional file sharing for package development
    fileSystems."/mnt/vm-persist" = {
      device = "vm-persist";
      fsType = "9p";
      options = [
        "trans=virtio"
        "version=9p2000.L"
        "rw"
        "nofail"
      ];
    };

    networking.useDHCP = lib.mkDefault true;
    # Disable NetworkManager - VMs just need simple DHCP, not full network management
    # This overrides the setting from networking.nix which enables NetworkManager
    networking.networkmanager.enable = lib.mkForce false;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== Hostname from instance config =====
    networking.hostName = lib.mkForce vmHostname;


    # ===== Enable virtiofs shared /nix/store =====
    hydrix.vm.sharedStore.enable = lib.mkDefault true;

    # ===== Rebuild script =====
    # Parameterized based on hydrix.vm.rebuildTarget
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "rebuild" ''
        #!/usr/bin/env bash
        set -e
        cd ~/hydrix-config
        echo "Rebuilding ${vmHostname}..."
        echo "Using flake target: ${rebuildTarget}"
        # using nh for better output visualization
        # --hostname forces the specific config (e.g. vm-pentest) instead of hostname (pentest-vm)
        nh os switch . --hostname ${rebuildTarget} -- --impure
      '')
    ];

    # ===== Profile writeback symlink =====
    # Create ~/hydrix-config/profiles symlink to the 9p mount
    # This allows direct editing of profiles that syncs to host
    systemd.services.hydrix-profiles-link = {
      description = "Create hydrix-config profiles symlink";
      wantedBy = [ "multi-user.target" ];
      after = [ "mnt-hydrix\\x2dprofiles.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.util-linux pkgs.coreutils ];
      script = ''
        # Get username from config
        USER_HOME="/home/${config.hydrix.username}"

        # Skip if mount doesn't exist (manually created VMs without writeback)
        if ! mountpoint -q /mnt/hydrix-profiles 2>/dev/null; then
          echo "Profiles mount not present, skipping symlink"
          exit 0
        fi

        echo "Mount found at /mnt/hydrix-profiles"

        # Create hydrix-config directory structure
        mkdir -p "$USER_HOME/hydrix-config"

        # Create or update symlink
        if [ -L "$USER_HOME/hydrix-config/profiles" ]; then
          # Already a symlink, verify it points to the right place
          if [ "$(readlink "$USER_HOME/hydrix-config/profiles")" != "/mnt/hydrix-profiles" ]; then
            rm "$USER_HOME/hydrix-config/profiles"
            ln -s /mnt/hydrix-profiles "$USER_HOME/hydrix-config/profiles"
          fi
          echo "Symlink already correct"
        elif [ -d "$USER_HOME/hydrix-config/profiles" ]; then
          # Directory exists (maybe from baked config), replace with symlink
          echo "Replacing directory with symlink"
          rm -rf "$USER_HOME/hydrix-config/profiles"
          ln -s /mnt/hydrix-profiles "$USER_HOME/hydrix-config/profiles"
        else
          # Nothing there, create symlink
          echo "Creating new symlink"
          ln -s /mnt/hydrix-profiles "$USER_HOME/hydrix-config/profiles"
        fi

        # Fix ownership
        chown -h ${config.hydrix.username}:users "$USER_HOME/hydrix-config"
        chown -h ${config.hydrix.username}:users "$USER_HOME/hydrix-config/profiles"

        echo "Profiles symlink created: $USER_HOME/hydrix-config/profiles -> /mnt/hydrix-profiles"
      '';
    };

    # ===== Scaling config symlink =====
    # Create ~/.config/hydrix symlink to /mnt/hydrix-config
    # This allows apps to find scaling.json at the expected path
    systemd.services.hydrix-config-link = {
      description = "Create Hydrix config symlink for dynamic scaling";
      wantedBy = [ "multi-user.target" ];
      after = [ "mnt-hydrix\\x2dconfig.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.util-linux pkgs.coreutils ];
      script = ''
        USER_HOME="/home/${config.hydrix.username}"
        CONFIG_DIR="$USER_HOME/.config/hydrix"

        # Skip if mount doesn't exist
        if ! mountpoint -q /mnt/hydrix-config 2>/dev/null; then
          echo "Hydrix config mount not present, skipping"
          exit 0
        fi

        # Create .config directory if needed
        mkdir -p "$USER_HOME/.config"
        chown ${config.hydrix.username}:users "$USER_HOME/.config"

        # Create or update symlink
        if [ -L "$CONFIG_DIR" ]; then
          current=$(readlink "$CONFIG_DIR")
          if [ "$current" != "/mnt/hydrix-config" ]; then
            rm "$CONFIG_DIR"
            ln -s /mnt/hydrix-config "$CONFIG_DIR"
          fi
        elif [ -d "$CONFIG_DIR" ]; then
          # Directory exists, move aside and symlink
          mv "$CONFIG_DIR" "$CONFIG_DIR.bak"
          ln -s /mnt/hydrix-config "$CONFIG_DIR"
        else
          ln -s /mnt/hydrix-config "$CONFIG_DIR"
        fi

        chown -h ${config.hydrix.username}:users "$CONFIG_DIR"
        echo "Config symlink created: $CONFIG_DIR -> /mnt/hydrix-config"
      '';
    };

    }
  ];
}
