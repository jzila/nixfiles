# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a NixOS configuration using flakes for a laptop system (ASUS Zephyrus GA402) with KDE Plasma desktop. The configuration integrates Home Manager directly into the flake, eliminating the need for separate Home Manager commands.

## Key Commands

### System Management
```bash
# Build and activate the system configuration
sudo nixos-rebuild switch --flake .#venator

# Update all flake inputs
nix flake update

# Build ASUS installation ISO
nix build .#nixosConfigurations.asus-iso.config.system.build.isoImage
```

### Development Environment
The system includes development tools installed via both NixOS packages and Home Manager:
- Languages: Python 3, Node.js 22, Go, Bun
- Editors: VS Code (unstable), Zed, Neovim, LunarVim
- Version control: Git, Lazygit, Delta, GitHub CLI
- Containers: Podman (with Docker compatibility), Podman Compose

## Architecture

### Flake Structure
- `flake.nix` - Main flake defining inputs (nixpkgs, home-manager, hardware) and outputs
- Two nixpkgs inputs: stable (23.11) and unstable, plus specialized ollama packages
- Home Manager integrated as a NixOS module, not standalone

### Configuration Organization
- `hosts/venator/` - System-specific configuration for main laptop
- `home/john/` - User-specific Home Manager configuration  
- `modules/` - Reusable modules (Plasma, Ollama containers)
- Host imports nixos-hardware module for ASUS Zephyrus GA402 optimizations

### Key Integration Points
- Home Manager users defined in flake.nix via `home-manager.users.john`
- Special args pass unstable packages and extensions to both system and home configs
- Plasma configuration modularized in `modules/plasma/`
- Container infrastructure with Podman configured at system level

### Hardware-Specific Features
- AMD GPU with ROCm support enabled
- AMDGPU kernel module configuration for compute workloads
- TLP power management with AC/battery profiles
- AppImage support via binfmt registration
- Hardware-accelerated video drivers

## Development Workflow

Since Home Manager is integrated into the system flake, any changes to user packages, shell configuration, or dotfiles require a full system rebuild with `sudo nixos-rebuild switch --flake .#venator`. There are no separate `home-manager switch` commands.

The configuration references external dotfiles in `/home/john/repos/dotfiles/` for Zsh and Tmux configurations.