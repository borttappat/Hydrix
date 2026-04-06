# Lurking VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
{
  vsockCid  = 105;
  bridge    = "br-lurking";
  tapId     = "mv-lurking";
  routerTap = "mv-router-lurk";  # ≤15 chars (Linux iface limit)
  subnet    = "192.168.107";     # /24 prefix, no trailing octet
  workspace = 6;
  label     = "LURKING";
  icon      = "";
}
