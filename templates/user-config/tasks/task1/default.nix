# Task slot 1 — engagement tracked in tasks/.engagement-registry
# Customize per-engagement: encryption, packages, persistence size, etc.
{ ... }:
{
  hydrix.microvm = {
    vsockCid = 115;
    tapId    = "mv-task-1";
    persistence.homeSize = 20480;  # 20GB (smaller than pentest's 100GB)

    # Per-engagement options:
    # encryption.enable = true;   # Encrypt home volume
  };
}
