# MicroVM Git-Sync Module - Push/pull git repos from lockdown mode
#
# This VM provides git operations (push, pull, fetch) for host repositories
# while the host has no internet access in lockdown mode.
#
# Architecture:
#   - Shares br-builder bridge with builder VM (both trusted utility VMs)
#   - Repos mounted R/W via virtiofs so git operations affect host repos
#   - Small persistent volume for gh auth token
#   - Communicates with host via vsock (ports 14512/14513)
#
# Usage:
#   1. Declare repos in mkMicrovmGitSync { repos = [ { name = "..."; source = "..."; } ]; }
#   2. microvm build microvm-gitsync && microvm start microvm-gitsync
#   3. microvm console microvm-gitsync → gh auth login (first time)
#   4. microvm git push config
#
{ config, lib, pkgs, modulesPath, ... }:

let
  locale = config.hydrix.locale;
  hostUsername = config.hydrix.gitsync.hostUsername;
  repos = config.hydrix.gitsync.repos ++ config.hydrix.gitsync.extraRepos;
  vmName = config.networking.hostName;

  # Generate git safe.directory entries for all mounted repos
  safeDirectories = lib.concatMapStringsSep "\n"
    (repo: "    directory = /mnt/repos/${repo.name}")
    repos;

  # Generate repo name list for the vsock server
  repoNames = lib.concatMapStringsSep " " (repo: repo.name) repos;

