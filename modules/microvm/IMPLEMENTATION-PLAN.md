# MicroVM Implementation Plan

## Core Infrastructure (modules/microvm/)

- base.nix: Core microVM module with:
- Network isolation using bridge networking with NAT
- OverlayFS support for project directory mounting
- Port forwarding configuration
- State persistence options
- Resource management (CPU, memory)
- network.nix: Advanced networking setup:
- Isolated bridge network (virbr-mvm)
- DHCP/DNS via dnsmasq
- Port forwarding via iptables rules
- Outbound NAT for internet access
- storage.nix: Storage management:
- OverlayFS configuration for project directories
- Persistent volume support for state
- Ephemeral upper layers for isolation


## DevEnv Integration (modules/microvm/devenv.nix)

- Auto-detection of devenv.nix files
- Dynamic VM generation from devenv configs
- Support for both devenv CLI and flake-based setups
- Environment variable passthrough
- Process and service management


## VM Management Tools (modules/microvm/cli.nix)

- mvm command for VM lifecycle:
- mvm create <name> --project <path> - Create VM with project mount
- mvm start/stop/restart <name> - VM control
- mvm shell <name> - Interactive shell
- mvm port <name> <host>:<guest> - Dynamic port forwarding
- mvm list - Show all VMs with status
- Project integration:
- .envrc template for direnv users
- Auto-spawn VMs when entering directories
- Cleanup on directory exit


## Example Configurations (modules/microvm/examples/)

- Node.js development VM
- Python/Django VM
- Database testing VM
- Multi-service application VM


## Host Configuration Updates

- Add microvm.nix input to flake
- Enable microVM module in venator host
- Configure kernel modules for virtualization
- Set up required system packages


## Key Features Implementation:

1. Multiple VM Copies: Each VM gets unique ID and network config
2. OverlayFS Mounting: Read-only lower, writable upper per VM
3. DevEnv Support: Auto-configure from devenv.nix files
4. Network Isolation: Bridge network with configurable port exposure
5. Port Mapping: iptables-based forwarding with helper commands
6. State Persistence: Optional persistent volumes for data
