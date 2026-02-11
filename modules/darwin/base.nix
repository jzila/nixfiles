# macOS base configuration module (nix-darwin)
{ config, pkgs, pkgs-unstable, lib, ... }:

{
  imports = [ ../common/base.nix ];

  # Nix garbage collection (launchd syntax)
  nix.gc = {
    automatic = true;
    interval = { Weekday = 2; Hour = 3; Minute = 15; };
    options = "--delete-older-than 14d";
  };

  # macOS system defaults
  system.defaults = {
    dock = {
      autohide = false;
      show-recents = false;
    };
    finder = {
      AppleShowAllExtensions = true;
      FXPreferredViewStyle = "clmv";
    };
    NSGlobalDomain = {
      ApplePressAndHoldEnabled = false;
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
    };
  };

  # Homebrew for GUI apps not in nixpkgs
  homebrew = {
    enable = true;
    onActivation.cleanup = "zap";
    casks = [
      "google-chrome"
      "signal"
      "firefox"
    ];
  };

  # Tailscale VPN
  services.tailscale.enable = true;

  # Security - touch ID for sudo
  security.pam.enableSudoTouchIdAuth = true;

  # macOS-specific system packages
  environment.systemPackages = with pkgs; [
    # macOS utilities
    coreutils
  ];
}
