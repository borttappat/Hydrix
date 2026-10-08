# Declarative git repos: one declaration per repo, shared by the host and the git VM.
#
# The host holds every clone and makes every commit (host/repos.nix: ensure-repos). The git
# VM (gitsync) holds the GitHub credential and pushes/pulls the entries with push = true
# (vm/microvm/infra/gitsync-agent.nix). Other VMs see a repo only through
# hydrix.microvmHost.vms.<vm>.repos: a host-side view of the working tree with readOnlyPaths
# read-only, so they can edit files but never commit.
#
# Declare entries in a module imported by both the host and the git VM (hydrix-config:
# modules/repos.nix), since the git VM is not built per machine.
{
  config,
  lib,
  ...
}: let
  cfg = config.hydrix.repos;
  homeDir = "/home/${config.hydrix.username}";
in {
  options.hydrix.repos = {
    enable = lib.mkEnableOption "cloning hydrix.repos.entries on the host (ensure-repos)";

    owner = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "youruser";
      description = ''
        GitHub user or organisation. Entries without an explicit url clone from
        github.com/<owner>/<name>.
      '';
    };

    readOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [".git" ".claude"];
      description = ''
        Paths relative to a repo root that a VM sees read-only in the views made by
        hydrix.microvmHost.vms.<vm>.repos (read-only on the host side).
      '';
    };

    entries = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          url = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default =
              if cfg.owner != null
              then "https://github.com/${cfg.owner}/${name}.git"
              else null;
            defaultText = lib.literalExpression ''"https://github.com/''${owner}/<name>.git"'';
            description = "HTTPS clone URL, used with the gh CLI when it is authenticated.";
          };
          sshUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default =
              if cfg.owner != null
              then "git@github.com:${cfg.owner}/${name}.git"
              else null;
            defaultText = lib.literalExpression ''"git@github.com:''${owner}/<name>.git"'';
            description = "SSH clone URL, used when gh is not authenticated.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            default = "${homeDir}/${name}";
            defaultText = lib.literalExpression ''"/home/<username>/<name>"'';
            description = "Absolute host path of the clone.";
          };
          clone = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Clone this repo on the host when its path is missing or empty. Set false for a
              repo without a remote yet (it is still shared and pushable).
            '';
          };
          push = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Share this repo with the git VM, so `shard git push|pull|fetch|status <name>`
              works on it.
            '';
          };
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
        };
      }));
      default = {};
      example = lib.literalExpression ''
        {
          notes = {};                         # github.com/<owner>/notes, cloned to ~/notes
          site = { path = "/home/user/www"; };
          vault = { clone = false; };         # no remote yet, still pushable once it has one
        }
      '';
      description = ''
        Repos the host keeps cloned (missing or empty paths are cloned at boot and by
        `ensure-repos`; existing clones are never pulled or overwritten). Entries with
        push = true are shared with the git VM.
      '';
    };
  };
}
