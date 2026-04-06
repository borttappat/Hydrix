# Dev VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 103;
  bridge    = "br-dev";
  tapId     = "mv-dev";
  routerTap = "mv-router-dev";   # ≤15 chars (Linux iface limit)
  subnet    = "192.168.104";     # /24 prefix, no trailing octet
  workspace = 5;
  label     = "DEV";
  icon      = "";
}
