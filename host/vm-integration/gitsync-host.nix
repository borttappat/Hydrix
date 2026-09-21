# Git-Sync Host Module - Host-side support for the git-sync microVM
#
# The git-sync VM allows pushing/pulling git repos in lockdown mode
# without the host needing internet access.
#
# Usage from host:
#   shard git repos          List available repos
#   shard git push <repo>    Push commits
#   shard git pull <repo>    Pull changes
#   shard git status <repo>  Show repo status
#   shard git auth           Interactive gh auth login
#
# This module enables the required host-side packages.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.gitsync;
in {
  config = lib.mkIf cfg.enable {
    # Ensure socat is available for vsock communication
    environment.systemPackages = [pkgs.socat];
  };
}
