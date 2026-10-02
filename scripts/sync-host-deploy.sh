#!/usr/bin/env bash
#
# Trades — the deliberate, self-proving sync of the host's /srv/trades/deploy directory
# (production-infrastructure-first-deploy BR-26, DE-004; AC-11). Merging trades-infra deploys
# NOTHING; this is the lane that puts the committed deploy files on the host.
#
#   AWS_PROFILE=trades-prod scripts/sync-host-deploy.sh [--dry-run]
#
# From a clean trades-infra `master` equal to `origin/master`, it:
#   1. lists the committed files under deploy/ — EXCLUDING `.env*` (host state: the pinned tags,
#      the basic-auth hash, the bucket), `secrets/` and `rehearsal/`;
#   2. fetches the SHA-256 of every file the host currently holds in that scope, over SSM;
#   3. matches each host file against the blobs of that path in trades-infra's history
#      (`master`): a host file that exists and matches NO commit STOPS the sync, naming it — a
#      hand edit on the host is detected rather than silently clobbered (KHA's host copy ran
#      three months stale). A file ABSENT on the host (every file on the first sync) is simply
#      copied. A host file no commit ever tracked (an extra script) stops the sync too;
#   4. copies a timestamped `/srv/trades/deploy.bak-<ts>` of the directory;
#   5. transfers each file as base64 chunks inside `send-command` (one SSM parameter is bounded,
#      so a file travels in ≤16 KB pieces appended on the host, then decoded), `chmod +x` on
#      `*.sh`, owner `deploy`;
#   6. fetches every host file's SHA-256 again, prints the comparison against the source commit
#      and FAILS on any mismatch; writes `/srv/trades/deploy/.synced-commit` = the commit.
#
# What it never touches: deploy/.env, secrets/, the lock, the backups, the log archive. What it
# does not do: restart anything — a Caddyfile change is `docker compose restart caddy`, a compose
# change to Caddy is `docker compose up -d caddy` (BR-26a, RUNBOOK.md § "The two Caddy lanes").
#
# Env: AWS_PROFILE (trades-prod), AWS_REGION (eu-south-2), SSM_TIMEOUT_SECONDS (300).
# Never run from an agent session (IA-004; the agent role is denied ssm:SendCommand).

set -euo pipefail

DRY_RUN=0
case "${1:-}" in --dry-run) DRY_RUN=1 ;; '') ;; *) echo "usage: scripts/sync-host-deploy.sh [--dry-run]" >&2; exit 2 ;; esac

export AWS_PROFILE="${AWS_PROFILE:-trades-prod}"
export AWS_REGION="${AWS_REGION:-eu-south-2}"
export AWS_PAGER=""
PROJECT="trades"
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST_DIR="/srv/${PROJECT}/deploy"
SSM_TIMEOUT_SECONDS="${SSM_TIMEOUT_SECONDS:-300}"
CHUNK_BYTES=16000

log()  { printf '→ sync: %s\n' "$*"; }
die()  { printf '✗ sync: %s\n' "$*" >&2; exit 1; }

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
sha256_stdin() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

# --- preconditions ---------------------------------------------------------------------------
for tool in git aws base64; do command -v "$tool" >/dev/null 2>&1 || die "$tool not found"; done
cd "$INFRA_DIR"
[ -z "$(git status --porcelain)" ] || die "trades-infra has uncommitted or untracked changes — sync from a clean master"
git fetch --quiet origin master || die "could not fetch origin/master"
[ "$(git rev-parse HEAD)" = "$(git rev-parse master)" ] || die "HEAD is not master — check out master first"
[ "$(git rev-parse master)" = "$(git rev-parse origin/master)" ] || die "local master differs from origin/master — pull or push first"
COMMIT="$(git rev-parse HEAD)"

