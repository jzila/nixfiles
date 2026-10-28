# shellcheck shell=bash disable=SC2016,SC2034,SC2154 # stub bodies expand when they run; A, B, C and $name belong to the tests
# Shared by the deploy tests (test-*.sh, one per script): a scratch directory
# $T with the stubs in $T/bin, the stubs more than one script calls, and the
# assertions. A case sets $name, starts from `fresh`, runs its script (`script`
# sets $out and $rc) and checks the outcome; a file ends with `summary`.
set -euo pipefail
deploy=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export T

A=$(printf 'a%.0s' {1..40}) # deployed
B=$(printf 'b%.0s' {1..40}) # main
C=$(printf 'c%.0s' {1..40}) # main, later

# stub NAME BODY: a bash script in $T/bin.
stub() { printf '#!%s\n%s\n' "$(command -v bash)" "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }

# fresh: a new case; everything but the stubs goes. Stubs log to $T/calls.
fresh() {
  find "$T" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
  touch "$T/calls"
}

# script NAME [VAR=value...]: runs $deploy/NAME as writeShellApplication would,
# stubs first on PATH. Sets $out (stdout and stderr) and $rc.
script() {
  local s=$1
  shift
  rc=0
  out=$(env PATH="$T/bin:$PATH" "$@" bash -o errexit -o nounset -o pipefail "$deploy/$s" 2>&1) || rc=$?
}

# curl: github.com reachability, Hermes's endpoints, or the API
# (-o FILE -w %{http_code} ... URL; without -o, the body on stdout). Files in
# $T switch things off: offline, ollama-down, webhook-down; the API answers
# with checks.json and compare.json, and checks.status or compare.status.
stub curl '
url=${!#} out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
case $url in
  https://github.com) [ -e "$T/offline" ] && exit 6; exit 0 ;;
  */api/version) [ -e "$T/ollama-down" ] && exit 7; exit 0 ;;
  http://127.0.0.1:8644/) [ -e "$T/webhook-down" ] && { printf 000; exit 7; }; printf 404; exit 0 ;;
  */check-runs*) echo "api checks" >>"$T/calls"; f=checks ;;
  */compare/*) echo "api compare" >>"$T/calls"; f=compare ;;
esac
if [ -z "$out" ]; then cat "$T/$f.json"; exit 0; fi
cp "$T/$f.json" "$out"; printf %s "$(cat "$T/$f.status" 2>/dev/null || echo 200)"'

# systemctl: units listed in $T/inactive are down, in $T/failed failed, in
# $T/condfail skipped by their start condition; MainPID is $T/mainpid.
stub systemctl '
case $1 in
  list-units) cat "$T/failed" 2>/dev/null || true ;;
  show)
    u=${!#}
    case $3 in
      MainPID) cat "$T/mainpid" ;;
      ConditionResult) if grep -qx "$u" "$T/condfail" 2>/dev/null; then echo no; else echo yes; fi ;;
      *) echo loaded ;;
    esac ;;
  restart) echo "systemctl $*" >>"$T/calls" ;;
  is-active) u=${!#}; if grep -qx "$u" "$T/inactive" 2>/dev/null; then echo inactive; exit 3; fi; echo active ;;
esac'

pass=0 failures=0
ok() { pass=$((pass + 1)); }
no() {
  failures=$((failures + 1))
  echo "FAIL [$name]: $*"
  printf '    %s\n' "$out"
}
expect_rc() { if [ "$rc" = "$1" ]; then ok; else no "exit $rc, expected $1"; fi; }
expect_call() { if grep -q -- "$1" "$T/calls"; then ok; else no "no call matching '$1'"; fi; }
expect_no_call() { if ! grep -q -- "$1" "$T/calls"; then ok; else no "unexpected call matching '$1'"; fi; }
expect_out() { if grep -q -- "$1" <<<"$out"; then ok; else no "output lacks '$1'"; fi; }
# expect_in FILE PATTERN
expect_in() { if grep -q -- "$2" "$1" 2>/dev/null; then ok; else no "$1 lacks '$2'"; fi; }
expect_absent() { if [ ! -e "$1" ]; then ok; else no "$1 exists"; fi; }

summary() {
  echo "$(basename "$0"): $pass passed, $failures failed"
  [ "$failures" -eq 0 ]
}
