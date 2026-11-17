# Optional, for advanced users: one custom guest kernel per tier, never one per VM
# (plans/layered-stores.md, step 4). Off by default: every VM runs the stock nixpkgs kernel,
# which comes ready-built from cache.nixos.org. A custom kernel compiles locally, about an
# hour per kernel update, and no binary cache has it; only worth it with a cache shared
# between machines. With enable = true, flake.nix imports modules/vm-kernel.nix and
# `profile` below into every profile VM (on a store tier or not) and every task slot.
#
# Every VM of a tier gets exactly these settings (mkForce), so they evaluate to the same
# kernel derivation (checked: lurking, pentest, browsing, dev and task1 all give one
# linux-7.1.5.drv): the host compiles it once per kernel update and every VM reuses it. A
# tier builder never builds a kernel. Set the hardware axes for what any VM of the tier
# needs.
{
  enable = false;

  profile = {lib, ...}: {
    hydrix.vmKernel = lib.mkForce {
      enable = true;
      hardened = true;
      # pentest's USB WiFi adapter (meta.nix usbDevices): USB and wireless drivers stay.
      wireless = true;
      usbPeripherals = true;
      bluetooth = false;
      sound = false;
      graphics = false;
    };
  };
}
