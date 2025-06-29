{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.microvm-dev;
  
  # Generate a deterministic MAC address from VM name
  generateMacAddress = name: let
    hash = builtins.hashString "sha256" name;
    bytes = map (i: substring (i * 2) 2 hash) (range 0 5);
    firstByte = "02";
  in concatStringsSep ":" ([firstByte] ++ (tail bytes));
  
  # Network configuration
  bridgeName = cfg.networkBridge;
  subnet = cfg.subnet;
  
  # Parse subnet to get network info
  subnetParts = splitString "/" subnet;
  networkAddr = elemAt subnetParts 0;
  prefixLength = elemAt subnetParts 1;
  
  # Gateway is first IP in subnet
  gatewayAddr = let
    parts = splitString "." networkAddr;
    lastOctet = toString (toInt (elemAt parts 3) + 1);
  in concatStringsSep "." (init parts ++ [lastOctet]);
  
  # DHCP range (10-254)
  dhcpRangeStart = let
    parts = splitString "." networkAddr;
    lastOctet = toString (toInt (elemAt parts 3) + 10);
  in concatStringsSep "." (init parts ++ [lastOctet]);
  
  dhcpRangeEnd = let
    parts = splitString "." networkAddr;
    lastOctet = toString (toInt (elemAt parts 3) + 254);
  in concatStringsSep "." (init parts ++ [lastOctet]);

in {
  config = mkIf cfg.enable {
    # Bridge network interface
    networking.bridges.${bridgeName} = {
      interfaces = [];  # TAP interfaces added dynamically
    };
    
    # Configure bridge IP
    networking.interfaces.${bridgeName} = {
      ipv4.addresses = [{
        address = gatewayAddr;
        prefixLength = toInt prefixLength;
      }];
    };
    
    # Enable IP forwarding for NAT
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
    
    # NAT for outbound traffic
    networking.nat = {
      enable = true;
      internalInterfaces = [ bridgeName ];
      externalInterface = null;  # Auto-detect
    };
    
    # DHCP and DNS server
    services.dnsmasq = {
      enable = true;
      settings = {
        # Listen only on bridge interface
        interface = bridgeName;
        bind-interfaces = true;
        
        # DHCP configuration
        dhcp-range = "${dhcpRangeStart},${dhcpRangeEnd},12h";
        dhcp-option = [
          "option:router,${gatewayAddr}"
          "option:dns-server,${gatewayAddr}"
        ];
        
        # DNS configuration
        server = [
          "8.8.8.8"
          "8.8.4.4"
          "1.1.1.1"
        ];
        
        # Don't read /etc/hosts
        no-hosts = true;
        
        # Log DHCP transactions
        log-dhcp = true;
        
        # Static DHCP leases for VMs
        dhcp-host = mapAttrsToList (name: vm: 
          "${vm.macAddress or (generateMacAddress name)},${vm.staticIP or ""}"
        ) (filterAttrs (_: vm: vm.enable) cfg.vms);
      };
    };
    
    # Firewall rules for bridge
    networking.firewall = {
      trustedInterfaces = [ bridgeName ];
      
      # Allow DHCP and DNS on bridge
      interfaces.${bridgeName} = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 67 68 ];
      };
    };
    
    # Port forwarding rules
    networking.firewall.extraCommands = let
      forwardRules = concatLists (mapAttrsToList (name: vm:
        map (fwd: ''
          # Port forward ${toString fwd.host} -> ${name}:${toString fwd.guest}
          iptables -t nat -A PREROUTING -p tcp --dport ${toString fwd.host} \
            -j DNAT --to-destination $(cat /var/lib/microvm/${name}/ip 2>/dev/null || echo 192.168.100.99):${toString fwd.guest}
          iptables -A FORWARD -p tcp -d $(cat /var/lib/microvm/${name}/ip 2>/dev/null || echo 192.168.100.99) \
            --dport ${toString fwd.guest} -j ACCEPT
        '') vm.forwardPorts
      ) (filterAttrs (_: vm: vm.enable) cfg.vms));
    in ''
      # Create MICROVM-FORWARD chain
      iptables -t nat -N MICROVM-FORWARD 2>/dev/null || true
      iptables -t nat -F MICROVM-FORWARD
      
      # Add forwarding rules
      ${concatStringsSep "\n" forwardRules}
      
      # Ensure bridge traffic goes through iptables
      sysctl -w net.bridge.bridge-nf-call-iptables=1 || true
      sysctl -w net.bridge.bridge-nf-call-ip6tables=1 || true
    '';
    
    networking.firewall.extraStopCommands = ''
      # Clean up MICROVM-FORWARD chain
      iptables -t nat -F MICROVM-FORWARD 2>/dev/null || true
      iptables -t nat -X MICROVM-FORWARD 2>/dev/null || true
    '';
    
    # Systemd service to setup bridge networking
    systemd.services.microvm-network-setup = {
      description = "Setup MicroVM network bridge";
      wantedBy = [ "network.target" ];
      after = [ "network-pre.target" ];
      before = [ "network.target" "dnsmasq.service" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      
      script = ''
        # Ensure bridge exists
        if ! ip link show ${bridgeName} >/dev/null 2>&1; then
          ip link add ${bridgeName} type bridge
        fi
        
        # Bring up bridge
        ip link set ${bridgeName} up
        
        # Set bridge parameters for better VM compatibility
        echo 0 > /sys/class/net/${bridgeName}/bridge/stp_state || true
        echo 2 > /sys/class/net/${bridgeName}/bridge/forward_delay || true
      '';
      
      preStop = ''
        # Don't delete bridge on stop, let networking.nix handle it
        true
      '';
    };
    
    # Helper service to track VM IPs
    systemd.services."microvm-track-ip@" = {
      description = "Track IP address for microVM %i";
      after = [ "microvm@%i.service" ];
      bindsTo = [ "microvm@%i.service" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5s";
      };
      
      script = ''
        VM_NAME="$1"
        MAC=$(${pkgs.systemd}/bin/systemctl show "microvm@$VM_NAME.service" -p Environment | grep -oP 'MAC_ADDRESS=\K[^ ]+' || true)
        
        while true; do
          # Get IP from dnsmasq lease file
          IP=$(grep -i "$MAC" /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null | awk '{print $3}' || true)
          
          if [ -n "$IP" ]; then
            echo "$IP" > /var/lib/microvm/$VM_NAME/ip
            echo "VM $VM_NAME has IP $IP"
          fi
          
          sleep 10
        done
      '';
    };
  };
  
}