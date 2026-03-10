# nix-darwin module for Apple's container CLI.
#
# The container CLI binaries are code-signed with entitlements for
# Virtualization.framework and vmnet, so they must live at /usr/local/
# (outside the Nix store) to preserve their signatures.
#
# This module downloads the signed .pkg and installs it to /usr/local/
# via an activation script. The system service is started automatically
# after installation.
#
# Usage in your darwin configuration:
#   imports = [ ./modules/darwin/apple-container.nix ];
#   services.apple-container.enable = true;
#
# Requires macOS 26 (Tahoe) and Apple silicon.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.apple-container;
in {
  options.services.apple-container = {
    enable = lib.mkEnableOption "Apple container CLI for running Linux containers as lightweight VMs";

    version = lib.mkOption {
      type = lib.types.str;
      default = "0.10.0";
      description = "Version of the container CLI to install.";
    };

    hash = lib.mkOption {
      type = lib.types.str;
      default = "sha256-xIHONVUk0DbDzdrH/SgeMXlNQGkL+aIfcy7z12+p/gg=";
      description = "SRI hash of the installer .pkg. Update when changing version.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install the signed .pkg to /usr/local/ and start the system service.
    # Uses xar + pax (same method as upstream `make install`).
    system.activationScripts.postActivation.text = let
      src = pkgs.fetchurl {
        url = "https://github.com/apple/container/releases/download/${cfg.version}/container-${cfg.version}-installer-signed.pkg";
        hash = cfg.hash;
      };
    in ''
      echo "Checking Apple container CLI..."
      installed_version=""
      if [ -x /usr/local/bin/container ]; then
        installed_version=$(/usr/local/bin/container version 2>/dev/null || true)
      fi
      if echo "$installed_version" | grep -q "${cfg.version}"; then
        echo "Apple container CLI ${cfg.version} already installed."
      else
        echo "Installing Apple container CLI ${cfg.version}..."
        /usr/local/bin/container system stop 2>/dev/null || true
        temp_dir=$(mktemp -d)
        ${pkgs.xar}/bin/xar -xf ${src} -C "$temp_dir"
        (cd /usr/local && pax -rz -f "$temp_dir"/Payload)
        rm -rf "$temp_dir"
        echo "Apple container CLI ${cfg.version} installed."
      fi

      # Ensure the system service is running
      if ! /usr/local/bin/container system info &>/dev/null; then
        echo "Starting Apple container system service..."
        /usr/local/bin/container system start
      fi
    '';
  };
}
