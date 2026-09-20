# Dev VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 105;
  bridge    = "br-dev";
  tapId     = "mv-dev";
  routerTap = "mv-router-dev";   # ≤15 chars (Linux iface limit)
  subnet    = "192.168.105";     # /24 prefix — matches CID last octet
  workspace   = 5;
  label       = "DEV";
  focusBorder = "cyan";

  mem  = 8192;             # ceiling, MB - balloon reclaims idle memory
  vcpu = 8;                # ceiling - generous headroom, balloons down properly when idle
  memLowFloorMb   = 2048;  # elastic daemon: resting point, window open but idle
  memFloorMb      = 1536;  # elastic daemon: absolute floor, no windows open
  cpuLowFloorPct  = 400;   # elastic daemon: CPU floor while RAM still deflating (50% of ceiling)
  cpuFloorPct     = 20;    # elastic daemon: true CPU floor once RAM settled
}
