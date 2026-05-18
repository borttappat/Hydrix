# Custom packages for comms profile
# Managed by vm-sync - regenerated when packages are added/removed
#
# Workflow:
#   1. In VM:  vm-dev build https://github.com/owner/repo
#   2. In VM:  vm-sync push --name repo
#   3. On host: vm-sync pull repo --target comms
#   4. Rebuild: microvm build microvm-comms
#
{ config, lib, pkgs, ... }:

{
  environment.systemPackages = [
    # Your packages here (added by vm-sync pull)
  ];
}
