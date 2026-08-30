  # ─────────────────────────────────────────────────────────────────────
  # HARDWARE (hand-maintained, appended to the nixos-generate-config output
  # above -- kept out of the machine file so a disk/hardware change doesn't
  # touch unrelated preferences, and vice versa)
  # ─────────────────────────────────────────────────────────────────────
  hydrix = {
    hardware = {
      platform = "@PLATFORM@";
      isAsus = @IS_ASUS@;
      vfio = {
        enable = @VFIO_ENABLE@;
        pciIds = [ "@WIFI_PCI_ID@" ];
        wifiPciAddress = "@WIFI_PCI_ADDRESS@";
      };

      # bluetooth.enable = true;     # DEFAULT: true - Bluetooth + Blueman
      # i2c.enable = true;           # DEFAULT: true - DDC/CI monitor control
      # touchpad.enable = true;      # DEFAULT: true - libinput touchpad

      grub.gfxmodeEfi = "@GRUB_GFXMODE@";
    };

    disko = {
      enable = @DISKO_ENABLE@;
      device = "@DEVICE@";
      swapSize = "@SWAP_SIZE@";
      layout = "@LAYOUT@";
      nixosPartition = "@NIXOS_PARTITION@";
      efiPartition = "@EFI_PARTITION@";
      efiBootloaderId = "@EFI_BOOTLOADER_ID@";
    };
  };
