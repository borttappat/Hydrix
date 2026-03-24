# Override disk image build with more memory for large images
#
# The default NixOS disk-image module only allocates 1GB RAM for the build VM.
# For large images like pentest with 100+ packages, this causes entropy starvation
# and the build VM hangs waiting for random data.
#
# This module overrides system.build.image using the approach from:
# https://discourse.nixos.org/t/... (SpiderUnderUrBed's fix)
{ config, lib, pkgs, ... }:

let
  cfg = config.image;
in {
  options.image.buildMemSize = lib.mkOption {
    type = lib.types.int;
    default = 2048;
    description = "Memory size (in MiB) for the temporary VM used to build the disk image.";
  };

  config = {
    # Override the default image build using pkgs.callPackage (matches working solution)
    system.build.image = lib.mkForce (pkgs.callPackage "${pkgs.path}/nixos/lib/make-disk-image.nix" {
      inherit config lib;
      format = cfg.format;
      diskSize = "auto";
      additionalSpace = "2G";  # Extra space for large closures
      memSize = cfg.buildMemSize;
      partitionTableType = if cfg.efiSupport then "efi" else "legacy";
    });
  };
}
