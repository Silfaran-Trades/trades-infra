#!/usr/bin/env bash
#
# Trades — the manual, scripted promotion from the developer's Mac (ADR-125;
# production-infrastructure-first-deploy BR-24; AC-8, AC-9, AC-10, AC-23; TM-7).
#
#   scripts/promote.sh <app|media|web> <40-hex-sha> [--first-boot-skip-backup-gate]
#
# One command promotes ONE deployable at ONE SHA, under the `trades-prod` profile (BR-4):
#
#   1. PRECONDITIONS — each refuses BEFORE any build, naming itself (AC-8):
#        - a full 40-character lowercase SHA;
#        - the deployable's repository (trades-backend / media-service / trades-front) has a
#          CLEAN tree and its `master` equals `origin/master` after a fetch;
#        - the SHA is on `master`;
#        - an AWS session under the operator role; the host, the registry and the backups
#          bucket resolve from the account (nothing is configured locally).
#   2. LANE — decided from ECR, never from the SHA alone:
#        - NEW IMAGE: the SHA is `origin/master`'s head and ECR holds no image for it → run the
#          repository's FULL `make quality` (never diff-scoped), build linux/arm64 from
#          `git archive <sha>` (a pristine tree — never the working copy), scan the image
#          (HIGH / CRITICAL with a fix available blocks, AS-018), push with a short-lived ECR
#          login. For `app`, COMPOSER_AUTH rides as a BuildKit secret (derived from `gh auth
#          token` when unset — never on disk, never in a layer). For `web`, the committed
#          deploy/production/web.build-args are the build arguments, plus VITE_APP_VERSION=<sha>;
#          an unfilled `@…@` placeholder in that file refuses the build.
#        - ROLLBACK: the SHA is older than head → allowed ONLY when ECR already holds its image
#          (which was gated when first promoted); no build, no gate. An older SHA never promoted
#          is refused (promote head, or a previously promoted SHA).
#        - the SHA is head AND ECR already holds it → the rollback lane (the image was gated).
#   3. DEPLOY — `aws ssm send-command` (AWS-RunShellScript) runs
#      `sudo -u deploy /srv/trades/deploy/deploy.sh <deployable> <sha>` on the host, polled with
#      `get-command-invocation`; its output is printed. `--first-boot-skip-backup-gate` passes
#      `sudo -u deploy env SKIP_BACKUP_GATE=1 …` (plain sudo would drop the variable); deploy.sh
#      still refuses it on a database with users (AC-23) — the one legitimate use is the first
#      `app` promotion on the empty database.
#   4. RECORD — one JSON object `promotions/<UTC stamp>-<deployable>-<sha>.json` in the backups
#      bucket (operator-written; the host cannot forge it, TM-4): deployable, sha, previous_sha,
#      started_at, finished_at, outcome (success | failed | refused), lane (new-image |
#      rollback), backup_gate (ran | skipped-empty-db | not-applicable for web), operator (the
#      assumed role's ARN WITHOUT its session name — no personal data). Written on success AND
#      on failure, and on a refusal once the session exists.
#
# What this lane does NOT give (ADR-125 records it): no provenance / SBOM attestation, arm64
# only, no workflow run history — the promotion record is the durable answer to "what is live".
#
# Env: AWS_PROFILE (trades-prod), AWS_REGION (eu-south-2), WORKSPACE (the directory holding the
# four repos; default: this repo's parent), COMPOSER_AUTH (app builds), SSM_TIMEOUT_SECONDS
# (1800). Never run from an agent session (IA-004; the agent role is denied ssm:SendCommand).

set -euo pipefail

DEPLOYABLE="${1:-}"
SHA="${2:-}"
BYPASS="${3:-}"
usage() { echo "usage: scripts/promote.sh <app|media|web> <40-hex-sha> [--first-boot-skip-backup-gate]" >&2; exit 2; }
[ -n "$DEPLOYABLE" ] && [ -n "$SHA" ] || usage
case "${BYPASS}" in ''|--first-boot-skip-backup-gate) ;; *) usage ;; esac

export AWS_PROFILE="${AWS_PROFILE:-trades-prod}"
export AWS_REGION="${AWS_REGION:-eu-south-2}"
export AWS_PAGER=""
PROJECT="trades"
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$INFRA_DIR/.." && pwd)}"
SSM_TIMEOUT_SECONDS="${SSM_TIMEOUT_SECONDS:-1800}"
STARTED_AT="$(date -u +%FT%TZ)"

log()  { printf '→ promote: %s\n' "$*"; }
warn() { printf '⚠ promote: %s\n' "$*" >&2; }

