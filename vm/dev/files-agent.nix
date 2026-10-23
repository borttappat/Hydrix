# Files Agent - per-VM vsock service for `shard files` transfers
#
# Imported by every profile VM (microvm-profile-base.nix) and by infra VMs
# whose meta.nix sets `filesAgent = true`. Listens on vsock 14506 for host
# commands; the data itself moves over port 8888 on the VM's bridge, to or
# from the files VM (.2 on this subnet) only, as an age-encrypted stream
# (see dev/xfer.py, `hydrix.microvm.xfer`).
#
# Commands (paths and names base64, relative to hydrix.files.agent.root):
#   PING                               -> PONG
#   SEND <age-recipient> <path>        listen on 8888, stream tar|zstd|age of
#                                      <path> to the files VM
#                                      -> LISTENING SIZE=<n>, then OK SHA256=<h> BYTES=<n>
#   RECV <id> <name> <dest>            second line: the age identity. Listen on
#     <identity>                       8888, decrypt and extract <name> into
#                                      staging -> LISTENING FREE=<n>, then OK SHA256=<h> ...
#   COMMIT <id> <sha256>               move the staged <name> to <dest>/<name>
#                                      if <sha256> matches what arrived -> OK
#   ABORT                              stop a running SEND/RECV, drop staging -> OK
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.files.agent;
  username = config.hydrix.username;
  userHome = "/home/${username}";
  vmType = config.hydrix.vmType;
  vmSubnet = config.hydrix.networking.vmSubnet;
  xfer = config.hydrix.microvm.xfer;
  state = "/run/hydrix-files-agent";

  # One command per vsock connection. Arguments go to the helper as
  # --opt=value, so nothing a field contains can become an option; the helper
  # validates every value.
  handlerScript = pkgs.writeShellScript "vm-files-handler" ''
    set -euo pipefail
    X() { ${xfer} --state ${state} "$@"; }
    read -r CMD A1 A2 A3 _ || exit 0

    case "$CMD" in
      PING)
        echo "PONG"
        ;;
      SEND)
        X abort --root ${cfg.root} >/dev/null || true
        X send --root ${cfg.root} --recipient="$A1" --path-b64="$A2" \
          --listen 8888 --allow ${vmSubnet}.2
        ;;
      RECV)
        X abort --root ${cfg.root} >/dev/null || true
        # The identity follows on the next line of this connection (stdin).
        X recv --root ${cfg.root} --id="$A1" --name-b64="$A2" --dest-b64="$A3" \
          --listen 8888 --allow ${vmSubnet}.2
        ;;
      COMMIT)
        X commit --root ${cfg.root} --id="$A1" --sha256="$A2"
        ;;
      ABORT)
        X abort --root ${cfg.root}
        ;;
      *)
        echo "ERROR: unknown command: $CMD"
        ;;
    esac
  '';
in {
  options.hydrix.files.agent = {
    root = lib.mkOption {
      type = lib.types.str;
      default = userHome;
      description = "Directory that `shard files` paths for this VM are relative to.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = username;
      description = "User the agent runs as; it reads and writes files under root as this user.";
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open port 8888 to the files VM (.2 on hydrix.networking.vmSubnet) in the
        iptables firewall. Turn off in VMs with their own nftables ruleset and
        allow that port there.
      '';
    };
  };

  config = lib.mkIf (vmType != "") {
    systemd.tmpfiles.rules =
      lib.optional (cfg.root == userHome) "d ${userHome}/shared 0750 ${username} users -";

    systemd.services.vm-files-agent = {
      description = "VM files agent (vsock 14506)";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "1s";
        User = cfg.user;
        RuntimeDirectory = "hydrix-files-agent";
        ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14506,reuseaddr,fork EXEC:${handlerScript}";
      };
    };

    networking.firewall.extraCommands = lib.mkIf (cfg.openFirewall && vmSubnet != "") ''
      iptables -A nixos-fw -p tcp --dport 8888 -s ${vmSubnet}.2 -j ACCEPT
    '';
  };
}
