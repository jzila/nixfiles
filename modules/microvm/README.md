# MicroVM Development Environment Implementation Plan

This module provides isolated development environments using microVMs with the following key features:

## Requirements & Features

- **Multiple VM Copies**: Spin up multiple isolated instances of the same environment
- **OverlayFS Integration**: Mount project directories with copy-on-write semantics
  - Read-only lower layer (host's project directory)
  - Writable upper layer per VM (isolated changes)
  - No full directory copying required
- **DevEnv.sh Support**: Auto-configure VMs from existing `devenv.nix` files
- **Network Isolation**: 
  - Internal networking isolated by default
  - Outbound connections via NAT
  - Configurable port forwarding for exposed services
- **State Persistence**: Optional persistent storage for VM state

## Architecture

### Module Structure

1. **base.nix** - Core microVM configuration
   - VM lifecycle management
   - Resource allocation (CPU, memory)
   - Basic guest configuration

2. **network.nix** - Network isolation and routing
   - Bridge network setup (virbr-mvm)
   - DHCP/DNS via dnsmasq
   - iptables rules for NAT and port forwarding
   - Per-VM network isolation

3. **storage.nix** - Storage and filesystem management
   - OverlayFS configuration for project mounts
   - Persistent volume support
   - State directory management

4. **devenv.nix** - DevEnv.sh integration
   - Auto-detection of devenv.nix files
   - Dynamic VM configuration from devenv
   - Support for both CLI and flake-based devenv

5. **cli.nix** - Command-line tools
   - `mvm` command for VM management
   - Shell functions for common operations
   - Direnv integration helpers

6. **examples/** - Example configurations
   - Node.js development
   - Python/Django
   - Database testing
   - Multi-service applications

## Usage

### Basic VM Definition

```nix
services.microvm-dev = {
  enable = true;
  vms.myproject = {
    vcpu = 2;
    mem = 1024;
    projectDir = /home/user/myproject;
    forwardPorts = [
      { host = 8080; guest = 3000; }
    ];
  };
};
```

### CLI Commands

```bash
# VM management
mvm create <name> --project <path>  # Create new VM
mvm start <name>                    # Start VM
mvm stop <name>                     # Stop VM
mvm shell <name>                    # Get shell in VM
mvm port <name> <host>:<guest>     # Add port forward
mvm list                            # List all VMs

# Project integration
cd /path/to/project
create-microvm-env                  # Generate .envrc
direnv allow                        # Auto-spawn VM
```

### DevEnv Integration

When a `devenv.nix` exists in the project directory:
1. VM automatically configures matching environment
2. All devenv packages available in VM
3. Services and processes managed by VM's systemd
4. Environment variables passed through

## Implementation Details

### Network Architecture

```
Host
├── virbr-mvm (192.168.100.1/24)
│   ├── dnsmasq (DHCP + DNS)
│   └── NAT to external network
└── VMs
    ├── vm1 (192.168.100.10)
    ├── vm2 (192.168.100.11)
    └── vm3 (192.168.100.12)
```

### Storage Layout

```
/project (in VM)
├── lower: /home/user/project (read-only bind)
├── upper: /var/lib/microvm/<name>/upper
├── work: /var/lib/microvm/<name>/work
└── merged: overlay filesystem
```

### Port Forwarding

- Dynamic iptables rules per VM
- Host ports forward to VM internal ports
- Persistent across VM restarts
- Cleaned up on VM removal

## Security Considerations

- VMs run with user privileges
- Network isolation prevents inter-VM communication
- OverlayFS prevents host filesystem modifications
- Resource limits prevent DoS