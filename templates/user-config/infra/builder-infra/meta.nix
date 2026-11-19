# Infrastructure VM: builder for the infra store tier
# Builds infra VMs whose meta.nix sets storeTier = "infra" into
# /var/lib/hydrix/stores/infra, never into the host store. Its own system boots from a
# view of its closure in the host store (read-only); it can run while the host
# nix-daemon does. router-stable and the builders stay on the host store.
# Uses mkMicrovmBuilder (not mkInfraVm), builtinVm = true
{
  vsockCid = 217;
  label = "BUILDER-INFRA";
  hasDisplay = false;
  builtinVm = true;
  buildsTier = "infra";

  # Shares the builder network (TAP mv-build* attaches to br-builder)
  bridge = "br-builder";
  tapId = "mv-build-infra";
  tapMac = "02:00:00:02:17:01";
  subnet = "192.168.210";
}
