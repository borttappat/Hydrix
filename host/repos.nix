# Host side of hydrix.repos (options: shared/repos-options.nix).
#
# The host holds every clone. ensure-repos clones each entry with clone = true whose path is
# missing or empty (gh over HTTPS when authenticated, else the SSH key); existing clones are
# never pulled or overwritten. Every entry's directory exists from boot, because the git VM
# and VM views share it (virtiofsd needs the source), and an empty directory is cloned into.
#
# Guards for the git boundary: VMs name repos through microvmHost.vms.<vm>.repos, and only
# hydrix.secrets.github.vms (the git VM) holds the GitHub key.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.repos;
  username = config.hydrix.username;
  homeDir = "/home/${username}";
  vms = config.hydrix.microvmHost.vms;
  cloned = lib.filterAttrs (_: e: e.clone) cfg.entries;

  ensureRepos = pkgs.writeShellApplication {
    name = "ensure-repos";
    runtimeInputs = with pkgs; [coreutils git gh openssh];
    text = ''
      log() { echo "[ensure-repos] $*"; }

      clone_repo() {
        local name="$1" https_url="$2" ssh_url="$3" path="$4"

        # An existing empty directory (created at boot for the git VM's share) is cloned
        # into; anything else already there is left alone.
        if [[ -d "$path" ]] && [[ -n "$(ls -A "$path" 2>/dev/null)" ]]; then
          log "$name already exists at $path"
          return 0
        fi

        log "Cloning $name to $path..."
        if [[ -n "$https_url" ]] && gh auth status &>/dev/null; then
          log "Using gh CLI (HTTPS)..."
          gh repo clone "$https_url" "$path" && return 0
        fi
        if [[ -n "$ssh_url" ]] && { [[ -f "${homeDir}/.ssh/id_ed25519" ]] || [[ -f "${homeDir}/.ssh/id_rsa" ]]; }; then
          log "Using SSH..."
          GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git clone "$ssh_url" "$path" && return 0
        fi
        log "Warning: failed to clone $name (no gh auth or SSH key, or no URL)"
        return 1
      }

      ${lib.concatStrings (lib.mapAttrsToList (name: e: ''
          clone_repo ${lib.escapeShellArgs [name (toString e.url) (toString e.sshUrl) e.path]} || true
        '')
        cloned)}
      log "Done"
    '';
  };

  unknownRepos = lib.concatLists (lib.mapAttrsToList (vm: v:
    map (r: "${vm}: ${r}") (lib.filter (r: !(cfg.entries ? ${r})) v.repos))
  vms);
  handGithub = lib.attrNames (lib.filterAttrs (_: v: builtins.elem "github" v.secrets) vms);
in {
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = unknownRepos == [];
          message = "microvmHost.vms.<vm>.repos names repos missing from hydrix.repos.entries: ${lib.concatStringsSep ", " unknownRepos}";
        }
        {
          assertion = handGithub == [];
          message = ''
            "github" is listed in microvmHost.vms.<vm>.secrets for ${lib.concatStringsSep ", " handGithub}.
            The GitHub key goes to hydrix.secrets.github.vms (the git VM by default) automatically;
            remove it from secrets, and add a VM to hydrix.secrets.github.vms only if it must push.
          '';
        }
      ];
    }

    {
      # Shares (git VM, VM views) need their source to exist before any clone. Only a
      # missing path is created; an existing clone keeps its owner and mode.
      system.activationScripts.hydrix-repo-dirs = lib.mkIf (cfg.entries != {}) {
        deps = ["users"];
        text = lib.concatStrings (lib.mapAttrsToList (_: e: ''
            [ -e ${lib.escapeShellArg e.path} ] || install -d -o ${username} -g users -m 0755 ${lib.escapeShellArg e.path}
          '')
          cfg.entries);
      };
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [pkgs.gh ensureRepos];

      systemd.services.hydrix-ensure-repos = {
        description = "Clone declared git repos (hydrix.repos.entries)";
        after = ["network-online.target" "local-fs.target"];
        wants = ["network-online.target"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = username;
          ExecStart = "${ensureRepos}/bin/ensure-repos";
        };
      };
    })
  ];
}
