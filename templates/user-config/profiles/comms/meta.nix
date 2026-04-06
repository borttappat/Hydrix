# Comms VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 104;
  bridge    = "br-comms";
  tapId     = "mv-comms";
  routerTap = "mv-router-comm";  # ≤15 chars (Linux iface limit)
  subnet    = "192.168.102";     # /24 prefix, no trailing octet
  workspace = 4;
  label     = "COMMS";
  icon      = "";
}
