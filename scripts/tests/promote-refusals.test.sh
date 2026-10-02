#!/usr/bin/env bash
#
# promote.sh refusals — production-infrastructure-first-deploy AC-8 / TM-7 (Tester scope).
#
# Drives the REAL scripts/promote.sh against a scratch workspace (a throwaway `trades-backend`
# clone of a throwaway bare origin) with stub `aws`, `docker` and `make` executables first on
# PATH, so nothing reaches AWS, a registry or a real build. For each precondition it asserts:
#   - exit status 1 (never 0 — the iteration-2 trap fix);
#   - the printed refusal names the precondition: `REFUSED (<name>)`;
#   - no `docker build` / `docker buildx` / `docker push` was invoked (refused BEFORE any build).
#
# Cases: a short SHA, a dirty tree, a local master behind origin/master, a SHA not on master,
# and a red `make quality` (the last one needs the stubbed operator session to get that far).
#
# Usage: scripts/tests/promote-refusals.test.sh        (from anywhere; bash 3.2-safe)
# Exit:  0 — every case refused as asserted · 1 — at least one case did not

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROMOTE="$INFRA_DIR/scripts/promote.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/promote-refusals-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STUBS="$WORK/stubs"
CALLS="$WORK/calls.log"
mkdir -p "$STUBS"
: > "$CALLS"

# --- stubs: record every call; answer only what the preconditions ask -------------------
cat > "$STUBS/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$STUB_CALLS"
case "$*" in
  *"sts get-caller-identity"*"--query Account"*) echo "123456789012" ;;
  *"sts get-caller-identity"*"--query Arn"*) echo "arn:aws:sts::123456789012:assumed-role/trades-production-operator/tester-session" ;;
  *"ec2 describe-instances"*) echo "i-0123456789abcdef0" ;;
  *"ecr describe-images"*) echo "None" ;;
  *"s3 cp"*) cat > /dev/null ;;
  *) ;;
esac
exit 0
EOF
cat > "$STUBS/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_CALLS"
exit 0
EOF
cat > "$STUBS/make" <<'EOF'
#!/usr/bin/env bash
echo "make $*" >> "$STUB_CALLS"
[ "${STUB_MAKE_RED:-0}" = 1 ] && { echo "stub make: quality is RED" >&2; exit 2; }
exit 0
EOF
chmod +x "$STUBS/aws" "$STUBS/docker" "$STUBS/make"
export STUB_CALLS="$CALLS"

# --- the scratch workspace: bare origin + a clone named like the deployable's repo -------
git_q() { git -c user.email=tester@example.invalid -c user.name=tester -c init.defaultBranch=master -c commit.gpgsign=false "$@"; }
fresh_workspace() {
  rm -rf "$WORK/ws" "$WORK/origin.git" "$WORK/other"
  mkdir -p "$WORK/ws"
  git_q init -q --bare "$WORK/origin.git"
  git_q clone -q "$WORK/origin.git" "$WORK/ws/trades-backend" 2>/dev/null
  ( cd "$WORK/ws/trades-backend" && echo one > a.txt && git_q add a.txt && git_q commit -qm one && git_q push -q origin master )
}
head_sha() { git -C "$WORK/ws/trades-backend" rev-parse HEAD; }

failures=0
run_case() {   # run_case <name> <expected precondition> <sha>   (env set by the caller)
  name="$1"; expected="$2"; sha="$3"
  : > "$CALLS"
  set +e
  out="$(PATH="$STUBS:$PATH" WORKSPACE="$WORK/ws" AWS_PROFILE=trades-prod "$PROMOTE" app "$sha" 2>&1)"
  rc=$?
  set -e
  ok=1
  [ "$rc" -eq 1 ] || { echo "  ✗ $name: exit $rc (expected 1)"; ok=0; }
  printf '%s' "$out" | grep -qF "REFUSED ($expected)" || { echo "  ✗ $name: output does not name '$expected': $out"; ok=0; }
  if grep -qE '^docker (build|buildx|push)' "$CALLS"; then echo "  ✗ $name: a build/push was invoked: $(grep -E '^docker (build|buildx|push)' "$CALLS")"; ok=0; fi
  if [ "$ok" = 1 ]; then
    echo "  ✓ $name → exit 1, $(printf '%s' "$out" | grep -F 'REFUSED' | head -1 | sed 's/^✗ promote: //')"
  else
    failures=$((failures + 1))
  fi
}

echo "promote.sh refusals on a scratch clone (AC-8, TM-7):"

fresh_workspace
run_case "short SHA" "sha-format" "$(head_sha | cut -c1-12)"
run_case "upper-case SHA" "sha-format" "$(head_sha | tr 'a-f' 'A-F')"

fresh_workspace
echo dirty >> "$WORK/ws/trades-backend/a.txt"
run_case "dirty tree (modified file)" "dirty-tree" "$(head_sha)"
fresh_workspace
echo new > "$WORK/ws/trades-backend/untracked.txt"
run_case "dirty tree (untracked file)" "dirty-tree" "$(head_sha)"

fresh_workspace
git_q clone -q "$WORK/origin.git" "$WORK/other" 2>/dev/null
( cd "$WORK/other" && echo two > b.txt && git_q add b.txt && git_q commit -qm two && git_q push -q origin master )
run_case "master behind origin/master" "master-drift" "$(head_sha)"

fresh_workspace
( cd "$WORK/ws/trades-backend" && git_q checkout -qb side && echo side > s.txt && git_q add s.txt && git_q commit -qm side )
side_sha="$(head_sha)"
git -C "$WORK/ws/trades-backend" checkout -q master
run_case "SHA not on master" "sha-not-on-master" "$side_sha"

fresh_workspace
STUB_MAKE_RED=1 run_case "red make quality" "quality-gate" "$(head_sha)"
grep -q '^make quality' "$CALLS" || { echo "  ✗ red make quality: the full gate was never invoked"; failures=$((failures + 1)); }

if [ "$failures" -gt 0 ]; then
  echo "✗ promote-refusals: $failures case(s) failed"
  exit 1
fi
echo "✓ promote-refusals: every precondition refused before any build, exit 1, naming itself"
