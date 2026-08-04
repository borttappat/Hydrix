# Task slot 3, engagement tracked in tasks/.engagement-registry
# Customize per-engagement: encryption, packages, persistence size, etc.
{ lib, ... }:
{
  # Per-engagement hostname override (needs mkForce: profiles/pentest/default.nix
  # sets hydrix.vm.hostname as a plain assignment, so a plain override here would
  # conflict with it instead of winning).
  # hydrix.vm.hostname = lib.mkForce "Win-aabbcc1122";

  hydrix.microvm = {
    vsockCid = 117;
    tapId    = "mv-task-3";
    persistence.homeSize = 20480;  # 20GB (smaller than pentest's 100GB)
    encryption.enable = true;      # On by default: task slots hold engagement data
  };
}
