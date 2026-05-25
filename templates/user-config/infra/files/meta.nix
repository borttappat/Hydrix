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

  # Host-side TAP → bridge wiring — auto-discovered from profiles/*/meta.nix
  # and tasks/*/meta.nix (for task VMs with custom isolated bridges).
  tapBridges =
    let
      profilesDir = ../../profiles;
      tasksDir    = ../../tasks;

      profileNames = builtins.filter
        (n: builtins.pathExists (profilesDir + "/${n}/meta.nix"))
        (builtins.attrNames (builtins.readDir profilesDir));

      taskNames = if builtins.pathExists tasksDir
        then builtins.filter
          (n: builtins.match "task[0-9]+" n != null
            && builtins.pathExists (tasksDir + "/${n}/meta.nix"))
          (builtins.attrNames (builtins.readDir tasksDir))
        else [];

      # Bridges already reachable via profile TAPs — don't add redundant task TAPs
      coveredBridges = map (n: (import (profilesDir + "/${n}/meta.nix")).bridge) profileNames;

      # Tasks with custom bridges not already covered by a profile TAP
      tasksNeedingTap = builtins.filter (n:
        !(builtins.elem (import (tasksDir + "/${n}/meta.nix")).bridge coveredBridges))
        taskNames;

      abbrev4 = n: builtins.substring 0 4 n;
    in
    # Home bridge
    { "mv-files" = "br-files"; } //
    # Profile VM bridges (auto-discovered)
    builtins.listToAttrs (map (n: {
      name  = "mv-files-${abbrev4 n}";
      value = (import (profilesDir + "/${n}/meta.nix")).bridge;
    }) profileNames) //
    # Task VM custom bridges (only tasks whose bridge isn't already covered above)
    # TAP name: mv-files-task1, mv-files-task2, etc. (max 15 chars, fits task1–task9)
    builtins.listToAttrs (map (n: {
      name  = "mv-files-${n}";
      value = (import (tasksDir + "/${n}/meta.nix")).bridge;
    }) tasksNeedingTap) //
    # Infra VM bridges (explicit)
    { "mv-files-usb" = "br-usb-sandbox"; } //
    { "mv-files-hsy" = "br-hostsync"; };
}
