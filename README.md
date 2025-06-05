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

## Home Manager

### Updating Home Manager

With the migration to flakes, Home Manager is now integrated directly into the NixOS configuration. This means:

1. Home Manager configuration is applied automatically when you rebuild the system
2. No separate Home Manager commands are needed

```
# This single command updates both NixOS and Home Manager configurations
sudo nixos-rebuild switch --flake .#venator
```

### Migration from non-flakes to flakes

If you're migrating from a non-flakes setup to this flakes-based configuration:

1. Previous separate commands (non-flakes):
   ```bash
   # System configuration
   sudo nixos-rebuild switch
   
   # Home Manager configuration
   home-manager switch
   ```

2. New unified command (flakes):
   ```bash
   sudo nixos-rebuild switch --flake .#venator
   ```

The Home Manager configuration is now defined in `home/john/home.nix` and referenced in the `flake.nix` file. All Home Manager settings are applied as part of the system rebuild, eliminating the need for separate commands.