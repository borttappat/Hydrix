# Ollama Dev Module - LLM assistance for Nix package development
#
# This module provides:
# - Ollama service with CPU/memory limits
# - vm-dev-llm: LLM-assisted flake fixing
#
# Commands:
#   vm-dev-llm analyze <pkg>  - Analyze flake + errors, get suggestions
#   vm-dev-llm fix <pkg>      - Try to auto-apply LLM suggestions
#   vm-dev-llm context <pkg>  - Show what context would be sent to LLM
#   vm-dev-llm status         - Check Ollama status, model loaded
#   vm-dev-llm pull           - Pull configured model if not present
#
# Imported by profiles/dev/default.nix
#
{ config, lib, pkgs, ... }:

let
  cfg = config.hydrix.ollama;
  model = cfg.model;

in {
  options.hydrix.ollama = {
    enable = lib.mkEnableOption "Ollama LLM for Nix development assistance";

    model = lib.mkOption {
      type = lib.types.str;
      default = "codellama:13b";
      description = ''
        Ollama model to use for code assistance.
        codellama:13b is recommended for code understanding and Nix syntax.
      '';
    };

    cpuCores = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Maximum CPU cores for Ollama (CPUQuota = cores * 100%)";
    };

    memoryLimit = lib.mkOption {
      type = lib.types.str;
      default = "12G";
      description = "Memory limit for Ollama service";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 11434;
      description = "Port for Ollama API";
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable Ollama service
    # Use mkOverride 10 to beat mkForce (priority 50) from microvm-base.nix
    # Store models in persistent home directory so they survive rebuilds
    services.ollama = {
      enable = lib.mkOverride 10 true;
      host = "127.0.0.1";
      port = cfg.port;
      home = "/home/${config.hydrix.username}/.ollama";
    };

    # Override ollama service to run as VM user (avoids permission issues)
    # Disable security hardening that prevents home directory access
    systemd.services.ollama.serviceConfig = {
      User = lib.mkForce config.hydrix.username;
      Group = lib.mkForce "users";
      WorkingDirectory = lib.mkForce "/home/${config.hydrix.username}";
      DynamicUser = lib.mkForce false;
      ProtectHome = lib.mkForce false;
    };

    # Ensure ollama directory exists
    systemd.services.ollama-setup = {
      description = "Setup Ollama home directory";
      wantedBy = [ "ollama.service" ];
      before = [ "ollama.service" ];
      after = [ "home.mount" "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "ollama-setup" ''
          mkdir -p /home/${config.hydrix.username}/.ollama
          chown ${config.hydrix.username}:users /home/${config.hydrix.username}/.ollama
        '';
      };
    };

    systemd.services.ollama.after = [ "ollama-setup.service" ];
    systemd.services.ollama.requires = [ "ollama-setup.service" ];

    # Apply CPU and memory limits to Ollama service
    systemd.services.ollama.serviceConfig = {
      CPUQuota = "${toString (cfg.cpuCores * 100)}%";
      MemoryMax = cfg.memoryLimit;
      MemoryHigh = cfg.memoryLimit;
    };

    # vm-dev-llm command
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "vm-dev-llm" ''
        #!/usr/bin/env bash
        set -e

        PACKAGES_DIR="$HOME/dev/packages"
        OLLAMA_HOST="http://127.0.0.1:${toString cfg.port}"
        MODEL="${model}"

        usage() {
          echo "vm-dev-llm - LLM assistance for Nix package development"
          echo ""
          echo "Commands:"
          echo "  analyze <pkg>   Analyze flake + build errors, get suggestions"
          echo "  fix <pkg>       Try to auto-apply LLM suggestions"
          echo "  context <pkg>   Show what context would be sent to LLM"
          echo "  status          Check Ollama status and loaded model"
          echo "  pull            Pull configured model ($MODEL)"
          echo ""
          echo "Examples:"
          echo "  vm-dev-llm analyze myapp    # Get help fixing build errors"
          echo "  vm-dev-llm fix myapp        # Auto-apply suggested fixes"
        }

        # Check if Ollama is running
        check_ollama() {
          if ! ${pkgs.curl}/bin/curl -s "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then
            echo "Error: Ollama is not running"
            echo "Start it with: sudo systemctl start ollama"
            exit 1
          fi
        }

        # Check if model is available
        check_model() {
          local models=$(${pkgs.curl}/bin/curl -s "$OLLAMA_HOST/api/tags" | ${pkgs.jq}/bin/jq -r '.models[].name' 2>/dev/null || echo "")
          if ! echo "$models" | grep -q "^$MODEL$"; then
            echo "Model '$MODEL' not found"
            echo "Available models: $models"
            echo ""
            echo "Pull it with: vm-dev-llm pull"
            exit 1
          fi
        }

        # Send prompt to Ollama and get response (5 min timeout)
        ollama_chat() {
          local prompt="$1"
          ${pkgs.curl}/bin/curl -s --max-time 300 "$OLLAMA_HOST/api/generate" \
            -d "$(${pkgs.jq}/bin/jq -n --arg model "$MODEL" --arg prompt "$prompt" '{model: $model, prompt: $prompt, stream: false}')" \
            | ${pkgs.jq}/bin/jq -r '.response'
        }

        # Build context for LLM - minimal, just error + derivation type
        build_context() {
          local pkg="$1"
          local pkg_dir="$PACKAGES_DIR/$pkg"

          if [ ! -f "$pkg_dir/flake.nix" ]; then
            echo "Error: Package '$pkg' not found at $pkg_dir"
            exit 1
          fi

          local context=""

          # Detect derivation type from flake
          local deriv_type="unknown"
          if grep -q "buildRustPackage" "$pkg_dir/flake.nix"; then
            deriv_type="rustPlatform.buildRustPackage"
          elif grep -q "buildGoModule" "$pkg_dir/flake.nix"; then
            deriv_type="buildGoModule"
          elif grep -q "buildPythonApplication" "$pkg_dir/flake.nix"; then
            deriv_type="buildPythonApplication"
          elif grep -q "stdenv.mkDerivation" "$pkg_dir/flake.nix"; then
            deriv_type="stdenv.mkDerivation"
          fi

          context+="Nix $deriv_type"

          # Extract just the key error line (prioritize compiler errors over nix wrapper)
          if [ -f "$pkg_dir/build.log" ]; then
            local error_line
            # Try compiler/linker errors first
            error_line=$(grep -E "(fatal error:|undefined reference|cannot find -l|No such file or directory)" "$pkg_dir/build.log" 2>/dev/null | head -1)
            # Fallback to general errors
            if [ -z "$error_line" ]; then
              error_line=$(grep -E "^error:" "$pkg_dir/build.log" 2>/dev/null | tail -1)
            fi
            if [ -n "$error_line" ]; then
              context+=" error: $error_line"
            fi
          fi

          echo "$context"
        }

        cmd_status() {
          check_ollama

          echo "Ollama Status"
          echo "============="
          echo "Host: $OLLAMA_HOST"
          echo "Configured model: $MODEL"
          echo ""

          echo "Available models:"
          ${pkgs.curl}/bin/curl -s "$OLLAMA_HOST/api/tags" | ${pkgs.jq}/bin/jq -r '.models[] | "  \(.name) (\(.size / 1024 / 1024 / 1024 | floor)GB)"' 2>/dev/null || echo "  (none)"
          echo ""

          # Check systemd service
          echo "Service status:"
          systemctl status ollama --no-pager -l 2>/dev/null | head -5 || echo "  Cannot get status"
        }

        cmd_pull() {
          check_ollama

          echo "Pulling model: $MODEL"
          echo "This may take a while..."
          echo ""

          ${pkgs.curl}/bin/curl -s "$OLLAMA_HOST/api/pull" \
            -d "{\"name\": \"$MODEL\"}" \
            | while read -r line; do
                status=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.status // empty' 2>/dev/null)
                completed=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.completed // empty' 2>/dev/null)
                total=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.total // empty' 2>/dev/null)

                if [ -n "$status" ]; then
                  if [ -n "$completed" ] && [ -n "$total" ]; then
                    pct=$((completed * 100 / total))
                    printf "\r%s: %d%%" "$status" "$pct"
                  else
                    printf "\r%s" "$status"
                  fi
                fi
              done

          echo ""
          echo "Done!"
        }

        cmd_context() {
          local pkg="''${1:-}"
          if [ -z "$pkg" ]; then
            echo "Usage: vm-dev-llm context <pkg>"
            exit 1
          fi

          echo "Context that would be sent to LLM:"
          echo "=================================="
          build_context "$pkg"
        }

        cmd_analyze() {
          local pkg="''${1:-}"
          if [ -z "$pkg" ]; then
            echo "Usage: vm-dev-llm analyze <pkg>"
            exit 1
          fi

          check_ollama
          check_model

          local pkg_dir="$PACKAGES_DIR/$pkg"
          local context=$(build_context "$pkg")

          echo "Analyzing $pkg..."
          echo ""

          local prompt="$context

What Nix attribute fixes this? Answer with just the attribute line."

          ollama_chat "$prompt"
        }

        cmd_fix() {
          local pkg="''${1:-}"
          if [ -z "$pkg" ]; then
            echo "Usage: vm-dev-llm fix <pkg>"
            exit 1
          fi

          check_ollama
          check_model

          local pkg_dir="$PACKAGES_DIR/$pkg"
          local context=$(build_context "$pkg")

          echo "Analyzing and generating fix for $pkg..."
          echo ""

          local prompt="Output ONLY the corrected flake.nix (no markdown, no explanation):

$context"

          local response=$(ollama_chat "$prompt")

          # Validate response looks like Nix code
          if echo "$response" | grep -q "^{"; then
            # Backup original
            cp "$pkg_dir/flake.nix" "$pkg_dir/flake.nix.bak"

            # Write new flake
            echo "$response" > "$pkg_dir/flake.nix"

            echo "Applied fix to $pkg_dir/flake.nix"
            echo "Backup saved to $pkg_dir/flake.nix.bak"
            echo ""
            echo "Test with: vm-dev run $pkg"
            echo "Revert with: mv $pkg_dir/flake.nix.bak $pkg_dir/flake.nix"
          else
            echo "LLM response doesn't look like valid Nix code"
            echo "Response:"
            echo "$response"
            exit 1
          fi
        }

        case "''${1:-}" in
          analyze) shift; cmd_analyze "$@" ;;
          fix) shift; cmd_fix "$@" ;;
          context) shift; cmd_context "$@" ;;
          status) cmd_status ;;
          pull) cmd_pull ;;
          *) usage ;;
        esac
      '')
    ];
  };
}
