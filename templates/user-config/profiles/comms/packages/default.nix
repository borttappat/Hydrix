# Custom packages for comms profile
#
# Every *.nix file in this directory except this one is a package expression
# `{ pkgs }: <derivation>`, installed in the VM. Nothing to list here: vm-sync pull drops
# files in this directory, and a file added by hand only needs `git add` so the flake sees it.
#
# Workflow:
#   1. In VM:   vm-dev build https://github.com/owner/repo
#   2. In VM:   vm-sync push --name repo
#   3. On host: vm-sync pull repo --target comms
#   4. Rebuild: shard -r comms
#
{
  lib,
  pkgs,
  ...
}: let
  packageFiles =
    lib.filterAttrs
    (name: type: type == "regular" && name != "default.nix" && lib.hasSuffix ".nix" name)
    (builtins.readDir ./.);
in {
  environment.systemPackages =
    lib.mapAttrsToList (name: _: import (./. + "/${name}") {inherit pkgs;}) packageFiles;
}
