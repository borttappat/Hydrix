# Core Packages - User-configured packages
#
# This file is intentionally empty. Package decisions belong in the user's
# hydrix-config, not in the framework.
#
# Users should create shared/host-packages.nix and shared/vm-packages.nix
# in their hydrix-config to define what packages are installed.
#
# See templates/user-config/ for examples.
#
{ config, pkgs, lib, ... }:

{
  # Packages, environment variables, and theming are configured
  # in the user's hydrix-config (shared/host-packages.nix)
}
