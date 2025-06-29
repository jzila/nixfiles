# MicroVM Development Environments

This module provides lightweight virtual machine support for isolated development environments using microvm.nix.

## Quick Start

### Enable MicroVM Support

In your `hosts/venator/configuration.nix`, enable the microVM service:

```nix
services.microvm-dev = {
  enable = true;
  
  # Define your VMs here (see examples below)
  vms = {
    # ...
  };
};
```

### Using the `mvm` Command

Once enabled, you can manage microVMs with the `mvm` command:

```bash
mvm list              # List all microVMs
mvm start <vm>        # Start a microVM
mvm stop <vm>         # Stop a microVM  
mvm restart <vm>      # Restart a microVM
mvm status <vm>       # Show status of a microVM
mvm console <vm>      # Connect to VM console
mvm ssh <vm>          # SSH into a microVM
```

## Example Configurations

### Basic Development VM

```nix
services.microvm-dev = {
  enable = true;
  
  vms.myproject = {
    enable = true;
    memory = 2048;  # 2GB RAM
    vcpu = 2;       # 2 CPUs
    
    # Share project directory
    shares = [{
      source = "/home/john/projects/myproject";
      mountPoint = "/project";
      tag = "project";
    }];
    
    # Forward ports
    forwardPorts = [
      { host.port = 3000; guest.port = 3000; }
    ];
    
    extraConfig = {
      config = {
        environment.systemPackages = with pkgs; [
          nodejs
          git
          neovim
        ];
      };
    };
  };
};
```

### Project-Specific VMs with direnv

For project-specific VMs that start/stop with direnv:

1. In your project directory, create a microVM environment:
   ```bash
   create-microvm-env [project-name]
   ```

2. Allow direnv:
   ```bash
   direnv allow
   ```

3. Use the `vm` helper function:
   ```bash
   vm ssh                    # SSH into the VM
   vm exec npm start         # Run commands in /project
   vm status                 # Check VM status
   vm stop                   # Stop the VM
   ```

### Using Flakes for Project VMs

Create a project-specific VM configuration:

```bash
microvm-flake-template
```

This creates a `flake.nix` that defines a microVM for your project. Edit it to add your required packages, then build and run:

```bash
nix build .#nixosConfigurations.dev-vm.config.microvm.runner
./result/bin/microvm-run
```

## Advanced Examples

See `microvm-examples.nix` for more complex configurations including:
- Node.js development environment
- Python development environment  
- Database testing environment (PostgreSQL + Redis)
- Isolated build environment with Docker

## Network Configuration

MicroVMs use a bridge network (`virbr0`) with NAT:
- Bridge IP: 192.168.122.1
- VM IP range: 192.168.122.2-254
- DNS and DHCP provided by dnsmasq

## Storage

### Ephemeral Storage
By default, VMs use ephemeral storage that's cleared on restart.

### Persistent Volumes
Add persistent storage with the `volumes` option:

```nix
volumes = [{
  image = "/var/lib/microvms/myvm/data.img";
  mountPoint = "/data";
  size = 10240;  # 10GB
}];
```

## File Sharing

Two protocols are supported:
- **virtiofs** (default): Better performance, recommended
- **9p**: More compatible, use if virtiofs has issues

```nix
shares = [{
  source = "/host/path";
  mountPoint = "/vm/path";
  tag = "share-name";
  proto = "virtiofs";  # or "9p"
}];
```

## Tips

1. **SSH Access**: VMs have password-less root by default. Configure proper authentication for production use.

2. **Performance**: Use virtiofs for file sharing when possible for better performance.

3. **Resource Limits**: Set appropriate memory and CPU limits to avoid overcommitting host resources.

4. **Networking**: Use port forwarding for services that need to be accessible from the host.

5. **State Management**: VMs are stateless by default. Use volumes for persistent data.

## Troubleshooting

- **VM Won't Start**: Check `systemctl status microvm-<name>` for errors
- **Can't SSH**: Wait a few seconds for the VM to boot and get an IP
- **File Sharing Issues**: Try switching from virtiofs to 9p protocol
- **Network Issues**: Ensure virbr0 bridge is up and dnsmasq is running