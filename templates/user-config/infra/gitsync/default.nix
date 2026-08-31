# Gitsync Infra VM - push/pull git repos from lockdown mode
#
# Repos are mounted R/W via virtiofs. Add/remove entries in the repos list
# below and rebuild. Ephemeral by default - no persistent state, SSH keys
# re-derive fresh from host secrets every boot, push/pull is SSH-key auth
# only. Set hydrix.gitsync.gh.enable if you'd rather authenticate with the
# gh CLI than manage an SSH deploy key - it adds gh plus a small persistent
# volume for its OAuth token.
#
# Host commands:
#   microvm git repos            List mounted repos and current branch
#   microvm git push <repo>      Push commits
#   microvm git pull <repo>      Pull changes
#   microvm git status <repo>    Show status + recent log
#
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  meta = import ./meta.nix;

  hostUsername = config.hydrix.username;

  ghEnabled = config.hydrix.gitsync.gh.enable;

  repos = [
    {
      name = "hydrix-config";
      source = "/home/${hostUsername}/hydrix-config";
    }
    # Add any other repos you want accessible from lockdown mode, e.g.:
    # { name = "vault";           source = "/home/${hostUsername}/vault"; }
    # { name = "borttappat-site"; source = "/home/${hostUsername}/borttappat.github.io"; }
  ];

  repoNames = lib.concatMapStringsSep " " (r: r.name) repos;

  safeDirectories =
    lib.concatMapStringsSep "\n"
    (r: "    directory = /mnt/repos/${r.name}")
    repos;

  gitHandler = pkgs.writeShellScript "gitsync-vsock-handler" ''
    export PATH="${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.openssh}/bin:${pkgs.glibc.bin}/bin:$PATH"
    export HOME="/home/gitsync"

    read -r cmd rest

    case "$cmd" in
      PUSH)
        repo="$rest"
        repo_path="/mnt/repos/$repo"
        if [ ! -d "$repo_path/.git" ]; then echo "ERROR repo not found: $repo"; exit 0; fi
        cd "$repo_path"
        echo "OK pushing $repo"
        if git push 2>&1; then echo "DONE"; else echo "ERROR push failed"; fi
        ;;
      PULL)
        repo="$rest"
        repo_path="/mnt/repos/$repo"
        if [ ! -d "$repo_path/.git" ]; then echo "ERROR repo not found: $repo"; exit 0; fi
        cd "$repo_path"
        echo "OK pulling $repo"
        if git pull 2>&1; then echo "DONE"; else echo "ERROR pull failed"; fi
        ;;
      FETCH)
        repo="$rest"
        repo_path="/mnt/repos/$repo"
        if [ ! -d "$repo_path/.git" ]; then echo "ERROR repo not found: $repo"; exit 0; fi
        cd "$repo_path"
        echo "OK fetching $repo"
        if git fetch --all 2>&1; then echo "DONE"; else echo "ERROR fetch failed"; fi
        ;;
      STATUS)
        repo="$rest"
        repo_path="/mnt/repos/$repo"
        if [ ! -d "$repo_path/.git" ]; then echo "ERROR repo not found: $repo"; exit 0; fi
        cd "$repo_path"
        echo "OK status for $repo"
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
        for name in ${repoNames}; do
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
      SYNC)
        # Commit all changes then push - used by vault-cli sync
        repo="$rest"
        repo_path="/mnt/repos/$repo"
        if [ ! -d "$repo_path/.git" ]; then echo "ERROR repo not found: $repo"; exit 0; fi
        cd "$repo_path"
        echo "OK syncing $repo"
        git add -A
        if ! git diff --cached --quiet; then
          git commit -m "sync $(date +%Y-%m-%dT%H:%M)" 2>&1
        else
          echo "(nothing to commit)"
        fi
        if git push 2>&1; then echo "DONE"; else echo "ERROR push failed"; fi
        ;;
      PING)
        echo "PONG"
        ;;
      *)
        echo "ERROR unknown command: $cmd"
        echo "Commands: PUSH <repo>, PULL <repo>, FETCH <repo>, SYNC <repo>, STATUS <repo>, REPOS, PING"
        ;;
    esac
  '';

  motdLines =
    [
      ""
      "+-------------------------------------------------+"
      "|  HYDRIX GIT-SYNC VM                             |"
      "+-------------------------------------------------+"
      "|  Push/pull git repos from lockdown mode         |"
      "|                                                 |"
    ]
    ++ lib.optionals ghEnabled [
      "|  First time:  gh auth login                     |"
    ]
    ++ [
      "|  Commands from host (via microvm git):          |"
      "|    microvm git repos          List repos        |"
      "|    microvm git push <repo>    Push commits      |"
      "|    microvm git pull <repo>    Pull changes      |"
      "|    microvm git status <repo>  Show status       |"
      "+-------------------------------------------------+"
      ""
    ];
