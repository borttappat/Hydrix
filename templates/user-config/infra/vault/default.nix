# Vault Infra VM - KeePassXC password database
#
# The database lives in ~/vault on the host, shared here as /var/lib/vault (virtiofs,
# uid-squashed to the host user). Fully offline: no network interface at all.
#
# The agent is Hydrix's hydrix.vault.agent (vm/microvm/infra/vault-agent.nix): protocol v2
# over vsock 14514, served by shared/vault/backend.py as the vault user. The master password
# lives only in a tmpfs session (/run/vault-session), deleted on LOCK and after 5 minutes idle.
# Host frontends: `vault` (TUI) and `vault-pick` (Mod+P), via hydrix.passwords.backend = "vm".
{ config, lib, pkgs, ... }:
let
  meta         = import ./meta.nix;
  hostUsername = config.hydrix.username;
  vaultDir     = "/var/lib/vault";
in {
  microvm.vsock.cid = meta.vsockCid;

  # No network interface - vault stays fully offline
  microvm.interfaces = lib.mkForce [];
  networking.useDHCP = lib.mkForce false;
  networking.firewall.enable = lib.mkForce false;
  # No interfaces, so these have nothing to do; timesyncd keeps retrying its
  # unreachable servers on a ~30s cycle, which showed as periodic vCPU spikes.
  # Guest time follows the host through kvm-clock.
  networking.useNetworkd = lib.mkForce false;
  systemd.network.enable = lib.mkForce false;
  services.resolved.enable = lib.mkForce false;
  services.timesyncd.enable = lib.mkForce false;

  microvm.mem = lib.mkForce 512;

  # Vault data dir: virtiofs share of ~/vault/ on the host.
  # ~/vault/ already exists (git repo), gitsync mounts the same path.
  # A new machine gets the database by syncing ~/vault (plans/vault-rework.md, Step 5).
  microvm.shares = [{
    tag        = "vault-data";
    source     = "/home/${hostUsername}/vault";
    mountPoint = "${vaultDir}";
    proto      = "virtiofs";
    posixAcl   = false; # required by uid translation
    extraArgs  = config.hydrix.microvm.ownedShareArgs;
  }];

  boot.kernelModules = [ "vmw_vsock_virtio_transport" ];

  hydrix.vault.agent = {
    enable = true;
    database = "${vaultDir}/Passwords.kdbx";
  };

  users.users.vault = {

    # Same uid as the host owner of its writable share (uid translation).

    uid = config.hydrix.microvm.hostOwner.uid;
    isSystemUser = true;
    group        = "vault";
    home         = "/var/lib/vault";
  };
  users.groups.vault = {};

  services.getty.autologinUser = "root";

  environment.systemPackages = with pkgs; [ socat keepassxc coreutils gnugrep gnused ];

  users.motd = ''

  +-------------------------------------------------+
  |  HYDRIX VAULT VM                                |
  +-------------------------------------------------+
  |  KeePassXC database, offline, vsock 14514       |
  |                                                 |
  |  From the host:                                 |
  |    vault          TUI: list, copy, add, edit    |
  |    vault status   Locked or unlocked            |
  |    Mod+P          Quick picker                  |
  +-------------------------------------------------+

  '';
}
