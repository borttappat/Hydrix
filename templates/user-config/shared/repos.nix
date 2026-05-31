# Declarative Git Repositories
#
# Repos listed here are cloned on activation if they don't already exist.
# Runs as the user (not root), non-blocking - failures are logged to journal,
# never to the console, and never break a rebuild.
#
# Authentication (tried in order):
#   1. gh CLI  - run `gh auth login` once after first boot
#   2. SSH key - ~/.ssh/id_ed25519 or ~/.ssh/id_rsa
#   3. Warning logged, repo skipped (no error thrown)
#
# No gh auth or sops setup required to import this file safely.
# An empty `repos` attrset below is a valid no-op.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix;
  username = cfg.username;
  homeDir = "/home/${username}";

  # ─── Add your repositories here ──────────────────────────────────────────
  # Each entry needs: url (HTTPS), sshUrl (SSH fallback), path, description.
  #
  # repos = {
  #   my-notes = {
  #     url    = "https://github.com/youruser/my-notes.git";
  #     sshUrl = "git@github.com:youruser/my-notes.git";
  #     path   = "${homeDir}/my-notes";
  #     description = "Personal notes";
  #   };
  #   my-site = {
  #     url    = "https://github.com/youruser/youruser.github.io.git";
  #     sshUrl = "git@github.com:youruser/youruser.github.io.git";
  #     path   = "${homeDir}/youruser.github.io";
  #     description = "GitHub Pages site";
  #   };
  # };
  repos = {};

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
    '') repos)}

    log "Done"
  '';

in {
  environment.systemPackages = [ pkgs.gh ensureReposScript ];

  system.activationScripts.ensureRepos = {
    text = ''
      if id "${username}" &>/dev/null; then
        ${pkgs.sudo}/bin/sudo -u ${username} ${ensureReposScript}/bin/ensure-repos 2>&1 | \
          ${pkgs.systemd}/bin/systemd-cat -t ensure-repos || true
      fi
    '';
    deps = [ "users" ];
  };
}