in {
  options.hydrix.gitsync.gh = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the gh CLI in the gitsync VM and give it a small persistent
        /var/lib/gitsync/gh-config volume for its OAuth token, so `gh auth
        login` survives restarts. Off by default: push/pull only needs SSH
        keys, which already re-derive fresh from host secrets every boot.
        Enable this if you'd rather authenticate with gh than manage an SSH
        deploy key.
      '';
    };
  };

  config = {
    microvm.vsock.cid = meta.vsockCid;

    microvm.interfaces = [
      {
        type = "tap";
        id = meta.tapId;
        mac = meta.tapMac;
      }
    ];

    microvm.mem = lib.mkForce 2560;

    # Repo shares - nix-store share provided by infra-base
    microvm.shares =
      map (r: {
        tag = "repo-${r.name}";
        source = r.source;
        mountPoint = "/mnt/repos/${r.name}";
        proto = "virtiofs";
      })
      repos;

    # Ephemeral by default - no volumes. SSH keys re-derive fresh from
    # /mnt/vm-secrets every boot (gitsync-setup.service below); nothing here
    # needs to survive a restart. When hydrix.gitsync.gh.enable is set,
    # gh-config gets its own persistent volume since its OAuth token has no
    # host-side source to re-derive from.
    microvm.volumes = lib.mkForce (
      lib.optionals ghEnabled [
        {
          image = "/var/lib/microvms/microvm-gitsync/gh-config.qcow2";
          mountPoint = "/var/lib/gitsync/gh-config";
          size = 64;
          autoCreate = true;
        }
      ]
    );

    microvm.virtiofsd.threadPoolSize = 1;

    boot.kernelModules = ["vmw_vsock_virtio_transport"];

    users.users.gitsync = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      password = "gitsync";
      home = "/home/gitsync";
    };
    services.getty.autologinUser = "gitsync";
    services.haveged.enable = true;

    environment.systemPackages = with pkgs; [git openssh socat vim] ++ lib.optionals ghEnabled [gh];

    environment.etc."gitconfig".text = ''
        [safe]
      ${safeDirectories}
        [url "git@github.com:"]
          insteadOf = https://github.com/
    '';

    systemd.services.gitsync-setup = {
      description = "Set up gitsync SSH directory";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      before = ["gitsync-vsock.service"];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      script = ''
        mkdir -p /var/lib/gitsync/ssh
        ln -sfn /var/lib/gitsync/ssh /home/gitsync/.ssh

        ${lib.optionalString ghEnabled ''
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
      description = "Gitsync vsock server (port 14512)";
      wantedBy = ["multi-user.target"];
      # network-online.target (not just network.target) so a git command never
      # races DHCP - network.target is satisfied before an address/DNS exist.
      wants = ["network-online.target"];
      after = ["network-online.target" "gitsync-setup.service"];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        ExecStart = "${pkgs.socat}/bin/socat -t60 VSOCK-LISTEN:14512,reuseaddr,fork EXEC:${gitHandler},su=gitsync";
      };
    };

    systemd.services.gitsync-status = {
      description = "Gitsync status server (port 14513)";
      wantedBy = ["multi-user.target"];
      # The host's readiness poll (wait_for_gitsync) treats this service
      # answering as "safe to send a git command now" - it must not come up
      # before the guest actually has a DHCP lease and DNS.
      wants = ["network-online.target"];
      after = ["network-online.target"];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        ExecStart = let
          handler = pkgs.writeShellScript "gitsync-status-handler" ''
            read -r cmd
            if pgrep -x "git" > /dev/null; then echo "BUSY"; else echo "IDLE"; fi
          '';
        in "${pkgs.socat}/bin/socat VSOCK-LISTEN:14513,reuseaddr,fork EXEC:${handler}";
      };
    };

    users.motd = lib.concatStringsSep "\n" motdLines;
  };
}
