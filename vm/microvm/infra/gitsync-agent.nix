# Git VM agent (hydrix.gitsync.agent): pushes, pulls and fetches the host's clones on the
# host's command, from lockdown mode too (the VM reaches GitHub through the router).
#
# Repos: every hydrix.repos.entries entry with push = true, shared from its host path at
# /mnt/repos/<name> (uid-squashed to the host user, no mknod/setfcap). Credentials: the
# GitHub SSH key the host stages into /mnt/vm-secrets/ssh (hydrix.secrets.github.vms), copied
# fresh on every boot; or `gh auth login` with hydrix.gitsync.gh.enable.
#
# vsock 14512 (one command per connection, from `shard git`):
#   CLONE|PUSH|PULL|FETCH|STATUS|SYNC <repo>, REPOS, PING
# CLONE fills the host's empty directory for a declared repo: the host holds no GitHub
# credential, so this is how ensure-repos clones.
# vsock 14513: BUSY/IDLE, answers only once the network is up (the host's readiness gate).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hydrix.gitsync;
  repos = lib.filterAttrs (_: e: e.push) config.hydrix.repos.entries;
  repoNames = lib.attrNames repos;

  # name|url per repo for CLONE (sshUrl first: the key is what this VM authenticates with).
  cloneUrls = pkgs.writeText "gitsync-clone-urls" (lib.concatStrings (lib.mapAttrsToList (name: e: let
    url =
      if e.sshUrl != null
      then e.sshUrl
      else e.url;
  in
    lib.optionalString (url != null) "${name}|${url}\n")
  repos));

  gitHandler = pkgs.writeShellScript "gitsync-vsock-handler" ''
    export PATH="${lib.makeBinPath (with pkgs; [coreutils git openssh glibc.bin util-linux])}:$PATH"
    export HOME="/home/gitsync"

    read -r cmd rest

    # Only declared repos, by exact name.
    repo_dir() {
      local known=""
      for name in ${lib.escapeShellArgs repoNames}; do
        [ "$name" = "$1" ] && known=1
      done
      if [ -z "$known" ]; then echo "ERROR repo not found: $1"; exit 0; fi
      repo_path="/mnt/repos/$1"
      if [ ! -d "$repo_path/.git" ]; then echo "ERROR not a git repo yet: $1"; exit 0; fi
      cd "$repo_path" || { echo "ERROR cannot enter $1"; exit 0; }
    }

    # A branch without an upstream (a fresh config's first push) pushes to origin and
    # tracks it from then on.
    push() {
      if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        git push 2>&1
      else
        git push -u origin HEAD 2>&1
      fi
    }

    case "$cmd" in
      PUSH)
        repo_dir "$rest"
        echo "OK pushing $rest"
        if push; then echo "DONE"; else echo "ERROR push failed"; fi
        ;;
      PULL)
        repo_dir "$rest"
        echo "OK pulling $rest"
        if git pull 2>&1; then echo "DONE"; else echo "ERROR pull failed"; fi
        ;;
      FETCH)
        repo_dir "$rest"
        echo "OK fetching $rest"
        if git fetch --all 2>&1; then echo "DONE"; else echo "ERROR fetch failed"; fi
        ;;
      STATUS)
        repo_dir "$rest"
        echo "OK status for $rest"
        echo "--- git status ---"
        git status --short 2>&1
        echo "--- recent commits ---"
        git log --oneline -5 2>&1
        echo "--- remote ---"
        git remote -v 2>&1
        echo "DONE"
        ;;
      REPOS)
        echo "OK available repos"
        for name in ${lib.escapeShellArgs repoNames}; do
          repo_path="/mnt/repos/$name"
          if [ -d "$repo_path/.git" ]; then
            branch=$(cd "$repo_path" && git branch --show-current 2>/dev/null || echo "unknown")
            echo "  $name ($branch)"
          else
            echo "  $name (not a git repo)"
          fi
        done
        echo "DONE"
        ;;
      CLONE)
        # Into the host's empty directory only: never over an existing clone or files.
        repo_path="/mnt/repos/$rest"
        known=""
        for name in ${lib.escapeShellArgs repoNames}; do
          [ "$name" = "$rest" ] && known=1
        done
        if [ -z "$known" ]; then echo "ERROR repo not found: $rest"; exit 0; fi
        url=""
        while IFS='|' read -r n u; do
          [ "$n" = "$rest" ] && url="$u"
        done < ${cloneUrls}
        if [ -z "$url" ]; then echo "ERROR no URL declared for $rest"; exit 0; fi
        # The share exists only if the host directory did when this VM started.
        if ! mountpoint -q "$repo_path"; then echo "ERROR $rest is not shared from the host yet (restart the git VM)"; exit 0; fi
        if [ -n "$(ls -A "$repo_path" 2>/dev/null)" ]; then echo "ERROR $rest is not empty on the host"; exit 0; fi
        echo "OK cloning $rest"
        if git clone --quiet "$url" "$repo_path" 2>&1; then echo "DONE"; else echo "ERROR clone failed"; fi
        ;;
      SYNC)
        # Commit all changes then push (vault sync)
        repo_dir "$rest"
        echo "OK syncing $rest"
        git add -A
        if ! git diff --cached --quiet; then
          git commit -m "sync $(date +%Y-%m-%dT%H:%M)" 2>&1
        else
          echo "(nothing to commit)"
        fi
        if push; then echo "DONE"; else echo "ERROR push failed"; fi
        ;;
      PING)
        echo "PONG"
        ;;
      *)
        echo "ERROR unknown command: $cmd"
        echo "Commands: CLONE <repo>, PUSH <repo>, PULL <repo>, FETCH <repo>, SYNC <repo>, STATUS <repo>, REPOS, PING"
        ;;
    esac
  '';

  statusHandler = pkgs.writeShellScript "gitsync-status-handler" ''
    read -r cmd
    if ${pkgs.procps}/bin/pgrep -x "git" > /dev/null; then echo "BUSY"; else echo "IDLE"; fi
  '';

  motdLines =
    [
      ""
      "+-------------------------------------------------+"
      "|  HYDRIX GIT VM                                  |"
      "+-------------------------------------------------+"
      "|  Push/pull the host's repos, also in lockdown   |"
      "|                                                 |"
    ]
    ++ lib.optionals cfg.gh.enable [
      "|  First time:  gh auth login                     |"
    ]
    ++ [
      "|  Commands from host (via shard git):            |"
      "|    shard git repos          List repos          |"
      "|    shard git push <repo>    Push commits        |"
      "|    shard git pull <repo>    Pull changes        |"
      "|    shard git status <repo>  Show status         |"
      "+-------------------------------------------------+"
      ""
    ];