aws sts get-caller-identity --query Account --output text >/dev/null 2>&1 || die "no AWS session — run \`aws sso login --profile $AWS_PROFILE\`"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
case "$CALLER_ARN" in *"/${PROJECT}-production-operator/"*) ;; *) die "the session is not ${PROJECT}-production-operator ($CALLER_ARN) — use AWS_PROFILE=trades-prod" ;; esac
INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:project,Values=${PROJECT}" "Name=tag:environment,Values=production" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)"
[ -n "$INSTANCE_ID" ] || die "no running instance tagged project=${PROJECT} environment=production"
[ "$(printf '%s\n' "$INSTANCE_ID" | wc -l | tr -d ' ')" = 1 ] || die "more than one running instance tagged project=${PROJECT}: $INSTANCE_ID"
log "commit $COMMIT → host $INSTANCE_ID:$HOST_DIR"

# --- SSM helper: run a command, wait, print stdout, fail on a non-Success status ---------------
ssm_run() {   # ssm_run <comment> <command…>  → stdout of the remote command
  comment="$1"; shift
  cmd="$*"
  cmd_id="$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
    --comment "$comment" --timeout-seconds "$SSM_TIMEOUT_SECONDS" \
    --parameters "commands=[\"${cmd//\"/\\\"}\"],executionTimeout=[\"${SSM_TIMEOUT_SECONDS}\"]" \
    --query 'Command.CommandId' --output text)" || die "send-command failed ($comment)"
  status="Pending"
  deadline=$(( $(date +%s) + SSM_TIMEOUT_SECONDS + 60 ))
  while [ "$status" = Pending ] || [ "$status" = InProgress ] || [ "$status" = Delayed ]; do
    sleep 3
    status="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
    [ "$(date +%s)" -lt "$deadline" ] || die "SSM command $cmd_id ($comment) did not finish"
  done
  out="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text 2>/dev/null || true)"
  if [ "$status" != Success ]; then
    err="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" --query StandardErrorContent --output text 2>/dev/null || true)"
    die "remote step '$comment' ended with $status: ${err:-$out}"
  fi
  printf '%s' "$out"
}

# --- 1. the file list (committed, in scope) ----------------------------------------------------
FILES="$(git ls-files deploy/ | grep -vE '^deploy/\.env|^deploy/secrets/|^deploy/rehearsal/' || true)"
[ -n "$FILES" ] || die "no committed files under deploy/ in scope"
log "$(printf '%s\n' "$FILES" | wc -l | tr -d ' ') file(s) in scope"

