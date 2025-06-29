{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.microvm-dev;
  
  # MVM command implementation
  mvmScript = pkgs.writeShellScriptBin "mvm" ''
    set -euo pipefail
    
    COMMAND="''${1:-help}"
    shift || true
    
    STATE_DIR="/var/lib/microvm-dev"
    
    # Helper functions
    get_vm_status() {
      local vm="$1"
      if systemctl is-active "microvm@$vm.service" >/dev/null 2>&1; then
        echo "running"
      elif systemctl is-active "microvm-dynamic@$vm.service" >/dev/null 2>&1; then
        echo "running (dynamic)"
      else
        echo "stopped"
      fi
    }
    
    get_vm_ip() {
      local vm="$1"
      if [ -f "$STATE_DIR/$vm/ip" ]; then
        cat "$STATE_DIR/$vm/ip"
      else
        echo "unknown"
      fi
    }
    
    case "$COMMAND" in
      create)
        VM_NAME="''${1:-}"
        if [ -z "$VM_NAME" ]; then
          echo "Usage: mvm create <name> [options]"
          exit 1
        fi
        shift || true
        
        # Parse options
        PROJECT_DIR=""
        VCPU="2"
        MEM="512"
        PERSIST="false"
        
        while [ $# -gt 0 ]; do
          case "$1" in
            --project|-p)
              PROJECT_DIR="$2"
              shift 2
              ;;
            --vcpu)
              VCPU="$2"
              shift 2
              ;;
            --mem)
              MEM="$2"
              shift 2
              ;;
            --persist)
              PERSIST="true"
              shift
              ;;
            *)
              echo "Unknown option: $1"
              exit 1
              ;;
          esac
        done
        
        # Create VM directory
        mkdir -p "$STATE_DIR/$VM_NAME"
        
        # Generate VM configuration
        cat > "$STATE_DIR/$VM_NAME/config.json" <<EOF
    {
      "name": "$VM_NAME",
      "projectDir": "$PROJECT_DIR",
      "vcpu": $VCPU,
      "mem": $MEM,
      "persistState": $PERSIST
    }
    EOF
        
        echo "Created VM: $VM_NAME"
        echo "Run 'mvm start $VM_NAME' to start the VM"
        ;;
        
      start)
        VM_NAME="''${1:-}"
        if [ -z "$VM_NAME" ]; then
          echo "Usage: mvm start <name>"
          exit 1
        fi
        
        echo "Starting VM: $VM_NAME"
        sudo systemctl start "microvm-dynamic@$VM_NAME.service"
        
        # Wait for IP
        echo -n "Waiting for IP address..."
        for i in {1..30}; do
          if [ -f "$STATE_DIR/$VM_NAME/ip" ]; then
            echo " $(cat "$STATE_DIR/$VM_NAME/ip")"
            break
          fi
          echo -n "."
          sleep 1
        done
        echo ""
        ;;
        
      stop)
        VM_NAME="''${1:-}"
        if [ -z "$VM_NAME" ]; then
          echo "Usage: mvm stop <name>"
          exit 1
        fi
        
        echo "Stopping VM: $VM_NAME"
        sudo systemctl stop "microvm-dynamic@$VM_NAME.service"
        ;;
        
      restart)
        VM_NAME="''${1:-}"
        if [ -z "$VM_NAME" ]; then
          echo "Usage: mvm restart <name>"
          exit 1
        fi
        
        echo "Restarting VM: $VM_NAME"
        sudo systemctl restart "microvm-dynamic@$VM_NAME.service"
        ;;
        
      shell)
        VM_NAME="''${1:-}"
        if [ -z "$VM_NAME" ]; then
          echo "Usage: mvm shell <name>"
          exit 1
        fi
        
        IP=$(get_vm_ip "$VM_NAME")
        if [ "$IP" = "unknown" ]; then
          echo "VM $VM_NAME is not running or IP not yet assigned"
          exit 1
        fi
        
        echo "Connecting to VM $VM_NAME at $IP..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$IP"
        ;;
        
      port)
        VM_NAME="''${1:-}"
        PORT_SPEC="''${2:-}"
        
        if [ -z "$VM_NAME" ] || [ -z "$PORT_SPEC" ]; then
          echo "Usage: mvm port <name> <host>:<guest>"
          exit 1
        fi
        
        # Parse port specification
        HOST_PORT="''${PORT_SPEC%%:*}"
        GUEST_PORT="''${PORT_SPEC##*:}"
        
        IP=$(get_vm_ip "$VM_NAME")
        if [ "$IP" = "unknown" ]; then
          echo "VM $VM_NAME is not running or IP not yet assigned"
          exit 1
        fi
        
        # Add port forwarding rule
        sudo iptables -t nat -A PREROUTING -p tcp --dport "$HOST_PORT" \
          -j DNAT --to-destination "$IP:$GUEST_PORT"
        sudo iptables -A FORWARD -p tcp -d "$IP" --dport "$GUEST_PORT" -j ACCEPT
        
        echo "Added port forward: $HOST_PORT -> $VM_NAME:$GUEST_PORT"
        ;;
        
      list)
        echo "MicroVMs:"
        echo "NAME                STATUS      IP              PROJECT"
        echo "----                ------      --              -------"
        
        for vm_dir in "$STATE_DIR"/*; do
          [ -d "$vm_dir" ] || continue
          vm_name="$(basename "$vm_dir")"
          status=$(get_vm_status "$vm_name")
          ip=$(get_vm_ip "$vm_name")
          
          # Read project from config if exists
          project="none"
          if [ -f "$vm_dir/config.json" ]; then
            project=$(jq -r '.projectDir // "none"' "$vm_dir/config.json" 2>/dev/null || echo "none")
          fi
          
          printf "%-20s %-10s %-15s %s\n" "$vm_name" "$status" "$ip" "$project"
        done
        ;;
        
      delete)
        VM_NAME="''${1:-}"
        if [ -z "$VM_NAME" ]; then
          echo "Usage: mvm delete <name>"
          exit 1
        fi
        
        # Stop VM if running
        if systemctl is-active "microvm@$VM_NAME.service" >/dev/null 2>&1; then
          echo "Stopping VM..."
          sudo systemctl stop "microvm@$VM_NAME.service"
        elif systemctl is-active "microvm-dynamic@$VM_NAME.service" >/dev/null 2>&1; then
          echo "Stopping dynamic VM..."
          sudo systemctl stop "microvm-dynamic@$VM_NAME.service"
        fi
        
        # Remove state directory
        if [ -d "$STATE_DIR/$VM_NAME" ]; then
          echo "Removing VM state..."
          rm -rf "$STATE_DIR/$VM_NAME"
        fi
        
        echo "VM $VM_NAME deleted"
        ;;
        
      help|*)
        cat <<EOF
    MicroVM Manager (mvm)
    
    Commands:
      create <name> [options]  Create a new microVM
        --project <path>       Mount project directory
        --vcpu <count>         Number of CPUs (default: 2)
        --mem <MB>             Memory in MB (default: 512)
        --persist              Enable persistent state
        
      start <name>             Start a microVM
      stop <name>              Stop a microVM
      restart <name>           Restart a microVM
      shell <name>             SSH into a microVM
      port <name> <h>:<g>      Forward host port to guest
      list                     List all microVMs
      delete <name>            Delete a microVM
      help                     Show this help
    
    Examples:
      mvm create myapp --project /home/user/myapp --mem 1024
      mvm start myapp
      mvm shell myapp
      mvm port myapp 8080:3000
    EOF
        [ "$COMMAND" = "help" ] && exit 0 || exit 1
        ;;
    esac
  '';
  
  # Helper script for project integration
  createMicrovmEnvScript = pkgs.writeShellScriptBin "create-microvm-env" ''
    set -euo pipefail
    
    PROJECT_DIR="$(pwd)"
    PROJECT_NAME="$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-')"
    
    # Check if devenv.nix exists
    DEVENV_OPTS=""
    if [ -f "devenv.nix" ]; then
      echo "Found devenv.nix, will configure VM with devenv support"
      DEVENV_OPTS="--devenv"
    fi
    
    # Create .envrc file
    cat > .envrc <<EOF
    # MicroVM environment for $PROJECT_NAME
    export MICROVM_NAME="$PROJECT_NAME"
    export MICROVM_PROJECT_DIR="$PROJECT_DIR"
    
    # Create VM if it doesn't exist
    if ! mvm list | grep -q "^$PROJECT_NAME "; then
      echo "Creating microVM: $PROJECT_NAME"
      mvm create "$PROJECT_NAME" --project "$PROJECT_DIR" $DEVENV_OPTS
      mvm start "$PROJECT_NAME"
    fi
    
    # Start VM if not running
    if ! mvm list | grep "$PROJECT_NAME" | grep -q "running"; then
      echo "Starting microVM: $PROJECT_NAME"
      mvm start "$PROJECT_NAME"
    fi
    
    # Helper function to run commands in VM
    vm() {
      mvm shell "$PROJECT_NAME" -- "\$@"
    }
    
    # Export the helper
    export -f vm
    
    echo "MicroVM '$PROJECT_NAME' is ready. Use 'vm <command>' to run commands in the VM."
    EOF
    
    echo "Created .envrc for microVM integration"
    echo "Run 'direnv allow' to activate"
  '';

in {
  config = mkIf cfg.enable {
    # Install CLI tools
    environment.systemPackages = [
      mvmScript
      createMicrovmEnvScript
      pkgs.jq  # For JSON parsing in scripts
    ];
    
    # Bash completion for mvm
    environment.etc."bash_completion.d/mvm" = {
      text = ''
        _mvm() {
          local cur prev opts
          COMPREPLY=()
          cur="''${COMP_WORDS[COMP_CWORD]}"
          prev="''${COMP_WORDS[COMP_CWORD-1]}"
          opts="create start stop restart shell port list delete help"
          
          case "''${prev}" in
            mvm)
              COMPREPLY=( $(compgen -W "''${opts}" -- ''${cur}) )
              return 0
              ;;
            start|stop|restart|shell|delete|port)
              # Complete with VM names
              local vms=$(mvm list 2>/dev/null | tail -n +3 | awk '{print $1}')
              COMPREPLY=( $(compgen -W "''${vms}" -- ''${cur}) )
              return 0
              ;;
            --project|-p)
              # Complete with directories
              COMPREPLY=( $(compgen -d -- ''${cur}) )
              return 0
              ;;
          esac
        }
        
        complete -F _mvm mvm
      '';
    };
    
    # Systemd service template for dynamic VMs
    systemd.services."microvm-dynamic@" = {
      description = "Dynamic MicroVM %i";
      after = [ "network.target" "microvm-network-setup.service" ];
      requires = [ "microvm-network-setup.service" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";
        
        # Security settings
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        
        # Resource limits
        LimitNOFILE = 1048576;
        LimitMEMLOCK = "infinity";
        
        # State directory
        StateDirectory = "microvm/%i";
        RuntimeDirectory = "microvm/%i";
      };
      
      script = ''
        VM_NAME="%i"
        CONFIG_FILE="/var/lib/microvm-dev/$VM_NAME/config.json"
        
        if [ ! -f "$CONFIG_FILE" ]; then
          echo "No configuration found for VM $VM_NAME"
          exit 1
        fi
        
        # Read configuration
        PROJECT_DIR=$(jq -r '.projectDir // ""' "$CONFIG_FILE")
        VCPU=$(jq -r '.vcpu // 2' "$CONFIG_FILE")
        MEM=$(jq -r '.mem // 512' "$CONFIG_FILE")
        PERSIST=$(jq -r '.persistState // false' "$CONFIG_FILE")
        
        # Note: Dynamic VM creation requires a more complex implementation
        # This service is a placeholder for VMs created via mvm command
        # In practice, VMs should be defined in the NixOS configuration
        echo "VM $VM_NAME is managed dynamically"
        echo "Project: $PROJECT_DIR"
        echo "Resources: $VCPU vCPUs, $MEM MB RAM"
        echo "Persistent: $PERSIST"
        
        # Keep service running
        exec sleep infinity
      '';
      
      preStop = ''
        echo "Stopping VM %i"
      '';
    };
  };
}