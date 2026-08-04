# Host Scripts - Hydrix management scripts
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  config = lib.mkIf (cfg.vmType == "host") {
    # Note: 'rebuild' command is provided by modules/base/hydrix-scripts.nix
    # Note: 'hydrix-mode' and 'router-status' are in modules/host/specialisations.nix
  };
}
