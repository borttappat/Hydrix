# Infrastructure VM: nix builder for lockdown mode
# Gets internet through the router, mounts host /nix/store R/W via virtiofs
# Uses mkMicrovmBuilder (not mkInfraVm) — builtinVm = true
{
  vsockCid   = 210;
  label      = "BUILDER";
  hasDisplay = false;
  builtinVm  = true;
}
