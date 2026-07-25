# vm-switch — live NixOS switch via vsock (port 14504)
#
# Listens for SWITCH/TEST/STATUS/PING commands from the host.
# Enables `microvm update <name>`: build once on host, apply live without restart.
#
# Imported by all VM base modules so every VM supports live rebuild.
{ pkgs, ... }: {
  # Ensure switch-to-configuration is generated — required for live switching.
  # Infra VMs with nix.enable = false would otherwise have it disabled.
  system.switch.enable = true;

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

              # switch-to-configuration exit codes (see nixos/modules/system/
              # activation/switch-to-configuration.pl): 0 = full success,
              # 4 = activation ran but some units failed to restart/reload/start
              # (genuine partial success), 100 = new init is incompatible with
              # the running one — activation did NOT take effect until reboot.
              # Anything else (2 = activate/daemon-reexec failed, 3 = daemon-
              # reload failed, or unrecognized) is a hard failure and must not
              # be reported as OK.
              case "$exit_code" in
                0)
                  echo "OK: switched to $path"
                  ;;
                4)
                  echo "OK: switched to $path (some units failed, exit 4)"
                  echo "$output"
                  ;;
                100)
                  echo "ERROR: switch requires reboot (incompatible init interface) — configuration NOT active"
                  echo "$output"
                  ;;
                *)
                  echo "ERROR: switch failed (exit $exit_code)"
                  echo "$output"
                  ;;
              esac
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