in {
  options.hydrix.gitsync = {
    agent.enable = lib.mkEnableOption "the git VM agent (push/pull hydrix.repos entries for the host)";

    gh.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the gh CLI in the git VM and give it a small persistent volume for its
        OAuth token, so `gh auth login` survives restarts. Off by default: push/pull only
        needs the SSH key, which is copied fresh from the host's secrets on every boot.
      '';
    };
  };

  config = lib.mkIf cfg.agent.enable {
    # Above the infra base default (mkDefault 1024), below a plain assignment in the VM file.
    microvm.mem = lib.mkOverride 900 2560;
    microvm.virtiofsd.threadPoolSize = 1;

    microvm.shares =
      lib.mapAttrsToList (name: e: {
        tag = "repo-${name}";
        source = e.path;
        mountPoint = "/mnt/repos/${name}";
        proto = "virtiofs";
        posixAcl = false; # required by uid translation
        extraArgs = config.hydrix.microvm.ownedShareArgs;
      })
      repos;

    # Ephemeral apart from gh's token: the SSH key comes from the host on every boot.
    microvm.volumes = lib.mkForce (lib.optionals cfg.gh.enable [
      {
        image = "/var/lib/microvms/${config.networking.hostName}/gh-config.qcow2";
        mountPoint = "/var/lib/gitsync/gh-config";
        size = 64;
        autoCreate = true;
      }
    ]);

    boot.kernelModules = ["vmw_vsock_virtio_transport"];

    users.users.gitsync = {
      # Same uid as the host owner of its writable shares (uid translation).
      uid = config.hydrix.microvm.hostOwner.uid;
      isNormalUser = true;
      extraGroups = ["wheel"];
      password = "gitsync";
      home = "/home/gitsync";
    };
    services.getty.autologinUser = "gitsync";
    services.haveged.enable = true;

    environment.systemPackages = with pkgs; [git openssh socat vim] ++ lib.optionals cfg.gh.enable [gh];

    environment.etc."gitconfig".text = ''
      [safe]
      ${lib.concatMapStrings (n: "  directory = /mnt/repos/${n}\n") repoNames}[url "git@github.com:"]
        insteadOf = https://github.com/
    '';

    systemd.services.gitsync-setup = {
      description = "Set up the git VM's SSH directory";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      before = ["gitsync-vsock.service"];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      script = ''
        mkdir -p /var/lib/gitsync/ssh
        ln -sfn /var/lib/gitsync/ssh /home/gitsync/.ssh

        ${lib.optionalString cfg.gh.enable ''
          mkdir -p /var/lib/gitsync/gh-config /home/gitsync/.config
          ln -sfn /var/lib/gitsync/gh-config /home/gitsync/.config/gh
          chown -R gitsync:users /home/gitsync/.config /var/lib/gitsync/gh-config
        ''}
        if [ -f "/mnt/vm-secrets/ssh/id_ed25519" ]; then
          cp /mnt/vm-secrets/ssh/id_ed25519 /var/lib/gitsync/ssh/
          chmod 600 /var/lib/gitsync/ssh/id_ed25519
        fi
        if [ -f "/mnt/vm-secrets/ssh/id_ed25519.pub" ]; then
          cp /mnt/vm-secrets/ssh/id_ed25519.pub /var/lib/gitsync/ssh/
          chmod 644 /var/lib/gitsync/ssh/id_ed25519.pub
        fi

        cat > /var/lib/gitsync/ssh/config << 'SSHEOF'
        Host github.com
          User git
          IdentityFile ~/.ssh/id_ed25519
          StrictHostKeyChecking accept-new
        SSHEOF
        chmod 600 /var/lib/gitsync/ssh/config
        chown -R gitsync:users /var/lib/gitsync/ssh
      '';
    };

    systemd.services.gitsync-vsock = {
      description = "Git VM command server (vsock 14512)";
      wantedBy = ["multi-user.target"];
      # network-online.target so a git command never races DHCP.
      wants = ["network-online.target"];
      after = ["network-online.target" "gitsync-setup.service"];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        # -t: seconds socat keeps a command running after the host's request EOF; a clone of
        # a large repo takes minutes. The connection still closes as soon as git finishes.
        ExecStart = "${pkgs.socat}/bin/socat -t900 VSOCK-LISTEN:14512,reuseaddr,fork EXEC:${gitHandler},su=gitsync";
      };
    };

    systemd.services.gitsync-status = {
      description = "Git VM status server (vsock 14513)";
      wantedBy = ["multi-user.target"];
      # The host's readiness poll treats an answer here as "safe to send a git command":
      # it must not come up before the guest has an address and DNS.
      wants = ["network-online.target"];
      after = ["network-online.target"];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:14513,reuseaddr,fork EXEC:${statusHandler}";
      };
    };

    users.motd = lib.concatStringsSep "\n" motdLines;
  };
}
