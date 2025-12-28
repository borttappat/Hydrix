# Xpra host configuration
# Enables connecting to VM Xpra servers and launching VM apps from host
{ config, pkgs, lib, ... }:

let
  # VM connection info
  # These IPs are on br-shared - host needs IP on br-shared to reach them
  vmConnections = {
    pentest = { port = 14500; prefix = "[PTX]"; bridge = "br-pentest"; };
    browsing = { port = 14501; prefix = "[BRW]"; bridge = "br-browse"; };
    office = { port = 14502; prefix = "[OFC]"; bridge = "br-office"; };
    comms = { port = 14503; prefix = "[COM]"; bridge = "br-office"; };
    dev = { port = 14504; prefix = "[DEV]"; bridge = "br-dev"; };
  };

  # Script to discover VM IPs on a bridge
  discoverVmScript = pkgs.writeShellScript "xpra-discover" ''
    BRIDGE="$1"
    PORT="$2"

    if [ -z "$BRIDGE" ] || [ -z "$PORT" ]; then
      echo "Usage: xpra-discover <bridge> <port>"
      exit 1
    fi

    # Get subnet for bridge
    case "$BRIDGE" in
      br-pentest) SUBNET="192.168.101" ;;
      br-browse)  SUBNET="192.168.103" ;;
      br-office)  SUBNET="192.168.102" ;;
      br-dev)     SUBNET="192.168.104" ;;
      br-shared)  SUBNET="192.168.105" ;;
      *) echo "Unknown bridge: $BRIDGE"; exit 1 ;;
    esac

    # Scan for xpra servers
    for i in $(seq 2 254); do
      IP="$SUBNET.$i"
      if timeout 0.2 bash -c "echo >/dev/tcp/$IP/$PORT" 2>/dev/null; then
        echo "$IP"
        exit 0
      fi
    done

    echo "No VM found on $BRIDGE with xpra port $PORT"
    exit 1
  '';
