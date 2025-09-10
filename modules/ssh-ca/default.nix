# SSH Certificate Authority integration for SmallStep CA
{ config, pkgs, lib, ... }:

{
  # Trust the SSH CA for user certificates
  services.openssh = {
    extraConfig = ''
      # Trust certificates signed by our SSH CA
      TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub
      
      # Optional: Enable SSH CA for host certificates too
      # HostCertificate /etc/ssh/ssh_host_key-cert.pub
      
      # Allow certificate-based authentication
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
    '';
  };

  # Deploy SSH CA public key
  environment.etc."ssh/ssh_user_ca.pub" = {
    text = ''
      # SmallStep SSH CA public key
      # Generated: 2025-09-10T12:09:19-05:00
      # CA URL: https://smallstep-ca.local.zila.dev:9000
# SSH CA key will be available after first certificate generation
    '';
    mode = "0644";
  };

  # Install step CLI for certificate management
  environment.systemPackages = with pkgs; [
    step-cli
  ];

  # Optional: Configure step CLI globally
  environment.etc."step/config/defaults.json" = {
    text = builtins.toJSON {
      ca-url = "https://smallstep-ca.local.zila.dev:9000";
      fingerprint = "null";
      root = "/etc/step/certs/root_ca.crt";
    };
    mode = "0644";
  };

  # Deploy root CA certificate
  environment.etc."step/certs/root_ca.crt" = {
    text = ''-----BEGIN CERTIFICATE-----
MIIB6jCCAZGgAwIBAgIQAkP4wFIfd1fF48YE9tLpODAKBggqhkjOPQQDAjBUMSQw
IgYDVQQKExtzbWFsbHN0ZXAtY2EubG9jYWwuemlsYS5kZXYxLDAqBgNVBAMTI3Nt
YWxsc3RlcC1jYS5sb2NhbC56aWxhLmRldiBSb290IENBMB4XDTI1MDkxMDE2MjEy
N1oXDTM1MDkwODE2MjEyN1owVDEkMCIGA1UEChMbc21hbGxzdGVwLWNhLmxvY2Fs
LnppbGEuZGV2MSwwKgYDVQQDEyNzbWFsbHN0ZXAtY2EubG9jYWwuemlsYS5kZXYg
Um9vdCBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPh68zioENDq6+Y6ZfcM
cF6aqt1UjRhyORvCNiXGvpJC1aoBmelMDvjSEUZy+jcZt5jz8s1bRQaYJYbDQPSb
pzajRTBDMA4GA1UdDwEB/wQEAwIBBjASBgNVHRMBAf8ECDAGAQH/AgEBMB0GA1Ud
DgQWBBSQ2DxE6dduDFsQ1BhrZkTWzqUvUjAKBggqhkjOPQQDAgNHADBEAiAn7C8R
MocY9cbz26mLVw3UIelvVhGdj9U8Jps78tAR0AIgMrGZIo+YledWps08qbR1zJig
hAMIIoFjWY8xhdGr3GI=
-----END CERTIFICATE-----'';
    mode = "0644";
  };
}
