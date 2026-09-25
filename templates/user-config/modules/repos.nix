# Declarative Git Repositories
#
# hydrix.repos.entries declares repos that should be cloned once present on a
# machine or VM. Missing repos are cloned on boot; existing ones are left
# alone (never pulled/overwritten automatically).
#
# Authentication (tried in order):
#   1. gh CLI  - run `gh auth login` once after first boot
#   2. SSH key - ~/.ssh/id_ed25519 or ~/.ssh/id_rsa (on VMs, provisioned by
#      hydrix.secrets.github via vms.<name>.secrets = ["github"])
#   3. Warning logged, repo skipped (no error thrown)
#
# Import this file and set hydrix.repos.enable = true; an empty `entries`
# attrset is a valid no-op, so it's safe to import speculatively.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.repos;
  username = config.hydrix.username;
  homeDir = "/home/${username}";

  ensureReposScript = pkgs.writeShellScriptBin "ensure-repos" ''
    set -e

    log() { echo "[ensure-repos] $*"; }

    gh_authenticated() {
      ${pkgs.gh}/bin/gh auth status &>/dev/null
    }

    clone_repo() {
      local name="$1"
      local https_url="$2"
      local ssh_url="$3"
      local path="$4"

      if [[ -d "$path" ]]; then
        log "$name already exists at $path"
        return 0
      fi

      log "Cloning $name to $path..."

      if gh_authenticated; then
        log "Using gh CLI (HTTPS)..."
        ${pkgs.gh}/bin/gh repo clone "$https_url" "$path" && return 0
      fi

      if [[ -f "${homeDir}/.ssh/id_ed25519" ]] || [[ -f "${homeDir}/.ssh/id_rsa" ]]; then
        log "Using SSH..."
        GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new" \
          ${pkgs.git}/bin/git clone "$ssh_url" "$path" && return 0
      fi

      log "Warning: Failed to clone $name (no gh auth or SSH key found)"
      return 1
    }

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: repo: ''
        clone_repo "${name}" "${repo.url}" "${repo.sshUrl}" "${repo.path}" || true
      '')
      cfg.entries)}

    log "Done"
  '';
in {
  options.hydrix.repos = {
    enable = lib.mkEnableOption "declarative git repo cloning";

    entries = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "HTTPS clone URL, used with gh CLI when authenticated.";
          };
          sshUrl = lib.mkOption {
            type = lib.types.str;
            description = "SSH clone URL, used when gh isn't authenticated.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            description = "Absolute path to clone into.";
          };
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
        };
      });
      default = {};
      description = "Repos to keep cloned. Missing entries are cloned on boot; existing ones are untouched.";
      example = lib.literalExpression ''
        {
          my-notes = {
            url = "https://github.com/youruser/my-notes.git";
            sshUrl = "git@github.com:youruser/my-notes.git";
            path = "/home/youruser/my-notes";
            description = "Personal notes";
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [gh ensureReposScript];

    # network-online.target ordering matters on VMs: their network comes up
    # through the router after boot, unlike an activation script (which runs
    # before systemd starts any units and would race a cold boot).
    systemd.services.hydrix-ensure-repos = {
      description = "Clone declared git repos (hydrix.repos.entries)";
      after = ["network-online.target" "local-fs.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = username;
        ExecStart = "${ensureReposScript}/bin/ensure-repos";
      };
    };
  };
}
