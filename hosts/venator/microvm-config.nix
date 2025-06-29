# MicroVM configuration for venator host
{ config, lib, pkgs, ... }:

{
  # Enable microVM support with comprehensive features
  services.microvm-dev = {
    enable = true;
    
    # Network configuration
    networkBridge = "virbr-mvm";
    subnet = "192.168.100.0/24";
    
    # Example test VM (disabled by default, set enable = true to use)
    vms.test-vm = {
      enable = false;
      vcpu = 2;
      mem = 1024;
      
      # Enable overlayfs for project isolation
      overlayfs.enable = true;
      
      # Example: mount a project directory
      # projectDir = /home/john/projects/myapp;
      
      # Enable persistent state
      persistState = false;
      stateDiskSize = 2048;
      
      # Port forwarding example
      forwardPorts = [
        { host = 8080; guest = 8080; }
      ];
      
      # Guest configuration
      guestConfig = {
        environment.systemPackages = with pkgs; [
          htop
          neovim
          git
        ];
        
        users.users.developer = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          password = "developer"; # Change this!
        };
      };
    };
    
    # Example Node.js development VM (from examples, disabled by default)
    # vms.nodejs-dev = {
    #   enable = true;
    #   vcpu = 2;
    #   mem = 2048;
    #   projectDir = /home/john/projects/my-node-app;
    #   autoConfigureDevenv = true;
    #   forwardPorts = [
    #     { host = 3000; guest = 3000; }
    #     { host = 5173; guest = 5173; }
    #   ];
    # };
  };
}