# --- the record (step 4) — written on every exit once the session is known -------------
OUTCOME="refused"; LANE=""; PREVIOUS_SHA=""; BACKUP_GATE=""; OPERATOR=""; BACKUPS_BUCKET=""; REFUSAL=""
record_written=0
write_record() {
  [ "$record_written" = 0 ] || return 0
  [ -n "$BACKUPS_BUCKET" ] && [ -n "$OPERATOR" ] || return 0   # no session yet: nothing durable to write to
  record_written=1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  key="promotions/${stamp}-${DEPLOYABLE}-${SHA}.json"
  body="$(printf '{"deployable":"%s","sha":"%s","previous_sha":"%s","started_at":"%s","finished_at":"%s","outcome":"%s","lane":"%s","backup_gate":"%s","operator":"%s","refusal":"%s"}\n' \
    "$DEPLOYABLE" "$SHA" "${PREVIOUS_SHA:-}" "$STARTED_AT" "$(date -u +%FT%TZ)" "$OUTCOME" "${LANE:-}" "${BACKUP_GATE:-}" "$OPERATOR" "${REFUSAL:-}")"
  if printf '%s' "$body" | aws s3 cp --only-show-errors - "s3://${BACKUPS_BUCKET}/${key}" 2>/dev/null; then
    log "promotion record written: s3://${BACKUPS_BUCKET}/${key} (outcome=$OUTCOME)"
  else
    warn "could NOT write the promotion record to s3://${BACKUPS_BUCKET}/${key} — record it by hand: $body"
  fi
}
refuse() {   # refuse <precondition name> <message>
  OUTCOME="refused"; REFUSAL="$1"
  printf '✗ promote: REFUSED (%s) — %s\n' "$1" "$2" >&2
  write_record
  exit 1
}
BUILD_DIR=""   # the pristine archive of the new-image lane (2b); removed by on_exit
on_exit() {
  rc=$?   # the FIRST statement: the status of the `exit` that fired the trap, before anything resets $?
  if [ "$rc" -ne 0 ] && [ "$OUTCOME" != "refused" ]; then OUTCOME="failed"; fi
  write_record
  docker logout "${REGISTRY:-}" >/dev/null 2>&1 || true
  [ -z "$BUILD_DIR" ] || rm -rf "$BUILD_DIR"
  exit "$rc"
}
# ONE exit trap for the whole run — never re-armed with a compound body such as
# `trap 'rm -rf "$BUILD_DIR"; on_exit' EXIT`: the first command of that body resets $? to 0
# before on_exit reads it, so every refusal and failure after the re-arm exits 0 and tells the
# caller the promotion succeeded (observed in review; reproduced with a four-line script).
# Clean-up that must happen at exit goes INSIDE on_exit, after `rc=$?`.
trap on_exit EXIT

# --- 1. preconditions ------------------------------------------------------------------
case "$DEPLOYABLE" in
  app)   REPO="trades-backend"; IMAGE_NAME="trades-backend" ;;
  media) REPO="media-service";  IMAGE_NAME="media-service" ;;
  web)   REPO="trades-front";   IMAGE_NAME="trades-front" ;;
  *)     refuse "deployable" "'$DEPLOYABLE' is not one of app | media | web" ;;
esac
printf '%s' "$SHA" | grep -qE '^[0-9a-f]{40}$' || refuse "sha-format" "'$SHA' is not a full 40-character lowercase git SHA (never a short SHA, never a tag)"
[ -z "$BYPASS" ] || [ "$DEPLOYABLE" = app ] || refuse "bypass-scope" "--first-boot-skip-backup-gate applies to the first \`app\` promotion only"

for tool in git docker aws; do command -v "$tool" >/dev/null 2>&1 || refuse "tooling" "$tool not found"; done
docker info >/dev/null 2>&1 || refuse "tooling" "the Docker daemon is not reachable"

REPO_DIR="$WORKSPACE/$REPO"
[ -d "$REPO_DIR/.git" ] || refuse "repository" "$REPO_DIR is not a git checkout (set WORKSPACE)"
[ -z "$(git -C "$REPO_DIR" status --porcelain)" ] || refuse "dirty-tree" "$REPO has uncommitted or untracked changes — the promoted artifact must come from a clean, committed tree"
git -C "$REPO_DIR" fetch --quiet origin master || refuse "fetch" "could not fetch origin/master in $REPO"
LOCAL_MASTER="$(git -C "$REPO_DIR" rev-parse master)"
ORIGIN_MASTER="$(git -C "$REPO_DIR" rev-parse origin/master)"
[ "$LOCAL_MASTER" = "$ORIGIN_MASTER" ] || refuse "master-drift" "$REPO: local master ($LOCAL_MASTER) differs from origin/master ($ORIGIN_MASTER) — pull or push first"
git -C "$REPO_DIR" cat-file -e "${SHA}^{commit}" 2>/dev/null || refuse "sha-unknown" "$SHA is not a commit in $REPO"
git -C "$REPO_DIR" merge-base --is-ancestor "$SHA" master || refuse "sha-not-on-master" "$SHA is not on $REPO's master — only master commits are promoted"

