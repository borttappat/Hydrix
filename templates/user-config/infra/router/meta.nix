# Infrastructure VM: WiFi VFIO passthrough router
# CID 200 — reserved, never use for profile VMs
# Uses mkMicrovmRouter (not mkInfraVm) — builtinVm = true
{
  vsockCid   = 200;
  storeTier  = "infra"; # runs from the infra store tier, built by builder-infra (remove: host store; router-stable always stays there)
  workspace  = 10;
  label      = "ROUTER";
  hasDisplay = false;
  builtinVm  = true;

  # Management network — host↔router communication
  routerTap  = "mv-router-mgmt";
  subnet     = "192.168.100";
}