in
{
  # Add host IPs to VM bridges for direct communication
  # This allows the host to reach VMs on any bridge
  networking.interfaces = {
    br-shared.ipv4.addresses = lib.mkAfter [{
      address = "192.168.105.1";
      prefixLength = 24;
    }];
    br-pentest.ipv4.addresses = lib.mkAfter [{
      address = "192.168.101.1";
      prefixLength = 24;
    }];
    br-browse.ipv4.addresses = lib.mkAfter [{
      address = "192.168.103.1";
      prefixLength = 24;
    }];
    br-office.ipv4.addresses = lib.mkAfter [{
      address = "192.168.102.1";
      prefixLength = 24;
    }];
    br-dev.ipv4.addresses = lib.mkAfter [{
      address = "192.168.104.1";
      prefixLength = 24;
    }];
  };

  # dconf for GTK apps
  programs.dconf.enable = true;

  environment.systemPackages = with pkgs; [
    xpra
    # Python deps for xpra client
    python3Packages.numpy
    python3Packages.pillow
    python3Packages.pygobject3
    # GTK/notification deps
    libnotify
    glib

    # Attach to browsing VM
    (writeShellScriptBin "xpra-browsing" ''
      # Find browsing VM and attach
      echo "Looking for browsing VM on br-browse or br-shared..."

      # Try br-shared first (common for testing)
      for SUBNET in 192.168.105 192.168.103; do
        for i in $(seq 2 254); do
          IP="$SUBNET.$i"
          if timeout 0.3 bash -c "echo >/dev/tcp/$IP/14501" 2>/dev/null; then
            echo "Found browsing VM at $IP:14501"
            exec xpra attach "tcp://$IP:14501" \
              --title="@title@ ${vmConnections.browsing.prefix}" \
              --opengl=yes \
              "$@"
          fi
        done
      done

      echo "No browsing VM found. Is it running with xpra-start?"
      exit 1
    '')

    # Attach to pentest VM
    (writeShellScriptBin "xpra-pentest" ''
      echo "Looking for pentest VM..."

      for SUBNET in 192.168.105 192.168.101; do
        for i in $(seq 2 254); do
          IP="$SUBNET.$i"
          if timeout 0.3 bash -c "echo >/dev/tcp/$IP/14500" 2>/dev/null; then
            echo "Found pentest VM at $IP:14500"
            exec xpra attach "tcp://$IP:14500" \
              --title="@title@ ${vmConnections.pentest.prefix}" \
              --opengl=yes \
              "$@"
          fi
        done
      done

      echo "No pentest VM found. Is it running with xpra-start?"
      exit 1
    '')

    # Attach to dev VM
    (writeShellScriptBin "xpra-dev" ''
      echo "Looking for dev VM..."

      for SUBNET in 192.168.105 192.168.104; do
        for i in $(seq 2 254); do
          IP="$SUBNET.$i"
          if timeout 0.3 bash -c "echo >/dev/tcp/$IP/14504" 2>/dev/null; then
            echo "Found dev VM at $IP:14504"
            exec xpra attach "tcp://$IP:14504" \
              --title="@title@ ${vmConnections.dev.prefix}" \
              --opengl=yes \
              "$@"
          fi
        done
      done

      echo "No dev VM found. Is it running with xpra-start?"
      exit 1
    '')

    # Attach to comms VM
    (writeShellScriptBin "xpra-comms" ''
      echo "Looking for comms VM..."

      for SUBNET in 192.168.105 192.168.102; do
        for i in $(seq 2 254); do
          IP="$SUBNET.$i"
          if timeout 0.3 bash -c "echo >/dev/tcp/$IP/14503" 2>/dev/null; then
            echo "Found comms VM at $IP:14503"
            exec xpra attach "tcp://$IP:14503" \
              --title="@title@ ${vmConnections.comms.prefix}" \
              --opengl=yes \
              "$@"
          fi
        done
      done

      echo "No comms VM found. Is it running with xpra-start?"
      exit 1
    '')

    # Generic attach with manual IP
    (writeShellScriptBin "xpra-attach" ''
      if [ -z "$1" ]; then
        echo "Usage: xpra-attach <vm-type|ip:port>"
        echo ""
        echo "VM types: browsing, pentest, dev, comms"
        echo "Or specify IP:PORT directly"
        echo ""
        echo "Examples:"
        echo "  xpra-attach browsing"
        echo "  xpra-attach 192.168.105.136:14501"
        exit 1
      fi

      case "$1" in
        browsing) exec xpra-browsing ;;
        pentest)  exec xpra-pentest ;;
        dev)      exec xpra-dev ;;
        comms)    exec xpra-comms ;;
        *)
          # Assume IP:PORT format
          exec xpra attach "tcp://$1" --opengl=yes
          ;;
      esac
    '')

    # Launch app in VM via SSH
    (writeShellScriptBin "vm-run" ''
      VM_TYPE="$1"
      shift
      APP="$@"

      if [ -z "$VM_TYPE" ] || [ -z "$APP" ]; then
        echo "Usage: vm-run <vm-type> <app> [args...]"
        echo ""
        echo "VM types: browsing, pentest, dev, comms"
        echo ""
        echo "Examples:"
        echo "  vm-run browsing firefox"
        echo "  vm-run pentest burpsuite"
        echo "  vm-run dev code"
        exit 1
      fi

      case "$VM_TYPE" in
        browsing) PORT=14501; SUBNETS="192.168.105 192.168.103" ;;
        pentest)  PORT=14500; SUBNETS="192.168.105 192.168.101" ;;
        dev)      PORT=14504; SUBNETS="192.168.105 192.168.104" ;;
        comms)    PORT=14503; SUBNETS="192.168.105 192.168.102" ;;
        *) echo "Unknown VM type: $VM_TYPE"; exit 1 ;;
      esac

      # Find VM
      for SUBNET in $SUBNETS; do
        for i in $(seq 2 254); do
          IP="$SUBNET.$i"
          if timeout 0.3 bash -c "echo >/dev/tcp/$IP/$PORT" 2>/dev/null; then
            echo "Found $VM_TYPE VM at $IP"
            echo "Launching $APP..."
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
              user@$IP "DISPLAY=:100 $APP" &
            exit 0
          fi
        done
      done

      echo "No $VM_TYPE VM found"
      exit 1
    '')

    # Show all running VMs with xpra
    (writeShellScriptBin "xpra-list-vms" ''
      echo "Scanning for VMs with Xpra servers..."
      echo ""

      for VM in browsing pentest dev comms; do
        case "$VM" in
          browsing) PORT=14501; SUBNETS="192.168.105 192.168.103" ;;
          pentest)  PORT=14500; SUBNETS="192.168.105 192.168.101" ;;
          dev)      PORT=14504; SUBNETS="192.168.105 192.168.104" ;;
          comms)    PORT=14503; SUBNETS="192.168.105 192.168.102" ;;
        esac

        FOUND=""
        for SUBNET in $SUBNETS; do
          for i in $(seq 2 254); do
            IP="$SUBNET.$i"
            if timeout 0.2 bash -c "echo >/dev/tcp/$IP/$PORT" 2>/dev/null; then
              FOUND="$IP:$PORT"
              break 2
            fi
          done
        done

        if [ -n "$FOUND" ]; then
          echo "  $VM: $FOUND"
        fi
      done

      echo ""
      echo "To attach: xpra-<vmtype> (e.g., xpra-browsing)"
      echo "To run app: vm-run <vmtype> <app> (e.g., vm-run browsing firefox)"
    '')

    # Comprehensive help/reference command
    (writeShellScriptBin "xpra-help" ''
      cat << 'EOF'
================================================================================
                          XPRA HOST COMMANDS
================================================================================

ATTACHING TO VMs (auto-discovers VM IP):
  xpra-browsing       Attach to browsing VM (port 14501)
  xpra-pentest        Attach to pentest VM (port 14500)
  xpra-dev            Attach to dev VM (port 14504)
  xpra-comms          Attach to comms VM (port 14503)
  xpra-attach <type>  Generic attach (browsing|pentest|dev|comms|ip:port)

LAUNCHING APPS IN VMs:
  vm-run <vmtype> <app>    Launch app in VM via SSH
                           Examples:
                             vm-run browsing firefox
                             vm-run browsing obsidian
                             vm-run pentest burpsuite
                             vm-run dev code

DISCOVERY:
  xpra-list-vms       Scan for running VMs with Xpra servers

i3 KEYBINDINGS:
  Mod+F9              Attach to browsing VM
  Mod+F10             Attach to pentest VM
  Mod+F11             Attach to dev VM
  Mod+Shift+F9        Attach to comms VM
  Mod+Shift+o         Launch Obsidian in browsing VM
  Mod+Shift+a         Launch Claude (firefox) in browsing VM

VM PORT ASSIGNMENTS:
  pentest:  14500 (br-pentest / br-shared)
  browsing: 14501 (br-browse / br-shared)
  office:   14502 (br-office / br-shared)
  comms:    14503 (br-office / br-shared)
  dev:      14504 (br-dev / br-shared)

HOST BRIDGE IPs:
  br-pentest: 192.168.101.1
  br-office:  192.168.102.1
  br-browse:  192.168.103.1
  br-dev:     192.168.104.1
  br-shared:  192.168.105.1

WORKFLOW:
  1. Start a VM (via virt-manager or build-vm.sh)
  2. VM auto-starts Xpra server on login
  3. From host, run: xpra-<vmtype> (e.g., xpra-browsing)
  4. In VM, run apps with: xpra-run <app>
  5. Apps appear as windows on host!

DETACHING:
  Press Ctrl+C in the terminal running xpra-attach
  Or close the xpra tray icon

================================================================================
EOF
    '')

    # Script to auto-attach to all available VMs
    (writeShellScriptBin "xpra-auto-attach" ''
      # Auto-attach to VMs as they become available
      # Runs in background, attaching to each VM type once

      ATTACHED=""

      attach_vm() {
        VM_TYPE="$1"
        PORT="$2"
        SUBNETS="$3"
        PREFIX="$4"

        # Skip if already attached
        if echo "$ATTACHED" | grep -q "$VM_TYPE"; then
          return
        fi

        for SUBNET in $SUBNETS; do
          for i in $(seq 2 254); do
            IP="$SUBNET.$i"
            if timeout 0.3 bash -c "echo >/dev/tcp/$IP/$PORT" 2>/dev/null; then
              echo "Found $VM_TYPE VM at $IP:$PORT - attaching..."
              xpra attach "tcp://$IP:$PORT" \
                --title="@title@ $PREFIX" \
                --opengl=yes \
                --notifications=no &
              ATTACHED="$ATTACHED $VM_TYPE"
              return 0
            fi
          done
        done
        return 1
      }

      echo "Xpra auto-attach started. Scanning for VMs..."

      # Initial scan
      attach_vm browsing 14501 "192.168.105 192.168.103" "[BRW]"
      attach_vm pentest 14500 "192.168.105 192.168.101" "[PTX]"
      attach_vm dev 14504 "192.168.105 192.168.104" "[DEV]"
      attach_vm comms 14503 "192.168.105 192.168.102" "[COM]"

      echo "Initial scan complete. Attached to:$ATTACHED"
      echo "Press Ctrl+C to stop auto-attach."

      # Keep scanning for new VMs every 30 seconds
      while true; do
        sleep 30
        attach_vm browsing 14501 "192.168.105 192.168.103" "[BRW]"
        attach_vm pentest 14500 "192.168.105 192.168.101" "[PTX]"
        attach_vm dev 14504 "192.168.105 192.168.104" "[DEV]"
        attach_vm comms 14503 "192.168.105 192.168.102" "[COM]"
      done
    '')
  ];

  # Systemd user service for auto-attaching to VMs
  # Disabled by default - enable with: systemctl --user enable --now xpra-auto-attach
  systemd.user.services.xpra-auto-attach = {
    description = "Auto-attach to Xpra VMs";
    wantedBy = []; # Not auto-started - user enables manually if desired
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.bash}/bin/bash -c 'xpra-auto-attach'";
      Restart = "on-failure";
      RestartSec = 10;
      Environment = "PATH=/run/current-system/sw/bin";
    };
  };
}

