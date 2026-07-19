# hydrix.microvm.* option declarations — split out from microvm-profile-base.nix
# so libvirt/disk-image builds (hydrix.lib.mkVM) can import just the option
# schema, letting profiles/<name>/default.nix set hydrix.microvm.* (including
# via lib.mkDefault/lib.mkForce) without pulling in the full microVM
# implementation (vsock, virtiofs, TAP networking, etc.) that doesn't apply
# to a plain disk image.
{ config, lib, ... }:

{
  options.hydrix.microvm = {
    audio.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable PulseAudio-over-vsock forwarding to host PipeWire in waypipe mode. Disable for privacy-sensitive VMs (pentest, lurking).";
    };

    vcpu = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Number of virtual CPUs";
    };

    mem = lib.mkOption {
      type = lib.types.int;
      default = 2304;  # Avoid QEMU hang at exactly 2GB (microvm-nix#171)
      description = "Memory in MB (balloon reclaims idle memory from guest)";
    };

    vsockCid = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Unique vsock CID for this VM (must be unique per VM, >2)";
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "br-browse";
      description = "Network bridge to attach TAP interface to";
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/${config.hydrix.vm.storeName}/config";
      description = "Host path for VM config (read-only 9p mount)";
    };

    tapId = lib.mkOption {
      type = lib.types.str;
      default = "mv-${lib.substring 0 10 config.hydrix.vm.storeName}";
      description = "TAP interface ID (max 15 chars on Linux)";
    };

    shareStore = lib.mkOption {
      type = lib.types.bool;
      default = true;  # Share host /nix/store for instant startup (no squashfs build)
      description = "Share host /nix/store via virtiofs (faster rebuilds, instant startup)";
    };

    persistence = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable persistent home directory via qcow2 volume";
      };

      homeSize = lib.mkOption {
        type = lib.types.int;
        default = 10240;
        description = "Home volume size in MB";
      };

      volumePath = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/microvms/${config.hydrix.vm.storeName}/home.qcow2";
        description = "Path to the qcow2 volume for home persistence";
      };

      extraVolumes = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Volume name (used in path)";
            };
            size = lib.mkOption {
              type = lib.types.int;
              description = "Volume size in MB";
            };
            mountPoint = lib.mkOption {
              type = lib.types.str;
              description = "Mount point inside VM";
            };
          };
        });
        default = [];
        description = "Additional persistent volumes (e.g., docker)";
      };

      storeOverlaySize = lib.mkOption {
        type = lib.types.int;
        default = 20480;
        description = "Size in MB for persistent store overlay (for in-VM rebuilds). Thin-provisioned.";
      };

    };


    # Encryption options for persistent volumes
    encryption = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable LUKS encryption for persistent volumes.
          When enabled, volumes are encrypted with a password prompted at start.
          Use 'microvm create-encrypted <name>' to set up the encrypted volume.
        '';
      };

      mandatory = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Require encryption for this VM type.
          If true, the VM will refuse to start without encrypted volumes.
          Recommended for pentest VMs to protect sensitive data.
        '';
      };
    };

    # Static IP for this VM on its primary bridge (null = DHCP)
    # Used by the files VM to know where to reach each VM for file transfers.
    staticIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Static IP for this VM on its primary bridge. Null = DHCP.";
    };
  };
}
