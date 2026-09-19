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
  vcpu = 2;                # ceiling
  memLowFloorMb   = 2048;  # elastic daemon: resting point, window open but idle
  memFloorMb      = 1536;  # elastic daemon: absolute floor, no windows open
  cpuLowFloorPct  = 60;    # elastic daemon: CPU floor while RAM still deflating
  cpuFloorPct     = 20;    # elastic daemon: true CPU floor once RAM settled
}
