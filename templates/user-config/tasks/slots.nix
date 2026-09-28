# Expands tasks/default.nix into one attrset per slot. Shared by flake.nix and
# the files VM so every consumer agrees on CIDs, bridges and subnets.
#
# The 9-slot cap is structural: the host assigns TAPs to bridges by the glob
# mv-<network>*, so mv-task1* would also claim mv-task10, and mv-router-task10
# exceeds the 15-char interface name limit.
let
  cfg = import ./.;
  base = import (../profiles + "/${cfg.profile}/meta.nix");
in
  assert cfg.count <= 9 || throw "tasks/default.nix: count must be 9 or less";
    builtins.genList (i: let
      n = toString (i + 1);
      cid = cfg.baseCid + i;
    in {
      name = "task${n}";
      vsockCid = cid;
      subnet = "192.168.${toString cid}";
      bridge = "br-task${n}";
      tapId = "mv-task${n}";
      routerTap = "mv-router-task${n}";
      workspace = cfg.workspace or base.workspace;
      label = "TASK ${n}";
      focusBorder = cfg.focusBorder or (base.focusBorder or null);
      notifyForward = cfg.notifyForward or (base.notifyForward or false);
    })
    cfg.count
