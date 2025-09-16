# SSH Certificate Authority integration for SmallStep CA
{ config, pkgs, lib, ... }:

let
  fetch-ssh-ca-key-script = import ../../modules/fetch-ssh-ca-key { inherit pkgs lib; };
in

with lib; let
  cfg = config.services.ssh-ca;
in {

  options.services.ssh-ca = {
    caUrl = mkOption {
      type = types.str;
      default = "https://smallstep-ca.local.zila.dev:9000";
      description = "SmallStep CA base URL used to fetch SSH roots.";
    };
    resolveToIP = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional IP to map the CA hostname to (added to /etc/hosts) when DNS is unavailable in netboot.";
    };
  };

  config = {
    # Trust the SSH CA for user certificates (use structured settings)
    services.openssh.settings = {
      TrustedUserCAKeys = "/etc/ssh/ssh_user_ca.pub";
      PubkeyAuthentication = true;
      # Still allow per-user authorized_keys if needed
      AuthorizedKeysFile = ".ssh/authorized_keys";
    };

    # Install step CLI for certificate management
    environment.systemPackages = with pkgs; [ step-cli ];

    # Systemd service to fetch SSH CA public key on boot
    systemd.services.fetch-ssh-ca-key = {
      description = "Fetch SSH CA public key from SmallStep CA";
      # Start on boot and ensure it completes before sshd
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${fetch-ssh-ca-key-script}/bin/fetch-ssh-ca-key.sh";
      };
      environment = {
        STEP_CA_URL = cfg.caUrl;
      };
    };

    # Ensure sshd wants the CA-fetch service so ordering is respected
    systemd.services.sshd.wants = [ "fetch-ssh-ca-key.service" ];

    # Optional: Configure step CLI globally
    environment.etc."step/config/defaults.json" = {
      text = builtins.toJSON {
        ca-url = cfg.caUrl;
        fingerprint = "null";
        root = "/etc/step/certs/root_ca.crt";
      };
      mode = "0644";
    };

    # Deploy root CA certificate
    environment.etc."step/certs/root_ca.crt" = {
      text = ''-----BEGIN CERTIFICATE-----
MIIB6jCCAZGgAwIBAgIQSMK81SS0V1svlrNAB2BC5zAKBggqhkjOPQQDAjBUMSQw
IgYDVQQKExtzbWFsbHN0ZXAtY2EubG9jYWwuemlsYS5kZXYxLDAqBgNVBAMTI3Nt
YWxsc3RlcC1jYS5sb2NhbC56aWxhLmRldiBSb290IENBMB4XDTI1MDkxMDE4NDYy
OFoXDTM1MDkwODE4NDYyOFowVDEkMCIGA1UEChMbc21hbGxzdGVwLWNhLmxvY2Fs
LnppbGEuZGV2MSwwKgYDVQQDEyNzbWFsbHN0ZXAtY2EubG9jYWwuemlsYS5kZXYg
Um9vdCBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABN+1AXejhhtL+lazvcd1
09XRNeY3tobavSYwHtQuVCgreAwJQaEAfG3/fvEZZYKTwgYr52QLYHOQApEtBBYG
QpWjRTBDMA4GA1UdDwEB/wQEAwIBBjASBgNVHRMBAf8ECDAGAQH/AgEBMB0GA1Ud
DgQWBBTFBe+qV1d4NUE/HrSSTD2VmU702DAKBggqhkjOPQQDAgNHADBEAiBCioe8
+uQs/E5jrsr5jBQjVF2wxp678HfkzyU9QvgM5wIgHaxC/6T3dk9D6ifL7KtOvIKp
dajqc+JfwiTiy8bSK7o=
-----END CERTIFICATE-----'';
      mode = "0644";
    };

    # If resolveToIP is set, add a hosts mapping for the CA hostname
    networking.hosts = lib.mkIf (cfg.resolveToIP != null) (
      let
        # Extract hostname from URL like https://host:port or https://host
        urlNoScheme = lib.removePrefix "https://" (lib.removePrefix "http://" cfg.caUrl);
        hostWithPort = lib.takeWhile (c: c != "/") urlNoScheme;
        host = lib.takeWhile (c: c != ":") hostWithPort;
      in {
        "${cfg.resolveToIP}" = [ host ];
      }
    );
  };
}
