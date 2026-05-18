# Lurking VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 106;
  bridge    = "br-lurking";
  tapId     = "mv-lurking";
  routerTap = "mv-router-lurk";  # ≤15 chars (Linux iface limit)
  subnet    = "192.168.106";     # /24 prefix — matches CID last octet
  workspace = 6;
  label     = "LURKING";
  icon      = "";
}
