# Unit tests for the webhook scripts, run by `nix flake check` (CI):
#   nix build .#checks.x86_64-linux.hermes-scripts
{ runCommand, python3 }:
runCommand "hermes-scripts-tests" { nativeBuildInputs = [ python3 ]; } ''
  cd ${./.}
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_ha_log
  touch $out
''