# --- 2. the host's current hashes (same scope, plus anything extra it holds) ---------------------
# shellcheck disable=SC2016  # the find/sha256sum pipeline runs ON THE HOST
host_hashes="$(ssm_run "sync: hash host deploy files" \
  'cd '"$HOST_DIR"' 2>/dev/null || exit 0; find . -type f ! -name ".env*" ! -name ".synced-commit" ! -path "./secrets/*" ! -path "./rehearsal/*" ! -path "./.bak-*" -exec sha256sum {} + 2>/dev/null | sed "s#  \./#  #"')"
host_count="$(printf '%s\n' "$host_hashes" | grep -c '^[0-9a-f]\{64\}  ' || true)"
log "host holds $host_count file(s) in scope"

# --- 3. every host file must match SOME commit of its path (AC-11) ------------------------------
blob_matches_history() {   # blob_matches_history <path> <sha256> → 0 when a commit holds that content
  for blob in $(git log --format=%H master -- "$1" | while read -r c; do git rev-parse --quiet --verify "$c:$1" 2>/dev/null || true; done | sort -u); do
    [ "$(git cat-file -p "$blob" | sha256_stdin)" = "$2" ] && return 0
  done
  return 1
}
unknown=""
while read -r hash path; do
  [ -n "${path:-}" ] || continue
  rel="deploy/$path"
  if blob_matches_history "$rel" "$hash"; then
    continue
  fi
  unknown="$unknown\n  $path (sha256 ${hash:0:12}…)"
done <<< "$host_hashes"
if [ -n "$unknown" ]; then
  printf '✗ sync: STOPPED — host file(s) matching NO commit of trades-infra (a hand edit, or a file never committed):%b\n' "$unknown" >&2
  printf '  commit the edit to trades-infra or discard it on the host (/srv/%s/deploy), then re-run (AC-11).\n' "$PROJECT" >&2
  exit 1
fi
log "every host file matches a committed version — safe to overwrite"

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: would sync $(printf '%s\n' "$FILES" | wc -l | tr -d ' ') file(s) from $COMMIT; stopping here"
  exit 0
fi

# --- 4. the backup copy -----------------------------------------------------------------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ssm_run "sync: backup copy" "mkdir -p $HOST_DIR && cp -a $HOST_DIR /srv/${PROJECT}/deploy.bak-${TS} && chown -R deploy:deploy /srv/${PROJECT}/deploy.bak-${TS}" >/dev/null
log "host copy kept at /srv/${PROJECT}/deploy.bak-${TS}"

# --- 5. transfer, file by file, in base64 chunks ------------------------------------------------
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  path="${rel#deploy/}"
  dir="$(dirname "$path")"
  tmp="${HOST_DIR}/${path}.sync-tmp"
  b64="$(base64 < "$rel" | tr -d '\n')"
  total=${#b64}; offset=0; part=0
  ssm_run "sync: begin $path" "mkdir -p '$HOST_DIR/$dir' && : > '$tmp'" >/dev/null
  while [ "$offset" -lt "$total" ]; do
    chunk="${b64:$offset:$CHUNK_BYTES}"
    ssm_run "sync: $path part $part" "printf '%s' '$chunk' >> '$tmp'" >/dev/null
    offset=$((offset + CHUNK_BYTES)); part=$((part + 1))
  done
  mode="644"; case "$path" in *.sh) mode="755" ;; esac
  ssm_run "sync: finish $path" "base64 -d '$tmp' > '$HOST_DIR/$path' && rm -f '$tmp' && chmod $mode '$HOST_DIR/$path' && chown deploy:deploy '$HOST_DIR/$path'" >/dev/null
  log "synced $path ($total base64 chars, $part chunk(s), mode $mode)"
done <<< "$FILES"

# --- 6. prove it: every host file's hash equals the source commit's --------------------------------
# shellcheck disable=SC2016
after="$(ssm_run "sync: verify" 'cd '"$HOST_DIR"' && find . -type f ! -name ".env*" ! -name ".synced-commit" ! -path "./secrets/*" ! -path "./rehearsal/*" ! -path "./.bak-*" -exec sha256sum {} + | sed "s#  \./#  #"')"
mismatch=0
printf '%-10s  %-64s  %s\n' "verdict" "sha256 (host)" "path"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  path="${rel#deploy/}"
  want="$(git show "$COMMIT:$rel" | sha256_stdin)"
  have="$(printf '%s\n' "$after" | awk -v p="$path" '$2 == p {print $1}' | head -1)"
  if [ "$want" = "$have" ]; then printf '%-10s  %s  %s\n' "ok" "$have" "$path"; else printf '%-10s  %s  %s (want %s)\n' "MISMATCH" "${have:-<absent>}" "$path" "$want"; mismatch=$((mismatch + 1)); fi
done <<< "$FILES"
[ "$mismatch" = 0 ] || die "$mismatch file(s) on the host do not match commit $COMMIT — the sync is NOT complete; the previous copy is at /srv/${PROJECT}/deploy.bak-${TS}"
ssm_run "sync: record commit" "printf '%s\n' '$COMMIT' > '$HOST_DIR/.synced-commit' && chown deploy:deploy '$HOST_DIR/.synced-commit'" >/dev/null
echo "✓ sync: $HOST_DIR equals commit $COMMIT (recorded in .synced-commit); deploy/.env and secrets/ untouched"
echo "  Next: a Caddyfile change → \`docker compose restart caddy\`; a compose change to caddy → \`docker compose up -d caddy\` (BR-26a); a deployable → scripts/promote.sh"
