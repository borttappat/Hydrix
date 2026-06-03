# vm-switch — live NixOS switch via vsock (port 14504)
#
# Listens for SWITCH/TEST/STATUS/PING commands from the host.
# Enables `microvm update <name>`: build once on host, apply live without restart.
#
# Imported by all VM base modules so every VM supports live rebuild.
{ pkgs, ... }: {
  # CRITICAL: restartIfChanged = false — this service must not restart itself
  # while handling a SWITCH command, or it kills the handler mid-flight.
  systemd.services.vm-switch = {
    description = "Live NixOS switch via vsock";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "simple";
      ExecStart = let
        switchHandler = pkgs.writeShellScript "vm-switch-handler" ''
          read -r cmd path

          case "$cmd" in
            SWITCH)
              if [[ ! -d "$path" ]]; then
                echo "ERROR: path does not exist: $path"
                exit 1
              fi
              if [[ ! -x "$path/bin/switch-to-configuration" ]]; then
                echo "ERROR: not a valid NixOS system: $path"
                exit 1
              fi

              current=$(readlink /run/current-system)
              if [[ "$current" == "$path" ]]; then
                echo "OK: already running this configuration"
                exit 0
              fi

              # Update profile symlink directly (bypass nix-env to avoid Nix DB issues)
              ln -sfn "$path" /nix/var/nix/profiles/system

              # Register host-built store paths in VM's nix DB.
              # Profile VMs need this for home-manager activation; infra VMs skip it
              # if the share is absent (host write fails silently, file won't exist).
              if [[ -f /mnt/vm-config/.switch-reg ]]; then
                ${pkgs.nix}/bin/nix-store --load-db < /mnt/vm-config/.switch-reg 2>/dev/null || true
                rm -f /mnt/vm-config/.switch-reg
              fi

              output=$("$path/bin/switch-to-configuration" switch 2>&1)
              exit_code=$?

              if [[ $exit_code -eq 0 ]]; then
                echo "OK: switched to $path"
              elif [[ $exit_code -eq 1 ]]; then
                echo "ERROR: switch failed"
                echo "$output"
              else
                # Partial success: switch ran but some units failed
                echo "OK: switched to $path (some units failed, exit $exit_code)"
                echo "$output"
              fi
              ;;

            TEST)
              if [[ ! -d "$path" ]]; then
                echo "ERROR: path does not exist: $path"
                exit 1
              fi
              if [[ ! -x "$path/bin/switch-to-configuration" ]]; then
                echo "ERROR: not a valid NixOS system: $path"
                exit 1
              fi
              "$path/bin/switch-to-configuration" test 2>&1
              ;;

            STATUS)
              current=$(readlink /run/current-system)
              booted=$(readlink /run/booted-system 2>/dev/null || echo "unknown")
              profile=$(readlink /nix/var/nix/profiles/system 2>/dev/null || echo "none")
              echo "CURRENT $current"
              echo "BOOTED $booted"
              echo "PROFILE $profile"
              ;;

            PING)
              echo "PONG"
              ;;

            *)
              echo "ERROR: unknown command: $cmd"
              echo "Commands: SWITCH <path>, TEST <path>, STATUS, PING"
              ;;
          esac
        '';
        switchScript = pkgs.writeShellScript "vm-switch-server" ''
          while true; do
            ${pkgs.socat}/bin/socat VSOCK-LISTEN:14504,reuseaddr,fork EXEC:"${switchHandler}",nofork
          done
        '';
      in switchScript;
      Restart = "always";
      RestartSec = 5;
    };
  };
}
