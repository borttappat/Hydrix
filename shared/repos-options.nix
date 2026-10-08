# Declarative git repos: one declaration per repo, shared by the host and the git VM.
#
# The host holds every clone and makes every commit, with no GitHub credential. The git VM
# (gitsync) holds the key and clones, pushes and pulls the entries with push = true
# (vm/microvm/infra/gitsync-agent.nix; ensure-repos in host/repos.nix asks it to clone).
# Other VMs see a repo only through hydrix.microvmHost.vms.<vm>.repos: a host-side view of
# the working tree with readOnlyPaths read-only, so they can edit files but never commit.
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
    enable = lib.mkEnableOption "the ensure-repos command (clone hydrix.repos.entries through the git VM)";

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
            description = "HTTPS URL. The git VM clones from sshUrl when set, else from this.";
          };
          sshUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default =
              if cfg.owner != null
              then "git@github.com:${cfg.owner}/${name}.git"
              else null;
            defaultText = lib.literalExpression ''"git@github.com:''${owner}/<name>.git"'';
            description = "SSH URL the git VM clones from, with its key.";
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
              ensure-repos has the git VM clone this repo when its host path is empty (needs
              push = true, which shares it with the git VM). Set false for a repo without a
              remote yet (it is still shared and pushable).
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
        Repos the host keeps cloned. `ensure-repos` has the git VM clone empty paths;
        existing clones are never pulled or overwritten. Entries with push = true are
        shared with the git VM.
      '';
    };
  };
}