# The session: the operator role, never a static key (SC-012, TM-10).
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || refuse "aws-session" "no AWS session — run \`aws sso login --profile $AWS_PROFILE\`"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
case "$CALLER_ARN" in
  arn:*:sts::*:assumed-role/${PROJECT}-production-operator/*) OPERATOR="${CALLER_ARN%/*}" ;;   # the session name dropped (no personal data)
  *) refuse "aws-session" "the session is not ${PROJECT}-production-operator ($CALLER_ARN) — use AWS_PROFILE=trades-prod (BR-4)" ;;
esac
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKUPS_BUCKET="${PROJECT}-production-backups-${ACCOUNT_ID}"
INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:project,Values=${PROJECT}" "Name=tag:environment,Values=production" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)"
[ -n "$INSTANCE_ID" ] || refuse "host" "no running instance tagged project=${PROJECT} environment=production — has the apply happened?"
[ "$(printf '%s\n' "$INSTANCE_ID" | wc -l | tr -d ' ')" = 1 ] || refuse "host" "more than one running instance tagged project=${PROJECT}: $INSTANCE_ID"
IMAGE_REPO="${PROJECT}/${IMAGE_NAME}"
IMAGE="${REGISTRY}/${IMAGE_REPO}:${SHA}"
log "$DEPLOYABLE $SHA → host $INSTANCE_ID, registry $REGISTRY (operator $OPERATOR)"

# --- 2. the lane --------------------------------------------------------------------------
in_ecr="$(aws ecr describe-images --repository-name "$IMAGE_REPO" --image-ids "imageTag=$SHA" \
  --query 'imageDetails[0].imageDigest' --output text 2>/dev/null | grep -v '^None$' || true)"
if [ -n "$in_ecr" ]; then
  LANE="rollback"
  log "lane: ROLLBACK — ECR already holds $IMAGE_REPO:$SHA ($in_ecr); no build, no gate (gated when first promoted)"
elif [ "$SHA" = "$ORIGIN_MASTER" ]; then
  LANE="new-image"
  log "lane: NEW IMAGE — $SHA is origin/master's head and ECR holds no image for it"
else
  refuse "rollback-target" "$SHA is older than master's head and ECR holds no image for it — promote head, or a SHA that was promoted before"
fi

if [ "$LANE" = "new-image" ]; then
  # 2a. the repository's FULL quality gate — never scoped to the diff (BR-24, TM-7)
  log "running the full \`make quality\` in $REPO (the verification of record while Actions is off)"
  ( cd "$REPO_DIR" && make quality ) || refuse "quality-gate" "$REPO's \`make quality\` is red — nothing is built from a red gate"

  # 2b. a pristine tree of the commit — never the working copy
  BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/promote-${DEPLOYABLE}-XXXXXX")"   # removed by on_exit (the one EXIT trap)
  git -C "$REPO_DIR" archive --format=tar "$SHA" | tar -x -C "$BUILD_DIR"
  log "archived $SHA into $BUILD_DIR"

  build_args=()
  secret_args=()
  case "$DEPLOYABLE" in
    app)
      if [ -z "${COMPOSER_AUTH:-}" ]; then
        command -v gh >/dev/null 2>&1 || refuse "composer-auth" "COMPOSER_AUTH is unset and gh is not available to derive it (the private llm-gateway package needs a read-only GitHub token)"
        # shellcheck disable=SC2089,SC2090
        COMPOSER_AUTH='{"github-oauth":{"github.com":"'"$(gh auth token)"'"}}'
        # shellcheck disable=SC2090
        export COMPOSER_AUTH
      fi
      # shellcheck disable=SC2054  # one docker argument: the comma separates the secret's key=value pairs
      secret_args=(--secret id=composer_auth,env=COMPOSER_AUTH)
      ;;
    web)
      ARGS_FILE="$INFRA_DIR/deploy/production/web.build-args"
      [ -f "$ARGS_FILE" ] || refuse "web-build-args" "$ARGS_FILE missing"
      if grep -qE '@[A-Z_]+@' "$ARGS_FILE"; then
        refuse "web-build-args" "$ARGS_FILE still carries an unfilled placeholder ($(grep -oE '@[A-Z_]+@' "$ARGS_FILE" | sort -u | paste -sd, -)) — fill it from the apply outputs and the Google console check (Phase 7 step 6) and commit it first"
      fi
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        build_args+=(--build-arg "$line")
      done < "$ARGS_FILE"
      build_args+=(--build-arg "VITE_APP_VERSION=$SHA")
      ;;
  esac

  # 2c. build linux/arm64 (the host's architecture; the Mac builds it natively)
  log "building $IMAGE (linux/arm64, target runtime)"
  docker build --platform linux/arm64 --target runtime -t "$IMAGE" \
    ${build_args[@]+"${build_args[@]}"} ${secret_args[@]+"${secret_args[@]}"} "$BUILD_DIR" \
    || refuse "build" "docker build failed for $IMAGE"

  # 2d. scan — the repository's own Trivy gate (HIGH / CRITICAL with a fix available blocks,
  # AS-018; it carries the vendor-Dockerfile skip the 10.4 rehearsal learned)
  log "scanning $IMAGE (make container-scan in $REPO)"
  ( cd "$REPO_DIR" && make container-scan IMAGE="$IMAGE" ) || refuse "image-scan" "HIGH / CRITICAL finding(s) with a fix available in $IMAGE (AS-018) — bump and rebuild"

  # 2e. push with a short-lived login (the registry is IMMUTABLE — AC-10)
  aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null || refuse "ecr-login" "ECR login failed"
  log "pushing $IMAGE"
  docker push "$IMAGE" >/dev/null || refuse "ecr-push" "push of $IMAGE was refused (an existing tag with different content? the repository is IMMUTABLE)"
  docker logout "$REGISTRY" >/dev/null 2>&1 || true
  log "pushed; ECR digest $(aws ecr describe-images --repository-name "$IMAGE_REPO" --image-ids "imageTag=$SHA" --query 'imageDetails[0].imageDigest' --output text)"
fi

# --- 3. deploy over SSM ---------------------------------------------------------------------
if [ -n "$BYPASS" ]; then
  remote="sudo -u deploy env SKIP_BACKUP_GATE=1 /srv/${PROJECT}/deploy/deploy.sh ${DEPLOYABLE} ${SHA}"
else
  remote="sudo -u deploy /srv/${PROJECT}/deploy/deploy.sh ${DEPLOYABLE} ${SHA}"
fi
# bash on the host (AWS-RunShellScript's default sh has no pipefail); the output is also
# appended to the host's log archive so SSM's 24 000-character truncation loses nothing.
remote_cmd="bash -c 'set -o pipefail; ${remote} 2>&1 | tee -a /srv/${PROJECT}/log-archive/promotions.log'"
log "deploying on the host: $remote"
OUTCOME="failed"   # from here on, anything but a clean exit is a failed promotion
CMD_ID="$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --comment "promote ${DEPLOYABLE} ${SHA}" --timeout-seconds "$SSM_TIMEOUT_SECONDS" \
  --parameters "commands=[\"${remote_cmd//\"/\\\"}\"],executionTimeout=[\"${SSM_TIMEOUT_SECONDS}\"]" \
  --query 'Command.CommandId' --output text)" || { echo "✗ promote: send-command failed (the agent role is denied this by design; the operator is not)" >&2; exit 1; }
log "SSM command $CMD_ID — polling"
status="Pending"
deadline=$(( $(date +%s) + SSM_TIMEOUT_SECONDS + 120 ))
while [ "$status" = Pending ] || [ "$status" = InProgress ] || [ "$status" = Delayed ]; do
  sleep 10
  status="$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  [ "$(date +%s)" -lt "$deadline" ] || { echo "✗ promote: SSM command $CMD_ID did not finish within the budget (status $status) — read /srv/${PROJECT}/log-archive/promotions.log on the host; deploy.sh's lock prevents a concurrent run" >&2; exit 1; }
done
out="$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text 2>/dev/null || true)"
err="$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --query 'StandardErrorContent' --output text 2>/dev/null || true)"
echo "----- deploy.sh output (host) -----"
printf '%s\n' "$out"
[ -z "$err" ] || [ "$err" = None ] || { echo "----- stderr -----"; printf '%s\n' "$err"; }
echo "-----------------------------------"

# the previous SHA and the gate's verdict, from the output deploy.sh prints
PREVIOUS_SHA="$(printf '%s\n' "$out" | grep -oE '^→ deploy: [a-z-]+ +[^ ]+ → [0-9a-f]{40}' | head -1 | awk '{print $4}' | grep -vE '^<' || true)"
if [ "$DEPLOYABLE" = web ]; then BACKUP_GATE="not-applicable"
elif printf '%s' "$out" | grep -q 'BACKUP GATE SKIPPED (empty database)'; then BACKUP_GATE="skipped-empty-db"
else BACKUP_GATE="ran"; fi

[ "$status" = Success ] || { echo "✗ promote: deploy.sh on the host ended with status $status — see the output above (rollback: scripts/promote.sh $DEPLOYABLE ${PREVIOUS_SHA:-<previous sha>})" >&2; exit 1; }

OUTCOME="success"
echo "✓ promote: $DEPLOYABLE is on $SHA (lane $LANE, backup gate $BACKUP_GATE, previous ${PREVIOUS_SHA:-<none>})"
