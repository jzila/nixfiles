# Job-started hook for a GitHub Actions runner: it only runs the repo's own
# jobs, from main's workflows, against main, for the given events. A failing
# hook fails the job before any step runs. (The runner only accepts hooks
# ending in .sh, .ps1 or .js.)
{ lib, pkgs }:
name: repo: events:
pkgs.writeShellScript "${name}-guard.sh" ''
  fail() { echo "${name} runner: refusing this job: $*" >&2; exit 1; }
  [ "''${GITHUB_REPOSITORY:-}" = ${repo} ] || fail "repository ''${GITHUB_REPOSITORY:-?}"
  [ "''${GITHUB_REF:-}" = refs/heads/main ] || fail "ref ''${GITHUB_REF:-?} is not main"
  case "''${GITHUB_WORKFLOW_REF:-}" in
    ${repo}/.github/workflows/*@refs/heads/main) ;;
    *) fail "workflow ''${GITHUB_WORKFLOW_REF:-?} is not from main" ;;
  esac
  case "''${GITHUB_EVENT_NAME:-}" in
    ${lib.concatStringsSep "|" events}) ;;
    *) fail "event ''${GITHUB_EVENT_NAME:-?}" ;;
  esac
  echo "${name} runner: $GITHUB_WORKFLOW_REF, $GITHUB_EVENT_NAME"
''
