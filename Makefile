asus-iso:
	nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage -I nixos-config=asus-iso.nix
