# __NAME_CAP__ VM identity — read by flake.nix at eval time
# All values here flow into vmRegistry → /etc/hydrix/vm-registry.json
#
# Convention: vsockCid = subnet last octet = workspace number.
# Avoid reserved CIDs: 200 (router), 210 (builder), 211 (gitsync).
{
  vsockCid  = __CID__;
  bridge    = "__BRIDGE__";
  tapId     = "__TAP_ID__";
  routerTap = "__ROUTER_TAP__";  # ≤15 chars (Linux iface limit)
  subnet    = "__SUBNET__";      # /24 prefix — matches CID last octet
  workspace = __WORKSPACE__;
  label     = "__LABEL__";
  icon      = "";
}
