# Universal Base VM - Minimal image with core components
# This is the small image that gets built once
# VM will shape itself on first boot based on hostname
{ config, pkgs, lib, ... }:

{
  # Allow unfree firmware for hardware support
  nixpkgs.config.allowUnfree = true;

  imports = [
    # Base system configuration
    ../modules/base/nixos-base.nix
    ../modules/base/users.nix
    ../modules/base/networking.nix

    # VM-specific modules
    ../modules/vm/qemu-guest.nix
    ../modules/vm/shaping.nix

    # Core desktop environment (i3, fish, alacritty, etc.)
    ../modules/core.nix
  ];

  # Hostname will be set during VM deployment based on --type and --name flags
  # Example: "pentest-google", "comms-signal", "browsing-leisure", "dev-rust"

  # Minimal additional packages for bootstrapping
  # (core.nix already includes git, vim, wget, curl, htop)
  environment.systemPackages = with pkgs; [
    # Build tools needed for shaping
    nixos-rebuild

    # Network diagnostics
    inetutils
    nmap

    # VM rebuild script (detects type from hostname)
    (pkgs.writeScriptBin "nixbuild-vm" (builtins.readFile ../scripts/nixbuild-vm.sh))
  ];

  # Boot and filesystem config handled by nixos-generators format
}
