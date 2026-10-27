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
- `modules/ha-gitops.nix` (argo) runs the GitHub Actions runners for the private `jzila/home-assistant` repo (Home Assistant declared with OpenTofu): `ha` holds the HA credentials from root-only `/etc/ha-tofu` and a job-started hook refuses anything not from `main`; `ha-pr` plans PRs with no credentials; nightly drift is filed on the hass kanban board (`ha-drift-report`) and completed by the next clean night
- `modules/hermes-container.nix` also takes PR events: `.github/workflows/pr-events.yml` (here and in home-assistant) joins the tailnet as `tag:github-ci` via Tailscale workload identity federation and posts `{repo, pr}` to argo:8646, which reaches Hermes's `github-pr` webhook route; `modules/hermes-scripts/github-pr.py` reads the PR from GitHub and starts an agent turn only for new reviews or comments from John on Hermes's own PRs, or ones mentioning @zila-hermes on any PR. Home Assistant also posts its logged errors (and `homeassistant.config`'s warnings) over the mutual-TLS webhook to the `ha-log` route: `modules/hermes-scripts/ha-log.py` keeps one hass kanban task per distinct issue (per device for the errors saying a device can't be reached, which Home Assistant's `hermes_ha_unreachable` sends only once the device has been unreachable for 30 minutes, and never for devices labelled `sleeps`) and starts a triage turn (to Signal) only for a new one, at most 5 an hour and once a day per issue; the turn completes the task itself when the error was transient and has cleared; `nix build .#checks.x86_64-linux.ha-log` runs `test_ha_log.py`
- Hermes changes this repo (argo, its own setup, other hosts) only through PRs, via the skill `modules/hermes-skills/nixfiles-changes/` (installed with `hermesHomeFiles` like `home-assistant-changes`). Every merge needs John's approval: `.github/CODEOWNERS` makes him the code owner and the `main` ruleset requires a code owner review, so collaborators' approvals don't count. `.github/workflows/protected-paths.yml` never fails; it comments on PRs that touch the files defining Hermes's own permissions or argo's system (`.github/`, Hermes's container, inner system, credentials, scripts and skills, `signal-cli.nix`, `ha-gitops.nix`, `hosts/argo/`, `hosts/hermes/`, `flake.nix`/`flake.lock`; the one exact list is the `protected` regex in that workflow) so they stand out; keep that regex current when such files move or new ones appear. In the container, Hermes's webhook scripts, these skills, `config.yaml` and `.env` are mounted read-only (`readOnlyState` in `modules/hermes-service.nix`), so Hermes can't change them live either. `pkgs/` bumps (`scripts/update-bin.sh`) are deliberately not flagged
- Hermes is moving from the container on argo to its own VM on the TrueNAS box, next to Home Assistant's (prototype; the container on argo stays the live Hermes until the manual cut-over in `hosts/hermes/README.md`, and Signal never runs in two places). The VM (`hosts/hermes/`, `nixosConfigurations.hermes`; UEFI qcow2 for TrueNAS: `nix build .#hermes-image`) hosts three NixOS containers: `hermes`, the same `modules/hermes-container.nix` as argo's (inner system `modules/hermes-service.nix`, identical on both; `services.hermesContainer.*` options carry what differs: addresses, `ollamaHost`/`allowedLanTargets` for argo's Ollama over the LAN, `hideNixDaemon`), and `ha`/`ha-pr`, the runners from `modules/ha-gitops.nix` (`services.haGitops.containers`; argo runs them as host services until the cut-over). The VM host keeps the credentials (`modules/hermes-credentials.nix`: its own GitHub App key and token, step-ca webhook certificate), runs Tailscale as its own node (`tag:hermes`; 8646 from the tailnet and 8645 from HA are DNATed into the container, as on argo), and lets only root and the runners use its nix-daemon (Hermes doesn't build; CI checks its PRs). Ollama on argo is open to the LAN, the VM included. The VM deploys main to itself (`hosts/hermes/deploy.nix`: CI check `Build NixOS (hermes)` on the exact commit, pinned build, health check incl. `hermes-health` from inside the container, rollback, `hermes deploy:` kanban task); argo stays manual. Tests: `bash hosts/hermes/deploy/test.sh` (flake check `hermes-deploy`)
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