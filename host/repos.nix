# Host side of hydrix.repos (options: shared/repos-options.nix).
#
# The host holds every clone and makes every commit, but no GitHub credential: the git VM
# (gitsync) is the only machine that talks to GitHub, in every boot mode. ensure-repos asks
# it to clone (`shard git clone <name>`, the agent's CLONE) each entry with clone = true
# whose path is empty; existing clones are never pulled or overwritten. Every entry's
# directory exists from activation on, because the git VM and VM views share it (virtiofsd
# needs the source when the VM starts), and an empty directory is cloned into.
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
  vms = config.hydrix.microvmHost.vms;
  gitVm = config.hydrix.microvmHost.vmNames.gitsync;
  cloned = lib.filterAttrs (_: e: e.clone && e.push) cfg.entries;
  notShared = lib.attrNames (lib.filterAttrs (_: e: e.clone && !e.push) cfg.entries);

  # Interactive (starting the git VM asks for sudo), run by the owner after install or
  # after declaring a repo.
  ensureRepos = pkgs.writeShellApplication {
    name = "ensure-repos";
    runtimeInputs = with pkgs; [coreutils systemd];
    text = ''
      log() { echo "[ensure-repos] $*"; }

      missing=()
      ${lib.concatStrings (lib.mapAttrsToList (name: e: ''
          if [[ -n "$(ls -A ${lib.escapeShellArg e.path} 2>/dev/null)" ]]; then
            log ${lib.escapeShellArg "${name} already exists at ${e.path}"}
          else
            missing+=(${lib.escapeShellArg name})
          fi
        '')
        cloned)}
      ${lib.concatMapStrings (n: ''
          log ${lib.escapeShellArg "${n}: push = false, so the git VM cannot clone it; clone it yourself"}
        '')
        notShared}
      if [[ ''${#missing[@]} -eq 0 ]]; then
        log "Nothing to clone"
        exit 0
      fi

      log "Cloning through the git VM: ''${missing[*]}"
      we_started=false
      if ! systemctl is-active --quiet "microvm@${gitVm}.service"; then
        shard -s ${gitVm}
        we_started=true
      fi
      failed=0
      for name in "''${missing[@]}"; do
        shard git clone "$name" || failed=$((failed + 1))
      done
      if [[ "$we_started" == true ]]; then
        shard -S ${gitVm}
      fi
      if [[ $failed -gt 0 ]]; then
        log "$failed repo(s) not cloned (see above)"
        exit 1
      fi
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
      environment.systemPackages = [ensureRepos];
    })
  ];
}
