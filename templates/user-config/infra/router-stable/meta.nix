# Infrastructure VM: immutable fallback router (auto-starts if main router fails)
# Same CID as router — only one router runs at a time
# Uses mkMicrovmRouterStable (not mkInfraVm) — builtinVm = true
{
  vsockCid   = 200;
  workspace  = 10;
  label      = "ROUTER";
  hasDisplay = false;
  builtinVm  = true;

  # Management TAP uses mv-rts-mgmt (stable router prefix)
  routerTap  = "mv-rts-mgmt";
  subnet     = "192.168.100";
}
