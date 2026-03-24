# AMD Platform - Microcode, graphics
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
in {
  config = lib.mkIf (cfg.hardware.platform == "amd") {
    # AMD microcode
    hardware.cpu.amd.updateMicrocode = true;

    # AMD graphics (if using integrated)
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [
        amdvlk
      ];
    };
  };
}
