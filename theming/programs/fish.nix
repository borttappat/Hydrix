# Fish Shell — Framework Integration
#
# Provides: pywal color sequences, fzf/zoxide integration, Ctrl+R history,
# vi key bindings (gated by hydrix.graphical.fish.viKeyBindings),
# lockdown git wrapper (host only), and the __save_last_dir plumbing.
#
# All abbreviations, colors, cursor settings, and user functions live in
# hydrix-config/modules/fish.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  username = config.hydrix.username;
  vmType = config.hydrix.vmType;
  isVM = vmType != null && vmType != "host";
  fishCfg = config.hydrix.graphical.fish;
in {
  config = lib.mkIf config.hydrix.graphical.enable {
    home-manager.users.${username} = {pkgs, ...}: {
      programs.fish = {
        enable = lib.mkDefault true;

        shellInit = ''
          # Disable greeting
          set -g fish_greeting

          ${lib.optionalString (!isVM) ''
            # Apply pywal colors to terminal (host only)
            # VMs use alacritty's live_config_reload via colors-runtime.toml instead
            if test -f ~/.cache/wal/sequences
              cat ~/.cache/wal/sequences
            end
          ''}
        '';

        interactiveShellInit = ''
          # Blank line between prompts (skip before first)
          function __add_newline --on-event fish_prompt
            if set -q __first_prompt_done
              echo
            else
              set -g __first_prompt_done 1
            end
          end

          # fzf colors from pywal (transparent bg, terminal palette)
          if test -f ~/.cache/wal/colors
            set -l colors (head -9 ~/.cache/wal/colors)
            set -gx FZF_DEFAULT_OPTS "--color=fg:$colors[8],bg:-1,hl:$colors[5],fg+:$colors[8],bg+:$colors[9],hl+:$colors[5],info:$colors[7],prompt:$colors[5],pointer:$colors[6],marker:$colors[4],spinner:$colors[7],header:$colors[9]"
          end

          # Register directory save event handler
          functions -q __save_last_dir; or source ~/.config/fish/functions/__save_last_dir.fish

          ${lib.optionalString fishCfg.viKeyBindings "fish_vi_key_bindings"}

          # Source fzf bindings explicitly to ensure Ctrl+R is available
          if test -f ${pkgs.fzf}/share/fish/vendor_functions.d/fzf_key_bindings.fish
            source ${pkgs.fzf}/share/fish/vendor_functions.d/fzf_key_bindings.fish
          end

          # Ctrl+R history search in both vi modes
          bind -M insert \cr fzf-history-widget
          bind -M default \cr fzf-history-widget

          ${lib.optionalString (!isVM) ''
            # Lockdown-aware git wrapper: routes push/pull/fetch through gitsync VM
            function git --wraps git
              if contains -- $argv[1] push pull fetch
                if test -f /etc/HYDRIX_MODE
                  and grep -q "MODE=lockdown" /etc/HYDRIX_MODE
                  set -l toplevel (command git rev-parse --show-toplevel 2>/dev/null)
                  if test -n "$toplevel"
                    set -l repo_name (basename $toplevel)
                    echo -e "\033[33m::\033[0m Lockdown mode — routing through git-sync VM."
                    read -P "Use git-sync VM for $argv[1] $repo_name? [Y/n] " confirm
                    if test -z "$confirm" -o "$confirm" = Y -o "$confirm" = y
                      microvm git $argv[1] $repo_name
                      return $status
                    else
                      echo "Cancelled."
                      return 1
                    end
                  end
                end
              end
              command git $argv
            end
          ''}
        '';

        functions = {
          # Save current directory on PWD change (used by directory memory)
          __save_last_dir = {
            body = "echo $PWD > /tmp/last_fish_dir";
            onVariable = "PWD";
          };

          # Used by double-Escape bind in user config
          sudo_last_command = "commandline -r \"sudo $history[1]\"";
        } // lib.optionalAttrs (!isVM) {
          # Router console shortcut (host-only infrastructure)
          rc = ''
            set _router_vm (jq -r '.routerVmName // "microvm-router"' /etc/hydrix/host-config.json 2>/dev/null; or echo "microvm-router")
            if systemctl is-active --quiet microvm@$_router_vm.service
              echo "Connecting to $_router_vm (Ctrl+] to disconnect)..."
              sudo socat -,rawer,escape=0x1d unix-connect:/var/lib/microvms/$_router_vm/console.sock
            else if sudo virsh domstate router-vm 2>/dev/null | grep -q running
              echo "Connecting to router-vm via Spice..."
              virt-viewer --connect qemu:///system router-vm
            else
              echo "No router running. Start with:"
              echo "  microvm: sudo systemctl start microvm@$_router_vm"
              echo "  libvirt: sudo virsh start router-vm"
            end
          '';
        };
      };

      # Zoxide (smart cd)
      programs.zoxide = {
        enable = lib.mkDefault true;
        enableFishIntegration = lib.mkDefault true;
      };

      # FZF (fuzzy finder) — colors set dynamically from pywal in interactiveShellInit
      programs.fzf = {
        enable = lib.mkDefault true;
        enableFishIntegration = lib.mkDefault true;
      };
    };
  };
}
