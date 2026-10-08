# Git VM (gitsync): pushes and pulls the host's clones, also from lockdown mode.
#
# Everything lives in Hydrix's hydrix.gitsync.agent (vm/microvm/infra/gitsync-agent.nix).
# Repos come from modules/repos.nix (every entry with push = true, shared from its host
# path), the GitHub key from secrets/github.yaml (the host stages it for this VM only).
# Set hydrix.gitsync.gh.enable = true to authenticate with `gh auth login` instead.
#
# Host commands:
#   shard git repos            List shared repos and their branch
#   shard git push <repo>      Push commits
#   shard git pull <repo>      Pull changes
#   shard git status <repo>    Show status + recent log
{...}: let
  meta = import ./meta.nix;
in {
  imports = [../../modules/repos.nix];

  microvm.vsock.cid = meta.vsockCid;
  microvm.interfaces = [
    {
      type = "tap";
      id = meta.tapId;
      mac = meta.tapMac;
    }
  ];

  hydrix.gitsync.agent.enable = true;
}
