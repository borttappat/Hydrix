# Browsing VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 103;
  bridge    = "br-browse";
  tapId     = "mv-browse";
  routerTap = "mv-router-brow";  # ≤15 chars (Linux iface limit)
  subnet    = "192.168.103";     # /24 prefix — matches CID last octet
  workspace   = 3;
  label       = "BROWSING";
  focusBorder = "yellow";

  mem  = 3072;             # ceiling, MB - balloon reclaims idle memory
  vcpu = 3;                # ceiling
  memLowFloorMb   = 2048;  # elastic daemon: resting point, window open but idle
  memFloorMb      = 1536;  # elastic daemon: absolute floor, no windows open
  cpuLowFloorPct  = 60;    # elastic daemon: CPU floor while RAM still deflating
  cpuFloorPct     = 20;    # elastic daemon: true CPU floor once RAM settled
}
