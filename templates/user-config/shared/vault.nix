# Vault VM integration
#
# The KeepassXC DB lives in microvm-vault (CID 213) on a virtiofs-backed host
# directory (/var/lib/microvms/microvm-vault/vault-export/).
# Host tools communicate exclusively over vsock port 14514.
# Clipboard: wl-copy on host, auto-cleared after 30s.
#
# vault-pick   Interactive Wayland picker  (Mod+Shift+P)
# vault-cli    Programmatic CLI (unlock/lock/status/list/get/sync/pull)
#
# Gitsync sync path: vault-cli sync → gitsync VM SYNC command → git push
{ config, lib, pkgs, ... }:

{
  hydrix.vault.enable = true;

  imports = [
    ./vault-pick.nix
    ./vault-cli.nix
  ];

  # Ensure ~/vault/ exists on all machines (vault VM virtiofs source + git repo root).
  # Populated on new machines by: vault-cli pull (via gitsync VM).
  systemd.tmpfiles.rules = [
    "d /home/${config.hydrix.username}/vault 0755 ${config.hydrix.username} users -"
  ];
}
