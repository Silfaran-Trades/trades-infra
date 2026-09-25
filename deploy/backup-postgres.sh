#!/usr/bin/env bash
#
# Trades — nightly Postgres backup: one `pg_dump --format=custom` per database, gzip,
# age-encrypted, 14-day local retention, off-host copy slot (production-packaging-promotion-lane
# BR-21). Adapted from ai-standards/templates/deploy/backup-postgres.sh.template.
# Authoritative rules: ai-standards/standards/deployment.md § "Backups and the restore drill".
#
# Schedule: PROVISIONED by the host's user-data as /etc/cron.d/trades-backup (10.6, IA-011) —
# never a hand-edited crontab a rebuilt host silently loses. deploy.sh also calls this inline
# when the DE-005 gate finds no dump newer than BACKUP_MAX_AGE_MINUTES.
#
# THE DUMP IS PERSONAL DATA (every inventoried field, as stored — pii-inventory.md): it is
# encrypted at rest with `age` before it touches the disk, and the private key (the restore
# credential) lives OFF this host. Retention 14 days local AND off-host (BR-21) — an erasure
# request is therefore fully effective at most 14 days after the last dump taken before it.
#
# Inputs (env, all optional except the recipient):
#   AGE_RECIPIENT       the age PUBLIC key (age1…) — or AGE_RECIPIENT_FILE, a file holding it
#                       (default /srv/trades/secrets/backup-age.recipient). The public half is
#                       not a secret, but it is environment-specific, so it is not in this repo.
#   BACKUP_DIR          default /srv/trades/backups
#   RETENTION_DAYS      default 14 — MUST match the dumps row in pii-inventory.md
#   POSTGRES_CONTAINER  default trades-prod-postgres-1 (compose project trades-prod)
#   RCLONE_REMOTE       off-host destination (e.g. `b2:trades-backups`) — 10.6 fills this slot
#                       under the same 14-day ceiling; until then the script WARNS on every run.
#
# TOPOLOGY — modular-monolith: ONE app database (schema per bundle) + media-service's own.

set -euo pipefail

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-trades-prod-postgres-1}"
DATABASES=(trades_app media)
BACKUP_DIR="${BACKUP_DIR:-/srv/trades/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
AGE_RECIPIENT_FILE="${AGE_RECIPIENT_FILE:-/srv/trades/secrets/backup-age.recipient}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"

if [ -z "$AGE_RECIPIENT" ] && [ -r "$AGE_RECIPIENT_FILE" ]; then
  AGE_RECIPIENT="$(tr -d '[:space:]' < "$AGE_RECIPIENT_FILE")"
fi
[ -n "$AGE_RECIPIENT" ] || { echo "✗ backup: no age recipient (AGE_RECIPIENT or $AGE_RECIPIENT_FILE) — refusing to write unencrypted PII dumps" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "✗ backup: age not found on this host — refusing to write unencrypted PII dumps" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

for db in "${DATABASES[@]}"; do
  out="$BACKUP_DIR/${db}-${STAMP}.dump.gz.age"
  # The container's own POSTGRES_USER — never a credential on this command line.
  docker exec "$POSTGRES_CONTAINER" sh -c 'pg_dump -U "$POSTGRES_USER" --format=custom "$0"' "$db" \
    | gzip \
    | age -r "$AGE_RECIPIENT" -o "$out"
  echo "→ backup: $db → $out ($(du -h "$out" | cut -f1))"
done

# Rotate local copies (AC-19): older than RETENTION_DAYS go, the rest stay. In MINUTES, not
# `-mtime +N`: find truncates the age to whole days and `+N` means strictly greater, i.e. at
# least N+1 days — `-mtime +14` kept dumps aged 14d02h and 14d20h (rehearsal, AC-19).
# `-mmin +20160` removes anything older than 14 days to the minute; the rclone `--min-age`
# below is exact already.
find "$BACKUP_DIR" -maxdepth 1 -name '*.dump.gz.age' -mmin "+$((RETENTION_DAYS * 1440))" -delete
echo "→ backup: local copies older than ${RETENTION_DAYS}d pruned"

# Off-host copy — the slot 10.6 fills. A backup that only exists on the disk it protects is
# not a backup; until the remote exists every run says so.
if [ -n "$RCLONE_REMOTE" ]; then
  command -v rclone >/dev/null 2>&1 || { echo "✗ backup: RCLONE_REMOTE set but rclone not installed" >&2; exit 1; }
  rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE" --include '*.dump.gz.age'
  rclone delete "$RCLONE_REMOTE" --include '*.dump.gz.age' --min-age "${RETENTION_DAYS}d"
  echo "→ backup: synced to $RCLONE_REMOTE (same ${RETENTION_DAYS}d ceiling)"
else
  echo "⚠ backup: RCLONE_REMOTE unset — no off-host copy made (10.6 fills this slot)" >&2
fi

echo "✓ backup: completed $STAMP"
