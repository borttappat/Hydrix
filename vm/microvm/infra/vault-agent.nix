# Vault agent (hydrix.vault.agent): serves the password database over vsock with the shared
# protocol v2 backend (shared/vault/backend.py). Every connection runs one request as the
# vault user. The master password lives only in a 1 MB tmpfs (/run/vault-session), deleted
# on LOCK and after lockTimeout seconds idle (checked every minute).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.vault.agent;
  backend = import ../../../shared/vault/package.nix {inherit pkgs;};
  sessionDir = "/run/vault-session";
  args = "--db ${lib.escapeShellArg cfg.database} --session-file ${sessionDir}/token --timeout ${toString cfg.lockTimeout}";
  # socat's EXEC address gets a single path; the arguments live here.
  handler = pkgs.writeShellScript "vault-agent-handler" "exec ${backend}/bin/hydrix-vault-backend ${args}";
in {
  options.hydrix.vault.agent = {
    enable = lib.mkEnableOption "the vault agent (vsock password database service)";
    database = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/vault/Passwords.kdbx";
      description = "KeePassXC database path inside the VM.";
    };
    lockTimeout = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Seconds of inactivity before the session is deleted (locked).";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "vault";
      description = "User the agent runs requests as; owns the session and the database.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.mounts = [
      {
        what = "tmpfs";
        where = sessionDir;
        type = "tmpfs";
        options = "size=1m,mode=700,uid=${toString config.users.users.${cfg.user}.uid}";
        wantedBy = ["local-fs.target"];
      }
    ];

    systemd.services.vault-agent = {
      description = "Vault agent (vsock ${toString config.hydrix.networking.vsockPorts.vaultAgent})";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      # By path: the mount unit's name is escaped (run-vault\x2dsession.mount).
      unitConfig.RequiresMountsFor = [sessionDir];
      serviceConfig = {
        Restart = "always";
        RestartSec = "2s";
        # -t: after the client finishes sending, wait for the reply instead of the
        # default 0.5 s (keepassxc-cli needs longer to open the database).
        ExecStart = "${pkgs.socat}/bin/socat -t60 VSOCK-LISTEN:${toString config.hydrix.networking.vsockPorts.vaultAgent},reuseaddr,fork,max-children=4 EXEC:${handler},su=${cfg.user}";
      };
    };

    systemd.services.vault-auto-lock = {
      description = "Delete an idle vault session";
      unitConfig.RequiresMountsFor = [sessionDir];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = "${backend}/bin/hydrix-vault-backend ${args} --expire";
      };
    };
    systemd.timers.vault-auto-lock = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
