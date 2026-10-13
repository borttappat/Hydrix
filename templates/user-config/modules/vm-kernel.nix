# Trimmed guest kernel for VMs (hydrix.vmKernel, off by default).
#
# The host handles real peripherals; VMs only ever see virtio devices, so the guest kernel
# does not need drivers for hardware it never touches. Enabling it compiles the kernel
# locally (no binary cache), so it is opt-in per VM: import this file in the VM's
# default.nix and set `hydrix.vmKernel.enable = true;`. Each hardware axis stays stripped
# unless that VM really owns the hardware (a VFIO-passthrough VM keeping wireless,
# usb-sandbox keeping USB drivers). Tweak the symbol lists below freely.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.vmKernel;
  # mkForce: nixpkgs' common-config.nix already sets defaults (often "m") for
  # many of these symbols, same priority as a plain value here - conflicts.
  no = lib.mkForce lib.kernel.no;
  yes = lib.mkForce lib.kernel.yes;
in {
  options.hydrix.vmKernel = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Build a trimmed guest kernel (linuxPackages_latest) with bluetooth, wifi and unused peripheral drivers stripped. Compiled locally.";
    };

    bluetooth = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Keep bluetooth support (this VM owns real bluetooth hardware).";
    };

    wireless = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Keep wireless LAN support (this VM owns a real wifi radio, e.g. via VFIO passthrough).";
    };

    usbPeripherals = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Keep USB storage/HID drivers (this VM handles real USB devices, e.g. usb-sandbox).";
    };

    sound = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Keep the sound subsystem (this VM forwards audio, e.g. over pulse-vsock).";
    };

    graphics = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Keep vendor GPU (DRM) drivers. All these VMs render with llvmpipe (software) and run headless (-vga none), so real GPU drivers are dead weight and, worse, some of the slowest things in the whole kernel to compile (amdgpu especially).";
    };
  };

  config = lib.mkIf cfg.enable {
    # NixOS's default initrd module list assumes generic hardware (USB HID,
    # various filesystems) and references specific driver modules by name for
    # autodetection. With USB_HID stripped from the kernel entirely, those
    # .ko files don't exist and initrd assembly hard-fails looking for them.
    # qemu-guest.nix already declares the actual virtio modules this VM boots
    # from, so the generic list is both wrong and unnecessary here.
    boot.initrd.includeDefaultModules = false;

    # mkForce: shared/core/nix.nix sets boot.kernelPackages via mkDefault for
    # every VM, same priority as a plain mkDefault here would be - conflicts.
    boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor (pkgs.linuxPackages_latest.kernel.override {
      # nixpkgs' common-config.nix sets many specific hardware-driver
      # submodules (wifi chips, joystick force-feedback, sound codecs) as
      # modules; disabling their parent menu here makes those now-unreachable
      # and nixpkgs treats that as a fatal error by default on this platform.
      ignoreConfigErrors = true;
      structuredExtraConfig =
        {
          # No cameras, joysticks, or touchscreens to drive anywhere
          MEDIA_SUPPORT = no;
          INPUT_JOYSTICK = no;
          INPUT_TABLET = no;
          INPUT_TOUCHSCREEN = no;

          SOUND =
            if cfg.sound
            then yes
            else no;
          SND =
            if cfg.sound
            then yes
            else no;

          # Real hardware classes no VM will ever see, regardless of profile
          FUSION = no; # LSI Fusion MPT SCSI/FC HBAs - virtio-blk/scsi only
          HYPERV = no; # MS Hyper-V integration drivers - this is QEMU/KVM
          INFINIBAND = no;
          CRYPTO_DEV_CCP = no; # AMD crypto coprocessor
          STAGING = no; # experimental/out-of-tree driver tree
          STAGING_MEDIA = no;
          "8139TOO_8129" = no; # Realtek NIC - virtio-net only
        }
        // lib.optionalAttrs (!cfg.bluetooth) {
          BT = no;
          BT_BREDR = no;
          BT_HCIBTUSB = no;
          BT_HCIUART = no;
          BT_HCIVHCI = no;
          BT_RFCOMM = no;
          BT_BNEP = no;
          BT_HIDP = no;
        }
        // lib.optionalAttrs (!cfg.wireless) {
          CFG80211 = no;
          MAC80211 = no;
          WLAN = no;
          RFKILL = no;
        }
        // lib.optionalAttrs (!cfg.usbPeripherals) {
          USB_HID = no;
          USB_STORAGE = no;
          USB_PRINTER = no;
        }
        // lib.optionalAttrs (!cfg.graphics) {
          DRM_AMDGPU = no;
          DRM_RADEON = no;
          DRM_NOUVEAU = no;
          DRM_I915 = no;
          DRM_VMWGFX = no;
          DRM_QXL = no;

          # Legacy pre-DRM framebuffer accel drivers for the same vendor cards
          FB_3DFX_ACCEL = no;
          FB_ATY_CT = no;
          FB_ATY_GX = no;
          FB_NVIDIA_I2C = no;
          FB_RIVA_I2C = no;
          FB_SAVAGE_ACCEL = no;
          FB_SAVAGE_I2C = no;
          FB_SIS_300 = no;
          FB_SIS_315 = no;
        };
    }));
  };
}
