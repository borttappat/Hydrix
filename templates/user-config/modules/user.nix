# User Identity - Shared across all machines
#
# Settings here define WHO uses this system, not what hardware it runs on.
# All values use lib.mkDefault - machine configs override with plain assignment.
#
# Populated automatically by the installer. Edit here to change identity across all machines.

{ config, lib, pkgs, ... }@args:

let
  # Not a named module argument on purpose. The NixOS module system forces a
  # lookup for every named function arg (via _module.args), ignoring `?`
  # defaults, and this module is also imported by microVM builds (hostConfig)
  # that never supply machineName in their specialArgs. Reading it off the
  # ambient args bundle with `or` sidesteps that forced injection entirely.
  machineName = args.machineName or "unknown";
in
{
  hydrix.username    = lib.mkDefault "@USERNAME@";
  hydrix.hostname    = lib.mkDefault "hydrix";
  hydrix.colorscheme = lib.mkDefault "@COLORSCHEME@";

  # Window manager selection stays in machines/<serial>.nix, kept per-machine
  # so each machine can be tweaked independently without touching this shared file.

  # tailscale needs host internet access, which only the administrative
  # specialisation has (base/lockdown has no default gateway); set in
  # specialisations/administrative.nix instead, not as a shared default here.

  # ─── Password ──────────────────────────────────────────────────────────────
  # Generate with: mkpasswd -m sha-512
  # users.users.${config.hydrix.username}.hashedPassword = "$6$...";

  # ─── Git identity, scoped ONLY to ~/hydrix-config ──────────────────────────
  # Auto-derived per machine, no manual setup, no prompts. Sets the repo's
  # LOCAL .git/config (not the user's global ~/.gitconfig, which stays
  # untouched, real identity and any credential helpers included).
  # user.name is the machine's own name, so `git log` in hydrix-config shows
  # exactly which machine made each commit.
  home-manager.users.${config.hydrix.username} = { lib, pkgs, ... }: {
    home.activation.hydrixGitIdentity = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      repo="$HOME/hydrix-config"
      if [ -d "$repo/.git" ]; then
        $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$repo" config --local user.name "${machineName}"
        $DRY_RUN_CMD ${pkgs.git}/bin/git -C "$repo" config --local user.email "${config.hydrix.username}@${machineName}.hydrix.local"
      fi
    '';
  };
}
