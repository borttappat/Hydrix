# VM settings shared by every machine, keyed by VM name (hydrix.microvmHost.byName): each
# name resolves to that machine's own VM, so nothing here knows a serial. A machine config
# overrides with a plain assignment, e.g. `hydrix.microvmHost.byName.dev.repos = [];`.
#
# A suggested starting point, not a requirement. Machine configs keep what differs per
# machine: the router's WiFi secret, which VMs autostart, VMs one machine turns off.
#
# The git VM needs no entry: it gets the GitHub key and every repo with push = true
# (modules/repos.nix) automatically.
{lib, ...}: {
  hydrix.microvmHost.byName = {
    # The dev VM edits this config through a view (.git read-only) and holds no credential;
    # you review and commit on the host, the git VM pushes.
    dev.repos = ["hydrix-config"];

    # Pentest with an encrypted home and a notes repo (declare "notes" in modules/repos.nix):
    # pentest = {
    #   encryption = lib.mkDefault true;
    #   repos = ["notes"];
    # };

    # comms.encryption = lib.mkDefault true;
  };
}
