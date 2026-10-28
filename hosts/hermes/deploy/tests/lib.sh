# shellcheck shell=bash disable=SC2016,SC2034,SC2154 # stub bodies expand when they run; the tests use A, B, C, $name
# Shared by the deploy tests (test-*.sh, one per script): a scratch directory
# $T with stubs in $T/bin (logging to $T/calls), the stubs several scripts
# call, and the assertions. A case sets $name and starts from `fresh`.
set -euo pipefail
deploy=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export T
A=$(printf 'a%.0s' {1..40}) # deployed
B=$(printf 'b%.0s' {1..40}) # main
C=$(printf 'c%.0s' {1..40}) # main, later

stub() { printf '#!%s\n%s\n' "$(command -v bash)" "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
fresh() { find "$T" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +; touch "$T/calls"; }
# script NAME [ARG...]: $deploy/NAME as writeShellApplication runs it, stubs
# first on PATH, and the caller's VAR=value prefixes; sets $out and $rc.
script() { rc=0; out=$(PATH="$T/bin:$PATH" bash -o errexit -o nounset -o pipefail "$deploy/$1" "${@:2}" 2>&1) || rc=$?; }

# curl: github.com, Hermes's endpoints, or the API (-o FILE -w %{http_code}
# ... URL; without -o, the body on stdout). $T/offline, ollama-down and
# webhook-down switch those off; the API answers with checks.json and
# compare.json, and checks.status or compare.status.
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
# expect MESSAGE COMMAND...: passes if COMMAND succeeds, else reports MESSAGE.
expect() {
  if "${@:2}"; then pass=$((pass + 1)); return; fi
  failures=$((failures + 1)); echo "FAIL [$name]: $1"; printf '    %s\n' "$out"
}
expect_rc() { expect "exit $rc, expected $1" [ "$rc" = "$1" ]; }
expect_call() { expect "no call matching '$1'" grep -q -- "$1" "$T/calls"; }
not() { ! "$@"; }
expect_no_call() { expect "unexpected call matching '$1'" not grep -q -- "$1" "$T/calls"; }
expect_out() { expect "output lacks '$1'" grep -q -- "$1" <<<"$out"; }
expect_in() { expect "$1 lacks '$2'" grep -qs -- "$2" "$1"; } # FILE PATTERN
expect_absent() { expect "$1 exists" [ ! -e "$1" ]; }
summary() { echo "$(basename "$0"): $pass passed, $failures failed"; [ "$failures" -eq 0 ]; }
