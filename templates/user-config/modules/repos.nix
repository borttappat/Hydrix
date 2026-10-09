# Git repos: one declaration per repo (options: Hydrix shared/repos-options.nix).
#
# Imported by every machine (flake.nix) and by the git VM (infra/gitsync), so a repo listed
# here is:
#   - cloned into its host path by the git VM when that is empty (`ensure-repos`, by hand;
#     existing clones are never pulled or overwritten),
#   - pushed and pulled by the git VM (`shard git push|pull|fetch|status <name>`), unless
#     push = false,
#   - shared with a VM only when hydrix.microvmHost.byName.<vm>.repos names it (modules/vms.nix:
#     working tree read-write, .git and .claude read-only on the host side; the VM edits, the
#     host commits, the git VM pushes).
#
# Credentials: only the git VM holds the GitHub key (hydrix.secrets.githubSecretsFile in the
# machine config, see its SECRETS section). The host has none and needs none, in lockdown too.
#
# Defaults per entry: url github.com/<owner>/<name>, path ~/<name>, clone = true, push = true.
#
# A suggested starting point, not a requirement: this config itself is declared, so the git VM
# can push it from lockdown once it has a remote, and modules/vms.nix shares it with the dev VM. Remove or add entries freely; an empty entries set is a valid no-op.
{lib, ...}: {
  hydrix.repos = {
    enable = lib.mkDefault true;
    # owner = "youruser";                  # GitHub user/organisation for default URLs
    entries = {
      # This repo: pushed by the git VM (`shard git push hydrix-config`), edited from the dev
      # VM. Already cloned by the installer; with owner set, ensure-repos gives it its origin
      # and clones it into an empty ~/hydrix-config on a new machine.
      hydrix-config = {};
      # notes = { description = "Personal notes"; };
      # site = {
      #   url = "https://github.com/youruser/youruser.github.io.git";
      #   sshUrl = "git@github.com:youruser/youruser.github.io.git";
      #   path = "/home/youruser/website";
      # };
      # vault = { clone = false; };        # password database (hydrix.passwords); clone = true
      #                                    # once its PRIVATE remote exists
      # scratch = { push = false; };       # cloned on the host, never shared with the git VM
    };
  };
}
