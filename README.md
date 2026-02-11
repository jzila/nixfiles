# NixOS Configuration (Flakes)

This is a cross-platform Nix configuration using Flakes, supporting both NixOS (Linux) and nix-darwin (macOS).

## Systems

- `venator` - ASUS Zephyrus GA402 (NixOS, KDE Plasma)
- `argo` - Framework Desktop (NixOS, KDE Plasma)
- `macbook` - MacBook (nix-darwin, Apple Silicon)

## Structure

- `flake.nix` - The main flake file that defines inputs and outputs
- `hosts/` - System configurations
  - `venator/` - ASUS Zephyrus laptop
  - `argo/` - Framework Desktop
  - `macbook/` - MacBook (nix-darwin)
- `home/` - Home-manager configurations
  - `john/` - User configuration (cross-platform)
- `modules/` - Reusable configuration modules
  - `common/` - Cross-platform settings shared between NixOS and nix-darwin
  - `darwin/` - macOS-specific configuration
  - `desktop/` - Linux desktop configuration
  - `plasma/` - KDE Plasma configuration

## Usage

### NixOS

```bash
# Build and activate the system configuration
sudo nixos-rebuild switch --flake .#venator
```

### nix-darwin (macOS)

After the initial bootstrap (see below), rebuild with:

```bash
sudo darwin-rebuild switch --flake .#macbook
```

### Updating dependencies

```bash
nix flake update
```

### Building the ASUS ISO

```bash
nix build .#nixosConfigurations.asus-iso.config.system.build.isoImage
```

## Bootstrapping nix-darwin on a new Mac

Prerequisites: [Install Nix](https://nixos.org/download/) and clone this repo.

### 1. Back up managed shell rc files

nix-darwin needs to manage `/etc/bashrc` and `/etc/zshrc`. Back up the originals first:

```bash
sudo mv /etc/bashrc /etc/bashrc.before-nix-darwin
sudo mv /etc/zshrc /etc/zshrc.before-nix-darwin
```

### 2. Run the initial bootstrap

```bash
sudo nix run nix-darwin -- switch --flake .#macbook
```

> **Note:** You may see a warning like:
> ```
> warning: $HOME ('/Users/john') is not owned by you, falling back to the one defined in the 'passwd' file ('/var/root')
> ```
> This is harmless — it happens because `sudo` runs as root while `$HOME` is still set to your user directory. It does not affect the build or activation.

### 3. Subsequent rebuilds

After the initial bootstrap, `darwin-rebuild` is on your PATH:

```bash
sudo darwin-rebuild switch --flake .#macbook
```

## Home Manager

Home Manager is integrated directly into both NixOS and nix-darwin configurations. No separate Home Manager commands are needed — user configuration is applied automatically when you rebuild the system.

```bash
# NixOS - rebuilds system and home configuration
sudo nixos-rebuild switch --flake .#venator

# nix-darwin - rebuilds system and home configuration
sudo darwin-rebuild switch --flake .#macbook
```
