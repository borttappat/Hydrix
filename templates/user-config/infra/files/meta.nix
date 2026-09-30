# Infrastructure VM: encrypted inter-VM file transfer hub
# CID 212, subnet 192.168.108.x — reserved, never use for profile VMs
# Accessed by host via vsock port 14505 (files agent)
{
  vsockCid      = 212;
  hasDisplay    = false;
  subnet        = "192.168.108";
  tapId         = "mv-files";
  tapMac        = "02:00:00:02:00:01";
  routerTap     = "mv-router-file";  # Router serves this subnet via extraNetworks dynamic wiring

  # Host-side TAP → bridge wiring, auto-discovered from profiles/*/meta.nix
  # and tasks/slots.nix (one isolated bridge per task slot).
  tapBridges =
    let
      profilesDir = ../../profiles;

      # `filesAccess = false;` in a profile's meta.nix keeps the files VM off
      # its bridge (same filter as validProfiles in ./default.nix)
      profileNames = builtins.filter
        (n: builtins.pathExists (profilesDir + "/${n}/meta.nix")
          && (import (profilesDir + "/${n}/meta.nix")).filesAccess or true)
        (builtins.attrNames (builtins.readDir profilesDir));

      abbrev4 = n: builtins.substring 0 4 n;
    in
    # Home bridge
    { "mv-files" = "br-files"; } //
    # Profile VM bridges (auto-discovered)
    builtins.listToAttrs (map (n: {
      name  = "mv-files-${abbrev4 n}";
      value = (import (profilesDir + "/${n}/meta.nix")).bridge;
    }) profileNames) //
    # Task slot bridges. TAP name: mv-files-task1 .. mv-files-task9 (15-char limit)
    builtins.listToAttrs (map (t: {
      name  = "mv-files-${t.name}";
      value = t.bridge;
    }) (import ../../tasks/slots.nix)) //
    # Infra VM bridges (explicit)
    { "mv-files-usb" = "br-usb-sandbox"; } //
    { "mv-files-hsy" = "br-hostsync"; };
}
