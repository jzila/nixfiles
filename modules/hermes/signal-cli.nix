# signal-cli as a local JSON-RPC daemon, the Signal transport for Hermes
# Agent's gateway (SIGNAL_HTTP_URL).
#
# The daemon runs in multi-account mode (no --account), serving whatever
# accounts are registered in its state directory, so the bot's phone number
# never appears in this repo. Register and verify through the daemon's
# JSON-RPC (`register` / `verify` methods) once it is running.
#
# It listens on loopback only. The state directory holds the account's
# identity keys: treat it like a password.
{ pkgs, ... }:
let
  stateDir = "/var/lib/signal-cli";
  # Not 8080, the de-facto alternate HTTP port that dev servers and proxies
  # grab by default.
  port = 7583;
in
{
  users.users.signal-cli = {
    isSystemUser = true;
    group = "signal-cli";
    home = stateDir;
  };
  users.groups.signal-cli = { };

  systemd.services.signal-cli = {
    description = "signal-cli JSON-RPC daemon (loopback only)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      User = "signal-cli";
      Group = "signal-cli";
      StateDirectory = "signal-cli";
      StateDirectoryMode = "0700";
      ExecStart = "${pkgs.signal-cli}/bin/signal-cli --config ${stateDir} daemon --http 127.0.0.1:${toString port}";
      Restart = "on-failure";
      RestartSec = 5;

      # Sandboxing. The JVM needs writable+executable memory for its JIT, so
      # MemoryDenyWriteExecute stays off.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
  };
}
