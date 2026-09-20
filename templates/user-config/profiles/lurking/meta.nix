# Lurking VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 106;
  bridge    = "br-lurking";
  tapId     = "mv-lurking";
  routerTap = "mv-router-lurk";  # ≤15 chars (Linux iface limit)
  subnet    = "192.168.106";     # /24 prefix — matches CID last octet
  workspace   = 6;
  label       = "LURKING";
  focusBorder = "red";

  mem  = 2304;             # ceiling, MB - balloon reclaims idle memory
  vcpu = 4;                # ceiling - generous headroom, balloons down properly when idle
  memLowFloorMb   = 2048;  # elastic daemon: resting point, window open but idle
  memFloorMb      = 1536;  # elastic daemon: absolute floor, no windows open
  cpuLowFloorPct  = 200;   # elastic daemon: CPU floor while RAM still deflating (50% of ceiling)
  cpuFloorPct     = 20;    # elastic daemon: true CPU floor once RAM settled
}
