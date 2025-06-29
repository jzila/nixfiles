{ config, lib, pkgs, ... }:

with lib;

{
  # Example VM configurations that can be imported or used as reference
  
  # Node.js development environment
  services.microvm-dev.vms.nodejs-example = {
    enable = false;  # Set to true to enable
    vcpu = 2;
    mem = 1024;
    
    guestConfig = {
      # Node.js development packages
      environment.systemPackages = with pkgs; [
        nodejs_22
        nodePackages.pnpm
        nodePackages.yarn
        nodePackages.typescript
        nodePackages.prettier
        git
      ];
      
      # Common Node.js ports
      networking.firewall.allowedTCPPorts = [ 3000 3001 5173 8080 ];
      
      # Development user
      users.users.developer = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        shell = pkgs.zsh;
        packages = with pkgs; [ oh-my-zsh ];
      };
      
      # Auto-start development server if package.json exists
      systemd.services.node-dev-server = {
        description = "Node.js development server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        
        serviceConfig = {
          Type = "simple";
          User = "developer";
          WorkingDirectory = "/project";
          Restart = "on-failure";
          Environment = "NODE_ENV=development";
        };
        
        script = ''
          if [ -f /project/package.json ]; then
            if [ -f /project/pnpm-lock.yaml ]; then
              pnpm install && pnpm dev
            elif [ -f /project/yarn.lock ]; then
              yarn install && yarn dev
            else
              npm install && npm run dev
            fi
          else
            echo "No package.json found"
            sleep infinity
          fi
        '';
      };
    };
    
    forwardPorts = [
      { host = 3000; guest = 3000; }
      { host = 5173; guest = 5173; }  # Vite
    ];
  };
  
  # Python/Django development environment
  services.microvm-dev.vms.python-example = {
    enable = false;
    vcpu = 2;
    mem = 1024;
    
    guestConfig = {
      environment.systemPackages = with pkgs; [
        python312
        python312Packages.pip
        python312Packages.virtualenv
        python312Packages.poetry
        python312Packages.django
        python312Packages.flask
        python312Packages.pytest
        python312Packages.black
        python312Packages.flake8
        git
        postgresql_15
      ];
      
      services.postgresql = {
        enable = true;
        ensureDatabases = [ "devdb" ];
        ensureUsers = [{
          name = "developer";
          ensureDBOwnership = true;
        }];
        authentication = ''
          local all all trust
          host all all 127.0.0.1/32 trust
        '';
      };
      
      users.users.developer = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
      
      # Django development server
      systemd.services.django-dev = {
        description = "Django development server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "postgresql.service" ];
        
        serviceConfig = {
          Type = "simple";
          User = "developer";
          WorkingDirectory = "/project";
          Environment = [
            "DJANGO_SETTINGS_MODULE=myproject.settings"
            "DATABASE_URL=postgresql://developer@localhost/devdb"
          ];
        };
        
        script = ''
          if [ -f /project/manage.py ]; then
            python manage.py migrate
            python manage.py runserver 0.0.0.0:8000
          else
            echo "No Django project found"
            sleep infinity
          fi
        '';
      };
    };
    
    forwardPorts = [
      { host = 8000; guest = 8000; }
      { host = 5432; guest = 5432; }  # PostgreSQL
    ];
  };
  
  # Database testing environment
  services.microvm-dev.vms.database-example = {
    enable = false;
    vcpu = 4;
    mem = 2048;
    persistState = true;  # Keep database data
    stateDiskSize = 10240;  # 10GB for databases
    
    guestConfig = {
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_15;
        settings = {
          shared_buffers = "256MB";
          effective_cache_size = "1GB";
        };
      };
      
      services.mysql = {
        enable = true;
        package = pkgs.mysql80;
        settings = {
          mysqld = {
            innodb_buffer_pool_size = "512M";
          };
        };
      };
      
      services.redis = {
        servers."" = {
          enable = true;
          bind = "0.0.0.0";
          requirePassAuth = "devpassword";
        };
      };
      
      services.mongodb = {
        enable = true;
        bind_ip = "0.0.0.0";
      };
      
      # Database admin tools
      environment.systemPackages = with pkgs; [
        pgcli
        mycli
        redis
        mongosh
      ];
      
      networking.firewall.allowedTCPPorts = [
        5432  # PostgreSQL
        3306  # MySQL
        6379  # Redis
        27017 # MongoDB
      ];
    };
    
    forwardPorts = [
      { host = 5432; guest = 5432; }
      { host = 3306; guest = 3306; }
      { host = 6379; guest = 6379; }
      { host = 27017; guest = 27017; }
    ];
  };
  
  # Isolated build environment
  services.microvm-dev.vms.builder-example = {
    enable = false;
    vcpu = 8;
    mem = 4096;
    
    guestConfig = {
      # Enable Docker in VM for isolated builds
      virtualisation.docker = {
        enable = true;
        autoPrune.enable = true;
      };
      
      # Build tools
      environment.systemPackages = with pkgs; [
        docker-compose
        buildah
        skopeo
        git
        gnumake
        gcc
        binutils
        pkg-config
        openssl
        # Language-specific build tools
        go
        rustc
        cargo
        nodejs
        python3
        openjdk
      ];
      
      users.users.builder = {
        isNormalUser = true;
        extraGroups = [ "wheel" "docker" ];
      };
      
      # Nix daemon for reproducible builds
      services.nix-daemon.enable = true;
      nix = {
        settings = {
          experimental-features = [ "nix-command" "flakes" ];
          trusted-users = [ "builder" ];
        };
      };
    };
  };
  
  # Multi-service application example
  services.microvm-dev.vms.fullstack-example = {
    enable = false;
    vcpu = 4;
    mem = 4096;
    persistState = true;
    
    guestConfig = {
      # Frontend tooling
      environment.systemPackages = with pkgs; [
        nodejs_22
        nodePackages.pnpm
        # Backend tooling
        go
        air  # Go live reload
        # Database tools
        postgresql_15
        redis
        # Utilities
        nginx
        certbot
        git
      ];
      
      # Services
      services.postgresql = {
        enable = true;
        ensureDatabases = [ "app" ];
      };
      
      services.redis.servers."" = {
        enable = true;
      };
      
      services.nginx = {
        enable = true;
        virtualHosts."app.local" = {
          locations."/" = {
            proxyPass = "http://localhost:3000";  # Frontend
          };
          locations."/api" = {
            proxyPass = "http://localhost:8080";  # Backend
          };
        };
      };
      
      # Development processes
      systemd.services = {
        frontend-dev = {
          description = "Frontend development server";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "simple";
            User = "developer";
            WorkingDirectory = "/project/frontend";
            Environment = "PORT=3000";
          };
          script = "pnpm install && pnpm dev";
        };
        
        backend-dev = {
          description = "Backend development server";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "simple";
            User = "developer";
            WorkingDirectory = "/project/backend";
            Environment = [
              "DATABASE_URL=postgresql://localhost/app"
              "REDIS_URL=redis://localhost:6379"
            ];
          };
          script = "air";  # Go live reload
        };
      };
      
      users.users.developer = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
    };
    
    forwardPorts = [
      { host = 80; guest = 80; }      # Nginx
      { host = 3000; guest = 3000; }   # Frontend dev
      { host = 8080; guest = 8080; }   # Backend API
      { host = 5432; guest = 5432; }   # PostgreSQL
      { host = 6379; guest = 6379; }   # Redis
    ];
  };
}