in {
  imports = [
    ../options.nix
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Git-sync specific options
  options.hydrix.gitsync = {
    hostUsername = lib.mkOption {
      type = lib.types.str;
      description = "Username on the host machine (for repo paths)";
    };
    repos = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Short name for the repo (used in commands and mount path)";
          };
          source = lib.mkOption {
            type = lib.types.str;
            description = "Absolute path to the repo on the host";
          };
        };
      });
      default = [];
      description = "List of git repositories to mount R/W";
    };
    extraRepos = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Short name for the repo";
          };
          source = lib.mkOption {
            type = lib.types.str;
            description = "Absolute path to the repo on the host";
          };
        };
      });
      default = [];
      description = "Additional repos (for site-specific modules to add repos without overriding)";
    };
  };

  config = {
    hydrix.username = lib.mkDefault "gitsync";
    networking.hostName = lib.mkDefault "microvm-gitsync";
    system.stateVersion = "25.05";
    nixpkgs.config.allowUnfree = true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # ===== MicroVM Configuration =====
    microvm = {
      hypervisor = "qemu";
      qemu.machine = "pc";

      # Lightweight - git ops don't need much
      vcpu = 2;
      mem = 2560;  # 2.5GB (avoid exactly 2GB - QEMU hang bug)

      # Use squashfs for the store (no host store access needed)
      # storeDiskType defaults to squashfs which is fine

      # Headless operation
      graphics.enable = false;
      qemu.extraArgs = [
        "-vga" "none"
        "-display" "none"
        "-chardev" "socket,id=console,path=/var/lib/microvms/microvm-gitsync/console.sock,server=on,wait=off"
        "-serial" "chardev:console"
      ];

      # ===== Shared Filesystems =====
      shares = map (repo: {
        tag = "repo-${repo.name}";
        source = repo.source;
        mountPoint = "/mnt/repos/${repo.name}";
        proto = "virtiofs";
      }) repos;

      # Persistent volume for gh auth token
      volumes = [{
        image = "gitsync-data.qcow2";
        mountPoint = "/var/lib/gitsync";
        size = 200;  # 200MB - just for auth tokens
      }];

      # ===== Network Interface =====
      interfaces = [{
        type = "tap";
        id = "mv-gitsync";
        mac = "02:00:00:02:11:01";  # Unique MAC for gitsync
      }];

      # ===== Vsock for host communication =====
      vsock.cid = 211;
    };

    # ===== Kernel Configuration =====
    boot.initrd.availableKernelModules = [
      "virtio_balloon" "virtio_blk" "virtio_pci" "virtio_ring"
      "virtio_net" "virtio_scsi" "virtio_mmio"
      "9p" "9pnet" "9pnet_virtio"
    ];

    boot.kernelParams = [
      "console=tty1"
      "console=ttyS0,115200n8"
      "random.trust_cpu=on"
    ];

    boot.kernelModules = [
      "virtio_blk"
      "virtio_pci"
      "virtio_rng"
      "vmw_vsock_virtio_transport"
    ];

    # ===== Networking =====
    networking = {
      useDHCP = true;
      enableIPv6 = false;
      networkmanager.enable = false;
      firewall.enable = false;
    };

    # ===== Services =====
    services.openssh.enable = false;
    services.qemuGuest.enable = true;
    services.getty.autologinUser = "gitsync";
    services.haveged.enable = true;

    # No nix-daemon needed (git-only VM)
    nix.enable = false;

    # ===== User Configuration =====
    users.users.gitsync = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      password = "gitsync";
      home = "/home/gitsync";
    };
    security.sudo.wheelNeedsPassword = false;

    # ===== Packages =====
    environment.systemPackages = with pkgs; [
      git
      gh
      openssh
      socat
      vim
    ];

    # ===== Git Configuration =====
    environment.etc."gitconfig".text = ''
      [safe]
    ${safeDirectories}
    '';

    # ===== Persistent auth directory =====
    # Link gh config to persistent volume so auth survives restarts
    systemd.services.gitsync-setup = {
      description = "Set up gitsync persistent directories";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      before = [ "gitsync-vsock.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Create persistent directories
        mkdir -p /var/lib/gitsync/gh-config
        mkdir -p /var/lib/gitsync/ssh

        # Link gh config for gitsync user
        mkdir -p /home/gitsync/.config
        ln -sfn /var/lib/gitsync/gh-config /home/gitsync/.config/gh
        chown -R gitsync:users /home/gitsync/.config

        # Link SSH config
        ln -sfn /var/lib/gitsync/ssh /home/gitsync/.ssh
        chown -R gitsync:users /var/lib/gitsync/gh-config
        chown -R gitsync:users /var/lib/gitsync/ssh
      '';
    };

    # ===== Vsock Git Server =====
    # Listens on port 14512 for git commands from host
    systemd.services.gitsync-vsock = {
      description = "Git-sync vsock server for host commands";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "gitsync-setup.service" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          gitServer = pkgs.writeShellScript "gitsync-vsock-server" ''
            while true; do
              ${pkgs.socat}/bin/socat -t60 VSOCK-LISTEN:14512,reuseaddr,fork EXEC:"${gitHandler}",su=gitsync
            done
          '';
          gitHandler = pkgs.writeShellScript "gitsync-vsock-handler" ''
            export PATH="${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.gh}/bin:${pkgs.openssh}/bin:${pkgs.glibc.bin}/bin:$PATH"
            export HOME="/home/gitsync"

            read -r cmd rest

            case "$cmd" in
              PUSH)
                repo="$rest"
                repo_path="/mnt/repos/$repo"
                if [ ! -d "$repo_path/.git" ]; then
                  echo "ERROR repo not found: $repo"
                  exit 0
                fi
                cd "$repo_path"
                echo "OK pushing $repo"
                if git push 2>&1; then
                  echo "DONE"
                else
                  echo "ERROR push failed"
                fi
                ;;

              PULL)
                repo="$rest"
                repo_path="/mnt/repos/$repo"
                if [ ! -d "$repo_path/.git" ]; then
                  echo "ERROR repo not found: $repo"
                  exit 0
                fi
                cd "$repo_path"
                echo "OK pulling $repo"
                if git pull 2>&1; then
                  echo "DONE"
                else
                  echo "ERROR pull failed"
                fi
                ;;

              FETCH)
                repo="$rest"
                repo_path="/mnt/repos/$repo"
                if [ ! -d "$repo_path/.git" ]; then
                  echo "ERROR repo not found: $repo"
                  exit 0
                fi
                cd "$repo_path"
                echo "OK fetching $repo"
                if git fetch --all 2>&1; then
                  echo "DONE"
                else
                  echo "ERROR fetch failed"
                fi
                ;;

              STATUS)
                repo="$rest"
                repo_path="/mnt/repos/$repo"
                if [ ! -d "$repo_path/.git" ]; then
                  echo "ERROR repo not found: $repo"
                  exit 0
                fi
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

              PING)
                echo "PONG"
                ;;

              *)
                echo "ERROR unknown command: $cmd"
                echo "Commands: PUSH <repo>, PULL <repo>, FETCH <repo>, STATUS <repo>, REPOS, PING"
                ;;
            esac
          '';
        in gitServer;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== Vsock Status Server =====
    systemd.services.gitsync-status = {
      description = "Git-sync status server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          statusServer = pkgs.writeShellScript "gitsync-status-server" ''
            while true; do
              ${pkgs.socat}/bin/socat VSOCK-LISTEN:14513,reuseaddr,fork EXEC:"${statusHandler}"
            done
          '';
          statusHandler = pkgs.writeShellScript "gitsync-status-handler" ''
            read -r cmd

            case "$cmd" in
              STATUS|PING)
                # Check if any git operations are running
                if pgrep -x "git" > /dev/null; then
                  echo "BUSY"
                else
                  echo "IDLE"
                fi
                ;;
              *)
                echo "IDLE"
                ;;
            esac
          '';
        in statusServer;
        Restart = "always";
        RestartSec = 5;
      };
    };

    # ===== Locale =====
    time.timeZone = locale.timezone;
    i18n.defaultLocale = locale.language;
    console.keyMap = locale.consoleKeymap;

    # ===== MOTD =====
    users.motd = ''

    +-------------------------------------------------+
    |  HYDRIX GIT-SYNC VM                             |
    +-------------------------------------------------+
    |  Push/pull git repos from lockdown mode         |
    |                                                 |
    |  First time:  gh auth login                     |
    |                                                 |
    |  Commands from host (via microvm git):          |
    |    microvm git repos        List repos          |
    |    microvm git push <repo>  Push commits        |
    |    microvm git pull <repo>  Pull changes        |
    |    microvm git status <repo> Show status        |
    +-------------------------------------------------+

    '';

    # ===== Startup Banner =====
    systemd.services.gitsync-banner = {
      description = "Display git-sync status";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo ""
        echo "Git-sync VM started"
        echo "  vsock CID: 211"
        echo "  Git port: 14512"
        echo "  Status port: 14513"
        echo "  Repos: ${repoNames}"
        echo ""
        echo "Ready for git commands"
      '';
    };
  };
}
