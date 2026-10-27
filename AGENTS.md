# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex, etc.) when working with code in this repository. `CLAUDE.md` just imports it.

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
- `flake.nix` - Main flake defining inputs (nixpkgs, home-manager, hardware, plasma-manager) and outputs
- Two nixpkgs inputs: stable (24.11) and unstable, plus specialized ollama packages
- Home Manager integrated as a NixOS module, not standalone
- Uses dynamic host loading with `mkHost` helper function for maintainable configuration
- All flake inputs passed via `specialArgs` and `extraSpecialArgs` using `inputs` directly

### Configuration Organization
- `hosts/venator/` - System-specific configuration for main laptop
- `home/john/` - User-specific Home Manager configuration  
- `modules/` - Reusable modules (Plasma, Ollama containers)
- Host imports nixos-hardware module for ASUS Zephyrus GA402 optimizations

### Key Integration Points
- Home Manager users defined in flake.nix via `home-manager.users.john`
- All flake inputs available to modules via `specialArgs = inputs` pattern
- Plasma configuration modularized in `modules/plasma/` with plasma-manager integration
- `modules/gdrive.nix` exposes `services.gdrive.{mount, bisync}`, a Linux-only Home Manager module for Google Drive via rclone: `mount` is an on-demand FUSE mount at `~/GoogleDrive`, on by default on every Linux host that doesn't run `bisync`; `bisync` is a two-way sync with `bisync.target` on a timer, plus an inotify `watch` for local writes (argo, Drive ↔ `/mnt/zila-family/drive`, the TrueNAS `zila-family` dataset over NFS). rclone's OAuth token lives in the unmanaged `~/.config/rclone/rclone.conf`, never in the repo; services wait until it exists
- Hermes (an AI agent; the GitHub App `zila-hermes`) and the runners for `jzila/home-assistant` run in the hermes VM on the TrueNAS box: `hosts/hermes/` (its README has setup, cut-over and rollback). How each part works is in its file's header: `modules/hermes-container.nix`, `modules/hermes-service.nix`, `modules/ha-gitops.nix`, `modules/hermes-scripts/`, `modules/hermes-plugins/`. argo keeps those modules imported but off.
- Hermes changes this repo only through PRs, and every merge needs John's approval (`.github/CODEOWNERS`, code owner review on `main`). `.github/workflows/protected-paths.yml` comments on PRs that touch Hermes's own setup; keep its `protected` regex current when those files move or new ones appear.
- Container infrastructure with Podman configured at system level
- TMUX configuration handled via `home.sessionVariables` instead of script files

### Hardware-Specific Features
- AMD GPU with ROCm support enabled
- AMDGPU kernel module configuration for compute workloads
- TLP power management with AC/battery profiles
- AppImage support via binfmt registration
- Hardware-accelerated video drivers

## Development Workflow

Do all branch work in a git worktree under `.agent-worktrees/` (gitignored); keep the main checkout on `main`.

Since Home Manager is integrated into the system flake, any changes to user packages, shell configuration, or dotfiles require a full system rebuild with `sudo nixos-rebuild switch --flake .#venator`. There are no separate `home-manager switch` commands.

The configuration references external dotfiles in `/home/john/repos/dotfiles/` for Zsh and Tmux configurations.

## Important Notes

### NixOS Version Compatibility
- Currently using NixOS 24.11 stable channel
- Some options (like `sound.enable`) were removed in 24.11 - use PipeWire configuration instead
- Hardware options like `hardware.amdgpu` require NixOS 24.05+ for nixos-hardware compatibility

### Flake Management
- Always run `nix flake update` after changing input URLs in flake.nix
- The flake uses `@inputs` pattern to make all inputs available to modules
- Custom package sets (pkgs-unstable, pkgs-jzila) are merged with inputs in specialArgs
- The release-archive packages under `./pkgs/` (opencode-bin, roborev-bin, kata-bin, ollama-rocm-bin on x86_64-linux, zed-editor-bin on darwin) are defined once, via `mkLocalPackages` in flake.nix; that same set backs the `packages.<system>` flake output and is handed to both NixOS and Home Manager as the `localPkgs` specialArg, so `home/john/home.nix` references `localPkgs.<name>` instead of calling `callPackage` on `./pkgs/*` a second time