#!/usr/bin/env bash
#
# Trades — nightly Postgres backup: one `pg_dump --format=custom` per database, gzip,
# age-encrypted, 14-day local retention, and the OFF-HOST COPY to this project's S3 backups
# bucket (production-packaging-promotion-lane BR-21; production-infrastructure-first-deploy
# BR-28, AC-15). Adapted from ai-standards/templates/deploy/backup-postgres.sh.template.
# Authoritative rules: ai-standards/standards/deployment.md § "Backups and the restore drill".
#
# Schedule: PROVISIONED by the host's user-data as /etc/cron.d/trades-backup (IA-011) —
# never a hand-edited crontab a rebuilt host silently loses. deploy.sh also calls this inline
# when the DE-005 gate finds no dump newer than BACKUP_MAX_AGE_MINUTES.
#
# THE DUMP IS PERSONAL DATA (every inventoried field, as stored — pii-inventory.md): it is
# encrypted at rest with `age` before it touches the disk, and the private key (the restore
# credential) lives OFF this host. Retention: 14 days local (the prune below) and 14 days
# off-host — enforced by the bucket's LIFECYCLE RULE (current versions 7 days + noncurrent
# versions 7 days), NEVER by this script: the host role holds no s3:DeleteObject* at all, so
# a compromised host cannot purge its own backups (BR-28, TM-4). There is no remote delete here.
#
# Inputs (env, all optional except the recipient and the bucket):
#   AGE_RECIPIENT       the age PUBLIC key (age1…) — or AGE_RECIPIENT_FILE, a file holding it
#                       (default /srv/trades/secrets/backup-age.recipient). The public half is
#                       not a secret, but it is environment-specific, so it is not in this repo.
#   BACKUPS_BUCKET      the off-host destination (`terraform output backups_bucket`). Read from
#                       deploy/.env next to this script when unset (host state; deploy.sh and
#                       the cron rely on that). MISSING = HARD STOP: a backup that exists only
#                       on the disk it protects is not a backup. The ONE opt-out is the local
#                       rehearsal (REHEARSAL_NO_OFFHOST_COPY=1, logged loudly) — never production.
#   AWS_REGION          default eu-south-2 (the bucket's region)
#   BACKUP_DIR          default /srv/trades/backups
#   RETENTION_DAYS      default 14 — MUST match the dumps row in pii-inventory.md
#   POSTGRES_CONTAINER  default trades-prod-postgres-1 (compose project trades-prod)
#
# TOPOLOGY — modular-monolith: ONE app database (schema per bundle) + media-service's own.

set -euo pipefail

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-trades-prod-postgres-1}"
DATABASES=(trades_app media)
BACKUP_DIR="${BACKUP_DIR:-/srv/trades/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
AGE_RECIPIENT_FILE="${AGE_RECIPIENT_FILE:-/srv/trades/secrets/backup-age.recipient}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"
AWS_REGION="${AWS_REGION:-eu-south-2}"
DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-$(cd "$(dirname "$0")" && pwd)/.env}"
export AWS_PAGER=""

if [ -z "$AGE_RECIPIENT" ] && [ -r "$AGE_RECIPIENT_FILE" ]; then
  AGE_RECIPIENT="$(tr -d '[:space:]' < "$AGE_RECIPIENT_FILE")"
fi
[ -n "$AGE_RECIPIENT" ] || { echo "✗ backup: no age recipient (AGE_RECIPIENT or $AGE_RECIPIENT_FILE) — refusing to write unencrypted PII dumps" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "✗ backup: age not found on this host — refusing to write unencrypted PII dumps" >&2; exit 1; }

# The off-host destination — resolved BEFORE any dump is taken, so a missing bucket is a
# clean refusal and not a local-only dump that looks like a backup.
BACKUPS_BUCKET="${BACKUPS_BUCKET:-}"
if [ -z "$BACKUPS_BUCKET" ] && [ -r "$DEPLOY_ENV_FILE" ]; then
  BACKUPS_BUCKET="$(grep -E '^BACKUPS_BUCKET=' "$DEPLOY_ENV_FILE" | head -1 | cut -d= -f2- | tr -d "\"'" || true)"
fi
if [ -z "$BACKUPS_BUCKET" ]; then
  if [ "${REHEARSAL_NO_OFFHOST_COPY:-0}" = "1" ]; then
    echo "⚠ backup: REHEARSAL_NO_OFFHOST_COPY=1 — NO off-host copy will be made; acceptable ONLY in the local rehearsal" >&2
  else
    echo "✗ backup: BACKUPS_BUCKET is unset (env or $DEPLOY_ENV_FILE) — refusing: a dump that exists only on the disk it protects is not a backup (BR-28). Set it from \`terraform output backups_bucket\`." >&2
    exit 1
  fi
else
  command -v aws >/dev/null 2>&1 || { echo "✗ backup: aws CLI not found — the off-host copy cannot be made (the host's user-data installs it; is /snap/bin on PATH?)" >&2; exit 1; }
fi

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
NEW_FILES=()

for db in "${DATABASES[@]}"; do
  out="$BACKUP_DIR/${db}-${STAMP}.dump.gz.age"
  # The container's own POSTGRES_USER — never a credential on this command line.
  docker exec "$POSTGRES_CONTAINER" sh -c 'pg_dump -U "$POSTGRES_USER" --format=custom "$0"' "$db" \
    | gzip \
    | age -r "$AGE_RECIPIENT" -o "$out"
  echo "→ backup: $db → $out ($(du -h "$out" | cut -f1))"
  NEW_FILES+=("$out")
done

# Off-host copy (BR-28): each NEW file, under postgres/, through the instance profile (put
# only). The age header is the proof the object is encrypted before it leaves the host.
if [ -n "$BACKUPS_BUCKET" ]; then
  for f in "${NEW_FILES[@]}"; do
    head -c 21 "$f" | grep -q '^age-encryption.org/v1' || { echo "✗ backup: $(basename "$f") does not start with the age header — NOT uploading an unencrypted dump" >&2; exit 1; }
    aws s3 cp --region "$AWS_REGION" --only-show-errors "$f" "s3://${BACKUPS_BUCKET}/postgres/$(basename "$f")" \
      || { echo "✗ backup: off-host copy of $(basename "$f") FAILED — the dump exists only on this host; fix the bucket / role before the next run" >&2; exit 1; }
    echo "→ backup: $(basename "$f") → s3://${BACKUPS_BUCKET}/postgres/ (expiry: the bucket's lifecycle rule, 7 + 7 days)"
  done
fi

# Rotate LOCAL copies (AC-19 of 10.4): older than RETENTION_DAYS go, the rest stay. In MINUTES,
# not `-mtime +N`: find truncates the age to whole days and `+N` means strictly greater, i.e.
# at least N+1 days — `-mtime +14` kept dumps aged 14d02h and 14d20h (rehearsal, AC-19).
# `-mmin +20160` removes anything older than 14 days to the minute. The off-host copies are
# expired by the bucket's lifecycle rule, never from here.
find "$BACKUP_DIR" -maxdepth 1 -name '*.dump.gz.age' -mmin "+$((RETENTION_DAYS * 1440))" -delete
echo "→ backup: local copies older than ${RETENTION_DAYS}d pruned"

echo "✓ backup: completed $STAMP"
