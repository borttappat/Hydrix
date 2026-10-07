# hydrix-vault-backend: the protocol v2 backend (backend.py), shared by the vault VM agent
# and the host backend. One request on stdin, one reply on stdout.
{pkgs}:
pkgs.writeTextFile {
  name = "hydrix-vault-backend";
  executable = true;
  destination = "/bin/hydrix-vault-backend";
  text =
    "#!${pkgs.python3}/bin/python3\n"
    + builtins.replaceStrings ["@keepassxc_cli@"] ["${pkgs.keepassxc}/bin/keepassxc-cli"] (builtins.readFile ./backend.py);
}
