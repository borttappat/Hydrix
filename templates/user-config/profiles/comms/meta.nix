# Comms VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 104;
  bridge    = "br-comms";
  tapId     = "mv-comms";
  routerTap = "mv-router-comm";  # ≤15 chars (Linux iface limit)
  subnet    = "192.168.104";     # /24 prefix — matches CID last octet
  workspace   = 4;
  label       = "COMMS";
  focusBorder = "green";

  mem  = 2304;             # ceiling, MB - balloon reclaims idle memory
  vcpu = 4;                # ceiling - generous headroom, balloons down properly when idle
  memLowFloorMb   = 2048;  # elastic daemon: resting point, window open but idle
  memFloorMb      = 1536;  # elastic daemon: absolute floor, no windows open
  cpuLowFloorPct  = 200;   # elastic daemon: CPU floor while RAM still deflating (50% of ceiling)
  cpuFloorPct     = 20;    # elastic daemon: true CPU floor once RAM settled
}
