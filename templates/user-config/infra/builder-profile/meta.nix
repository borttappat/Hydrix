# Infrastructure VM: builder for the profile store tier
# Builds profile VMs whose meta.nix sets storeTier = "profile" into
# /var/lib/hydrix/stores/profile, never into the host store. Its own system boots from a
# view of its closure in the host store (read-only); it can run while the host
# nix-daemon does.
# Uses mkMicrovmBuilder (not mkInfraVm), builtinVm = true
{
  vsockCid = 216;
  label = "BUILDER-PROFILE";
  hasDisplay = false;
  builtinVm = true;
  buildsTier = "profile";

  # Shares the builder network (TAP mv-build* attaches to br-builder)
  bridge = "br-builder";
  tapId = "mv-build-prof";
  tapMac = "02:00:00:02:16:01";
  subnet = "192.168.210";
}
