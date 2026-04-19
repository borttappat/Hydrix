# Infrastructure VM: encrypted inter-VM file transfer hub
# CID 212, subnet 192.168.108.x — reserved, never use for profile VMs
# Accessed by host via vsock port 14505 (files agent)
{
  vsockCid      = 212;
  subnet        = "192.168.108";
  tapId         = "mv-files";
  tapMac        = "02:00:00:02:00:01";
  # No routerTap — files uses a built-in subnet (192.168.108.x), already wired in the router VM.
  # Only user-defined infra VMs with NEW subnets need routerTap.

  # Host-side TAP → bridge wiring — auto-discovered from profiles/*/meta.nix
  tapBridges =
    let
      profilesDir = ../../profiles;
      names = builtins.attrNames (builtins.readDir profilesDir);
      valid = builtins.filter (n: builtins.pathExists (profilesDir + "/${n}/meta.nix")) names;
      abbrev = n: builtins.substring 0 4 n;
    in
    # Home bridge + profile VM bridges (auto-discovered)
    { "mv-files" = "br-files"; } //
    builtins.listToAttrs (map (n: {
      name  = "mv-files-${abbrev n}";
      value = (import (profilesDir + "/${n}/meta.nix")).bridge;
    }) valid) //
    # Infra VM bridges (explicit — not profile VMs)
    # usb-sandbox's main TAP stays isolated on br-usb-sandbox
    # files VM's mv-files-usb TAP connects to br-usb-sandbox for direct VM-to-VM communication
    { "mv-files-usb" = "br-usb-sandbox"; };
}
