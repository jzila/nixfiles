# NixOS Configuration (Flakes)

This is a NixOS configuration using the Flakes feature.

## System

- Host: `venator` - ASUS Zephyrus GA402
- Desktop: KDE Plasma

## Structure

- `flake.nix` - The main flake file that defines inputs and outputs
- `hosts/` - System configurations
  - `venator/` - Configuration for main laptop
- `home/` - Home-manager configurations
  - `john/` - User configuration
- `modules/` - Reusable configuration modules
  - `plasma/` - KDE Plasma configuration
  - `ollama.nix` - Ollama container configuration

## Usage

### Building and activating the system

```
sudo nixos-rebuild switch --flake .#venator
```

### Updating dependencies

```
nix flake update
```

### Building the ASUS ISO

```
nix build .#nixosConfigurations.asus-iso.config.system.build.isoImage
```