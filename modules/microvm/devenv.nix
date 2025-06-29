{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.microvm-dev;
  
  # Helper to detect and parse devenv.nix
  parseDevenvConfig = projectDir: let
    devenvPath = "${projectDir}/devenv.nix";
    flakePath = "${projectDir}/flake.nix";
  in
    if pathExists devenvPath then {
      type = "devenv";
      path = devenvPath;
    }
    else if pathExists flakePath then {
      type = "flake";
      path = flakePath;
    }
    else null;
  
  # Generate VM config from devenv
  mkDevenvVM = name: vmCfg: let
    devenvInfo = parseDevenvConfig vmCfg.projectDir;
  in mkIf (devenvInfo != null && vmCfg.autoConfigureDevenv) {
    # Add devenv-specific guest configuration
    guestConfig = mkMerge [
      vmCfg.guestConfig
      {
        # Import devenv in the guest
        imports = [ "${pkgs.devenv}/share/devenv/devenv.nix" ];
        
        # Configure the environment
        environment.systemPackages = with pkgs; [
          git
          direnv
          nix-direnv
        ];
        
        # Setup devenv activation
        system.activationScripts.devenv = ''
          # Link project directory
          if [ -d /project ]; then
            ln -sfn /project /home/devuser/project || true
          fi
        '';
        
        # Create development user
        users.users.devuser = {
          isNormalUser = true;
          home = "/home/devuser";
          shell = pkgs.bash;
          extraGroups = [ "wheel" "docker" ];
          password = "dev";  # Change in production
        };
        
        # Auto-start devenv shell
        systemd.services.devenv-shell = mkIf (devenvInfo.type == "devenv") {
          description = "Devenv development shell";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          
          serviceConfig = {
            Type = "simple";
            User = "devuser";
            WorkingDirectory = "/project";
            Restart = "always";
            RestartSec = "5s";
          };
          
          script = ''
            # Setup environment
            export HOME=/home/devuser
            export USER=devuser
            
            # Initialize devenv
            cd /project
            
            # If using flake-based devenv
            if [ -f flake.nix ]; then
              nix develop --impure -c bash
            else
              # Traditional devenv.nix
              devenv shell
            fi
          '';
        };
        
        # Environment variables from devenv
        environment.variables = {
          DEVENV_ROOT = "/project";
          DEVENV_DOTFILE = "/project/.devenv";
        };
        
        # Services commonly used in devenv
        services.postgresql = mkIf vmCfg.enableDatabaseServices {
          enable = true;
          package = pkgs.postgresql_15;
          ensureDatabases = [ "devdb" ];
          ensureUsers = [{
            name = "devuser";
            ensureDBOwnership = true;
          }];
        };
        
        services.redis = mkIf vmCfg.enableDatabaseServices {
          servers."" = {
            enable = true;
            bind = "127.0.0.1";
          };
        };
        
        services.mysql = mkIf vmCfg.enableDatabaseServices {
          enable = true;
          package = pkgs.mysql80;
          ensureDatabases = [ "devdb" ];
          ensureUsers = [{
            name = "devuser";
            ensurePermissions = {
              "devdb.*" = "ALL PRIVILEGES";
            };
          }];
        };
      }
    ];
  };
  
  # Enhanced VM options for devenv support
  devenvVmModule = {
    options = {
      autoConfigureDevenv = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically configure VM based on devenv.nix in project";
      };
      
      enableDatabaseServices = mkOption {
        type = types.bool;
        default = false;
        description = "Enable common database services (PostgreSQL, Redis, MySQL)";
      };
      
      devenvPackages = mkOption {
        type = types.listOf types.package;
        default = [];
        description = "Additional packages to install for devenv support";
      };
      
      devenvVariables = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Environment variables to set in the devenv";
      };
      
      processes = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Background processes to run (similar to devenv processes)";
      };
    };
  };

in {
  options.services.microvm-dev = {
    vms = mkOption {
      type = types.attrsOf (types.submodule [
        # Import existing VM options
        ({ ... }: {
          imports = [ devenvVmModule ];
        })
      ]);
    };
  };
  
  config = mkIf cfg.enable {
    
    # Enhanced mvm script with devenv support
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "mvm-devenv" ''
        set -euo pipefail
        
        PROJECT_DIR="''${1:-.}"
        VM_NAME="''${2:-$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-')}"
        
        # Check for devenv.nix or flake.nix
        if [ -f "$PROJECT_DIR/devenv.nix" ]; then
          echo "Found devenv.nix configuration"
          CONFIG_TYPE="devenv"
        elif [ -f "$PROJECT_DIR/flake.nix" ] && grep -q "devenv" "$PROJECT_DIR/flake.nix"; then
          echo "Found flake.nix with devenv"
          CONFIG_TYPE="flake"
        else
          echo "No devenv configuration found in $PROJECT_DIR"
          exit 1
        fi
        
        # Create VM with devenv support
        cat > /tmp/vm-config-$VM_NAME.nix <<EOF
        {
          services.microvm-dev.vms.$VM_NAME = {
            enable = true;
            projectDir = "$PROJECT_DIR";
            autoConfigureDevenv = true;
            vcpu = 4;
            mem = 2048;
            
            # Auto-detect needed services
            enableDatabaseServices = $(
              if grep -qE "(postgres|mysql|redis)" "$PROJECT_DIR/devenv.nix" 2>/dev/null; then
                echo "true"
              else
                echo "false"
              fi
            );
            
            # Forward common development ports
            forwardPorts = [
              { host = 3000; guest = 3000; }  # Node.js
              { host = 8000; guest = 8000; }  # Django/Python
              { host = 8080; guest = 8080; }  # General web
              { host = 4000; guest = 4000; }  # Phoenix
              { host = 5173; guest = 5173; }  # Vite
            ];
          };
        }
        EOF
        
        echo "Creating devenv-enabled VM: $VM_NAME"
        mvm create "$VM_NAME" --project "$PROJECT_DIR" --mem 2048 --vcpu 4
        mvm start "$VM_NAME"
        
        echo ""
        echo "VM $VM_NAME is ready with devenv support!"
        echo "Connect with: mvm shell $VM_NAME"
        echo "Or as devuser: ssh devuser@\$(mvm list | grep $VM_NAME | awk '{print \$3}')"
      '')
    ];
    
    # Systemd timer to sync devenv changes
    systemd.timers.microvm-devenv-sync = {
      description = "Sync devenv configurations to VMs";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "30min";
      };
    };
    
    systemd.services.microvm-devenv-sync = {
      description = "Sync devenv configurations to VMs";
      
      script = ''
        # Check all running VMs for devenv updates
        for vm_dir in /var/lib/microvm-dev/*; do
          [ -d "$vm_dir" ] || continue
          vm_name=$(basename "$vm_dir")
          
          # Check if VM is running and has devenv
          if systemctl is-active "microvm@$vm_name.service" >/dev/null 2>&1; then
            config_file="$vm_dir/config.json"
            if [ -f "$config_file" ]; then
              project_dir=$(${pkgs.jq}/bin/jq -r '.projectDir // ""' "$config_file")
              if [ -n "$project_dir" ] && [ -f "$project_dir/devenv.nix" ]; then
                echo "Checking devenv updates for $vm_name"
                # Could implement hot-reload here
              fi
            fi
          fi
        done
      '';
    };
  };
}