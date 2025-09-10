# Netboot installer configuration for Framework Desktop (argo)
{ config, pkgs, pkgs-unstable, lib, nixos-hardware, nixpkgs, nixpkgs-unstable, ... }:

{
  imports = [
    # Framework Desktop hardware support for netboot
    nixos-hardware.nixosModules.framework-amd-ai-300-series
    # Netboot base configuration
    "${nixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
    # Shared desktop configuration (minimal subset for installer)
    ../../modules/desktop/aliza.nix
  ];

  # System identification
  networking.hostName = "argo-netboot";

  # Enable ROCm support for AMD graphics
  nixpkgs.config.rocmSupport = true;

  # Graphics configuration for AMD Ryzen AI Max 300 series
  services.xserver.videoDrivers = [ "amdgpu" ];
  
  # Enable hardware graphics acceleration
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = [
    pkgs-unstable.amdvlk
    pkgs.rocmPackages.clr.icd
  ];

  # Override desktop services for netboot environment
  services.xserver.enable = lib.mkForce false;
  services.displayManager.sddm.enable = lib.mkForce false;
  services.desktopManager.plasma6.enable = lib.mkForce false;

  # Enable SSH for remote installation
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = false;
    };
  };

  # SSH access via certificate authentication (configured by SSH CA module)
  # No hardcoded keys needed - certificates are validated against the CA

  # Essential installer packages
  environment.systemPackages = with pkgs; [
    # Core utilities
    git
    curl
    wget
    rsync
    
    # Installation tools
    nixos-install-tools
    parted
    gptfdisk
    cryptsetup
    
    # Hardware detection
    pciutils
    usbutils
    dmidecode
    lshw
    
    # Network tools
    iproute2
    iputils
    
    # Text editors
    nano
    vim
    
    # System utilities
    htop
    tree
    file
  ];

  # Network configuration for installer
  networking.networkmanager.enable = lib.mkForce true;
  networking.wireless.enable = lib.mkForce false;

  # Enable DHCP for netboot
  networking.useDHCP = lib.mkForce true;

  # Disable unneeded services for netboot (only disable services that exist in minimal)
  services.avahi.enable = lib.mkForce false;
  services.printing.enable = lib.mkForce false;
  services.keybase.enable = lib.mkForce false;
  services.kbfs.enable = lib.mkForce false;

  # Minimal user for installation
  users.users.installer = {
    isNormalUser = true;
    description = "NixOS Installer User";
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
  };

  # Allow wheel group to sudo without password for installation
  security.sudo.wheelNeedsPassword = false;

  # Auto-login root user to console
  services.getty.autologinUser = lib.mkForce "root";

  # Welcome message with instructions
  environment.etc."issue".text = ''
    
    Framework Desktop (argo) NixOS Netboot Installer
    ==============================================
    
    This system is running from network boot.
    
    SSH access:
    - Root user: ssh root@this-ip
    - Installer user: ssh installer@this-ip
    
    To install NixOS:
    1. SSH into this system
    2. Run hardware scan: nixos-generate-config --show-hardware-config
    3. Update your nixfiles repo with the hardware config
    4. Install: nixos-install --flake /path/to/nixfiles#argo
    
    Network interfaces:
  '';

  # Show IP addresses on boot
  systemd.services.show-ip = {
    description = "Show IP addresses";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      echo "Network interfaces:" >> /etc/issue.d/ip
      ${pkgs.iproute2}/bin/ip addr show | grep "inet " | grep -v "127.0.0.1" >> /etc/issue.d/ip
      echo "" >> /etc/issue.d/ip
      cat /etc/issue.d/ip
    '';
  };

  # NixOS state version
  system.stateVersion = "23.11";
}