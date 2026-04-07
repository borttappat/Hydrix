# Browsing VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 103;
  bridge    = "br-browse";
  tapId     = "mv-browse";
  routerTap = "mv-router-brow";  # ≤15 chars (Linux iface limit)
  subnet    = "192.168.103";     # /24 prefix — matches CID last octet
  workspace = 3;
  label     = "BROWSING";
  icon      = "";
}
