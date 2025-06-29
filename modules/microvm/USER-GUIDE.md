# MicroVM Development Environment User Guide

This guide covers how to use the microVM system for isolated development environments on your NixOS system.

## Quick Start

### 1. Enable MicroVM Support

The microVM system is already enabled in your configuration. After running `sudo nixos-rebuild switch --flake .#venator`, you'll have access to the `mvm` command.

**Note**: Due to NixOS's declarative nature, VMs must be defined in your configuration. The `mvm create` command creates configuration templates that need to be added to your NixOS configuration for full functionality.

### 2. Create Your First VM

```bash
# Create a simple VM
mvm create myapp --mem 2048 --vcpu 4

# Create a VM with a project directory mounted
mvm create myproject --project /home/john/projects/myapp --mem 2048

# Create a VM with persistent state
mvm create database --persist --mem 4096
```

### 3. Start and Access the VM

```bash
# Start the VM
mvm start myapp

# Get a shell in the VM
mvm shell myapp

# List all VMs
mvm list
```

## Working with Project Directories

### OverlayFS Integration

When you mount a project directory, the VM uses OverlayFS to create an isolated view:
- The original project files are read-only (lower layer)
- All changes are stored in a separate layer (upper layer)
- VMs can modify files without affecting the host

```bash
# Create a VM with project directory
mvm create webapp --project /home/john/projects/webapp

# In the VM, project files are at /project
mvm shell webapp
cd /project
# Make any changes - they won't affect the host!
```

### Direnv Integration

For automatic VM management when entering project directories:

```bash
cd /home/john/projects/myapp
create-microvm-env

# This creates a .envrc file
direnv allow

# Now the VM starts automatically when you enter the directory
# Use the 'vm' function to run commands in the VM
vm npm install
vm npm run dev
```

## DevEnv.sh Integration

### Automatic Configuration

If your project has a `devenv.nix` file, use the helper:

```bash
cd /path/to/project-with-devenv
mvm-devenv .

# This creates a VM configured based on your devenv.nix
```

### Manual Configuration

For more control, create a VM with devenv support:

```nix
# In your host configuration or a custom module
services.microvm-dev.vms.myproject = {
  enable = true;
  projectDir = /home/john/projects/myproject;
  autoConfigureDevenv = true;
  enableDatabaseServices = true;  # If your devenv uses databases
};
```

## Port Forwarding

### Static Port Forwarding

Define in your VM configuration:

```nix
services.microvm-dev.vms.webapp = {
  forwardPorts = [
    { host = 8080; guest = 3000; }  # Access VM's port 3000 on host's 8080
    { host = 5432; guest = 5432; }  # PostgreSQL
  ];
};
```

### Dynamic Port Forwarding

Add port forwards on the fly:

```bash
# Forward host port 8080 to VM's port 3000
mvm port myapp 8080:3000

# Now access http://localhost:8080 to reach the VM's service
```

## Common Use Cases

### Node.js Development

```bash
# Create a Node.js dev VM
mvm create nodeapp --project /home/john/projects/my-node-app --mem 2048

# Start and enter the VM
mvm start nodeapp
mvm shell nodeapp

# Install dependencies and run dev server
cd /project
npm install
npm run dev
```

### Python/Django Development

```bash
# Create VM with more memory for databases
mvm create djangoapp --project /home/john/projects/django-site --mem 4096

# The VM can be configured to include PostgreSQL
# See examples.nix for full Python/Django configuration
```

### Database Testing

```bash
# Create a persistent VM for databases
mvm create databases --persist --mem 4096

# Configure multiple databases in the VM
# See examples.nix for multi-database setup
```

### Build Isolation

```bash
# Create a VM for isolated builds
mvm create builder --mem 8192 --vcpu 8

# Use it for untrusted or experimental builds
mvm shell builder
# Build processes are completely isolated from host
```

## Network Isolation

Each VM is isolated on its own network:
- VMs can access the internet through NAT
- VMs cannot see each other by default
- Host services are not exposed to VMs
- Use port forwarding to expose specific services

## Persistence

### Ephemeral VMs (Default)

- VM state is lost on stop
- Project changes via OverlayFS are lost
- Good for testing and experiments

### Persistent VMs

```bash
# Create with persistence
mvm create mydb --persist

# State is preserved across restarts
# Stored in /var/lib/microvm-dev/<name>/
```

## Troubleshooting

### VM Won't Start

```bash
# Check systemd logs
journalctl -u microvm@myapp -f

# Ensure the bridge network is up
ip link show virbr-mvm
```

### Can't Access VM

```bash
# Check if VM has an IP
mvm list

# If no IP shown, check DHCP
sudo systemctl status dnsmasq
```

### Port Forwarding Not Working

```bash
# Check firewall rules
sudo iptables -t nat -L PREROUTING -n -v

# Ensure VM service is listening
mvm shell myapp
netstat -tlnp
```

## Advanced Configuration

For complex setups, create a custom VM configuration:

```nix
# In /etc/nixos/myproject-vm.nix or your flake
services.microvm-dev.vms.complex = {
  enable = true;
  vcpu = 8;
  mem = 8192;
  
  # Multiple volume mounts
  volumes = [
    { image = "/var/lib/vms/data.img"; mountPoint = "/data"; size = 10240; }
  ];
  
  # Multiple shares
  shares = [
    { source = "/home/john/data"; mountPoint = "/shared-data"; proto = "virtiofs"; }
  ];
  
  # Custom guest configuration
  guestConfig = {
    # Your full NixOS configuration here
    services.postgresql.enable = true;
    # ... etc
  };
};
```

## Best Practices

1. **Resource Allocation**: Don't over-allocate CPU/memory. Start small and increase as needed.

2. **Project Organization**: Use direnv integration for projects you work on regularly.

3. **Cleanup**: Delete unused VMs to free resources:
   ```bash
   mvm delete old-project
   ```

4. **Security**: Change default passwords in production use.

5. **Backups**: For persistent VMs, backup `/var/lib/microvm-dev/<name>/` regularly.