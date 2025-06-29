{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.microvm-dev;
  
  # State directory for all VMs
  stateDir = "/var/lib/microvm-dev";
  
  # Helper to create a microVM configuration
  mkMicroVM = name: vmCfg: let
    vmStateDir = "${stateDir}/${name}";
  in {
    inherit (vmCfg) vcpu mem balloonMem;
    
    # Use cloud-hypervisor by default for better performance
    hypervisor = vmCfg.hypervisor or "cloud-hypervisor";
    
    # Network configuration
    interfaces = [{
      type = "tap";
      id = "vm-${name}";
      mac = vmCfg.macAddress or (generateMacAddress name);
    }];
    
    # Storage volumes
    volumes = vmCfg.volumes ++ (optional vmCfg.persistState {
      image = "${vmStateDir}/state.img";
      mountPoint = "/persist";
      size = vmCfg.stateDiskSize;
    });
    
    # Shared directories - if overlayfs is enabled, we mount read-only
    shares = vmCfg.shares ++ (optional (vmCfg.projectDir != null) {
      source = vmCfg.projectDir;
      mountPoint = if vmCfg.overlayfs.enable then "/mnt/project-lower" else "/project";
      tag = "project";
      proto = vmCfg.shareProtocol;
      securityModel = "none";
      socket = null;
    });
    
    # Guest configuration
    config = { config, pkgs, ... }: mkMerge [
      vmCfg.guestConfig
      {
        imports = vmCfg.guestModules;
      
      # Basic system configuration
      system.stateVersion = vmCfg.stateVersion;
      
      # Networking
      networking = {
        hostName = name;
        useDHCP = false;
        interfaces.eth0.useDHCP = true;
        firewall.enable = vmCfg.enableFirewall;
        firewall.allowedTCPPorts = map (p: p.guest) vmCfg.forwardPorts;
      };
      
      # Enable SSH by default
      services.openssh = {
        enable = true;
        settings.PermitRootLogin = "yes";
      };
      
      # Set root password for easy access
      users.users.root.password = vmCfg.rootPassword;
      
      # Mount persistent storage if enabled
      fileSystems = mkIf vmCfg.persistState {
        "/persist" = {
          device = "/dev/vdb";
          fsType = "ext4";
          autoFormat = true;
        };
      };
      
      # Setup overlayfs for project directory
      systemd.services.setup-project-overlay = mkIf (vmCfg.projectDir != null && vmCfg.overlayfs.enable) {
        description = "Setup project overlay filesystem";
        wantedBy = [ "multi-user.target" ];
        before = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        
        script = ''
          # Create overlay directories
          mkdir -p /overlay/upper /overlay/work /project
          
          # Mount overlay
          mount -t overlay overlay \
            -o lowerdir=/mnt/project-lower,upperdir=/overlay/upper,workdir=/overlay/work \
            /project
        '';
        
        preStop = ''
          umount /project || true
        '';
      };
      
      # If using persistent storage, put overlay directories there
      systemd.tmpfiles.rules = mkIf (vmCfg.projectDir != null && vmCfg.overlayfs.enable) (
        if vmCfg.persistState then [
          "d /persist/overlay 0755 root root -"
          "L+ /overlay - - - - /persist/overlay"
        ] else [
          "d /overlay 0755 root root -"
        ]
      );
      }
    ];
  };
  
  # Generate a deterministic MAC address from VM name
  generateMacAddress = name: let
    hash = builtins.hashString "sha256" name;
    # Take first 6 bytes of hash and format as MAC
    bytes = map (i: substring (i * 2) 2 hash) (range 0 5);
    # Ensure locally administered and unicast
    firstByte = "02";
  in concatStringsSep ":" ([firstByte] ++ (tail bytes));

in {
  options.services.microvm-dev = {
    enable = mkEnableOption "microVM development environments";
    
    networkBridge = mkOption {
      type = types.str;
      default = "virbr-mvm";
      description = "Network bridge name for microVMs";
    };
    
    subnet = mkOption {
      type = types.str;
      default = "192.168.100.0/24";
      description = "Subnet for microVM network";
    };
    
    vms = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to enable this microVM";
          };
          
          vcpu = mkOption {
            type = types.int;
            default = 2;
            description = "Number of virtual CPUs";
          };
          
          mem = mkOption {
            type = types.int;
            default = 512;
            description = "Memory in MB";
          };
          
          balloonMem = mkOption {
            type = types.int;
            default = 512;
            description = "Balloon memory in MB";
          };
          
          hypervisor = mkOption {
            type = types.enum [ "cloud-hypervisor" "qemu" "firecracker" "crosvm" "kvmtool" ];
            default = "cloud-hypervisor";
            description = "Hypervisor to use";
          };
          
          stateVersion = mkOption {
            type = types.str;
            default = config.system.stateVersion;
            description = "NixOS state version for the guest";
          };
          
          projectDir = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Project directory to mount in the VM";
          };
          
          overlayfs = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Use overlayfs for project directory (allows modifications without affecting host)";
            };
          };
          
          shareProtocol = mkOption {
            type = types.enum [ "9p" "virtiofs" ];
            default = "virtiofs";
            description = "Protocol for sharing directories";
          };
          
          volumes = mkOption {
            type = types.listOf types.attrs;
            default = [];
            description = "Additional volumes to mount";
          };
          
          shares = mkOption {
            type = types.listOf types.attrs;
            default = [];
            description = "Additional directories to share";
          };
          
          persistState = mkOption {
            type = types.bool;
            default = false;
            description = "Persist VM state between restarts";
          };
          
          stateDir = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Directory to store persistent state";
          };
          
          stateDiskSize = mkOption {
            type = types.int;
            default = 1024;
            description = "Size of state disk in MB";
          };
          
          forwardPorts = mkOption {
            type = types.listOf (types.submodule {
              options = {
                host = mkOption {
                  type = types.int;
                  description = "Host port";
                };
                guest = mkOption {
                  type = types.int;
                  description = "Guest port";
                };
              };
            });
            default = [];
            description = "Ports to forward from host to guest";
          };
          
          macAddress = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "MAC address for the VM (auto-generated if null)";
          };
          
          enableFirewall = mkOption {
            type = types.bool;
            default = false;
            description = "Enable firewall in the guest";
          };
          
          rootPassword = mkOption {
            type = types.str;
            default = "root";
            description = "Root password for the VM";
          };
          
          guestModules = mkOption {
            type = types.listOf types.path;
            default = [];
            description = "Additional NixOS modules to import in the guest";
          };
          
          guestConfig = mkOption {
            type = types.deferredModule;
            default = {};
            description = "Additional NixOS configuration for the guest";
          };
        };
      });
      default = {};
      description = "MicroVM definitions";
    };
  };
  
  config = mkIf cfg.enable {
    # Enable microVM host support
    microvm.host.enable = true;
    
    # Define microVMs
    microvm.vms = mapAttrs mkMicroVM (filterAttrs (_: vm: vm.enable) cfg.vms);
    
    # Required kernel modules
    boot.kernelModules = [ "vhost_vsock" "vhost_net" "tun" "tap" ];
    
    # Create state directory
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
    ] ++ (concatLists (mapAttrsToList (name: vm: 
      optional vm.enable "d ${stateDir}/${name} 0755 root root -"
    ) cfg.vms));
    
    # Systemd service to manage VM state directories
    systemd.services.microvm-dev-init = {
      description = "Initialize microVM development environment";
      wantedBy = [ "multi-user.target" ];
      before = [ "microvm@.service" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      
      script = ''
        # Ensure state directory exists
        mkdir -p ${stateDir}
        
        # Create VM-specific directories
        ${concatStringsSep "\n" (mapAttrsToList (name: vm: 
          optionalString (vm.enable && vm.persistState) ''
            mkdir -p ${stateDir}/${name}
            # Create state disk if it doesn't exist
            if [ ! -f ${stateDir}/${name}/state.img ]; then
              ${pkgs.qemu}/bin/qemu-img create -f qcow2 ${stateDir}/${name}/state.img ${toString vm.stateDiskSize}M
            fi
          ''
        ) cfg.vms)}
      '';
    };
  };
}