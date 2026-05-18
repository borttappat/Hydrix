# Custom packages for __NAME__ profile
# Managed by vm-sync — this file is regenerated when packages are added or removed.
# Do not add packages here manually; use vm-sync pull instead.
#
# Workflow:
#   1. In VM:   vm-dev build https://github.com/owner/repo
#   2. In VM:   vm-sync push --name repo
#   3. On host: vm-sync pull repo --target __NAME__
#   4. Rebuild: microvm build microvm-__NAME__
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = [
    # vm-sync managed packages
  ];
}
