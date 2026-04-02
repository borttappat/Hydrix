# Common Configuration - Shared across all machines
#
# Settings here apply to ALL your machines.
# Machine-specific overrides go in machines/<serial>.nix
#
# To activate: uncomment the import in flake.nix:
#   modules = [ (machinesDir + "/${file}") ./shared/common.nix ];

{ config, lib, pkgs, ... }:

{
  # ─── Locale (shared across all machines) ──────────────────────────────
  # Populated automatically by the installer from your current system.
  # Change here to apply to all machines at once.
  hydrix.locale = {
    timezone     = "@TIMEZONE@";
    language     = "@LOCALE@";
    consoleKeymap = "@CONSOLE_KEYMAP@";
    xkbLayout    = "@XKB_LAYOUT@";
    xkbVariant   = "@XKB_VARIANT@";
  };

  # ─── VM color inheritance ──────────────────────────────────────────────
  # hydrix.colorschemeInheritance = "dynamic";  # DEFAULT: "dynamic"
  #   "full"    — VMs use all host wal colors
  #   "dynamic" — VMs use host background + their own text colors
  #   "none"    — VMs use their own colorscheme independently

  # ─── Packages on every machine ────────────────────────────────────────
  environment.systemPackages = with pkgs; [
  #   git
  #   neovim
  #   ripgrep
  ];

  # ─── User groups on every machine ─────────────────────────────────────
  # users.users.${config.hydrix.username}.extraGroups = [ "libvirtd" "kvm" ];

  # ─── Services on every machine ────────────────────────────────────────
  # services.tailscale.enable = true;
  # services.openssh.enable = true;
}
