#!/usr/bin/env bash
#
# Trades — restore drill: the proof that the encrypted backups actually restore (AC-15).
# Adapted from ai-standards/templates/deploy/restore-drill.sh.template.
# Authoritative rules: ai-standards/standards/deployment.md § "Backups and the restore drill"
# (quarterly, mandatory; the drill-record line goes into this repo's README).
#
# Usage:  ./restore-drill.sh /path/to/age-key.txt
#
# WHERE it runs: wherever the age PRIVATE key is — OFF the host by design. Both lanes work:
#   - dev machine: set RCLONE_REMOTE — the newest dump per database is pulled from the off-host
#     copy (needs docker, age, rclone);
#   - on-host / rehearsal: leave RCLONE_REMOTE empty — dumps are read from BACKUP_DIR.
#
# Per database:
#   1. locates the NEWEST dump — copied into a private scratch dir FIRST, so a concurrent
#      retention prune can never remove the file mid-drill (spec § Edge Cases)
#   2. starts a THROWAWAY PostGIS container (the pinned production image — a dump restores
#      forward, never backward), never the production one
#   3. decrypts → gunzips → pg_restores into scratch_restore with --no-owner
#   4. runs ONE READ PER SCHEMA: every non-system schema the restored database lists in
#      pg_namespace (the modular monolith's schema-per-bundle layout), one count per schema
#      from its first table — so a bundle whose schema silently did not restore is a red line
#   5. tears the container down and prints the drill-record line

set -euo pipefail

AGE_KEY="${1:?usage: restore-drill.sh /path/to/age-key.txt}"
[ -r "$AGE_KEY" ] || { echo "✗ drill: cannot read age key at $AGE_KEY" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "✗ drill: age not found" >&2; exit 1; }

DATABASES=(trades_app media)
BACKUP_DIR="${BACKUP_DIR:-/srv/trades/backups}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
# The production image (docker-compose.prod.yml) — same major, same PostGIS.
PG_IMAGE="${PG_IMAGE:-imresamu/postgis:18-3.6@sha256:b5766ee720aca09c61b9a868abefbf273348a4b90ad4cf146b4f8c9ac85d48e4}"
CONTAINER="${RESTORE_DRILL_CONTAINER:-trades-restore-drill}"
WORKDIR="$(mktemp -d)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- throwaway postgres — never the production container ----------------------
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=drill "$PG_IMAGE" >/dev/null
until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

psql_scratch() { docker exec "$CONTAINER" psql -U postgres -d scratch_restore -tAc "$1"; }

RECORD=()
for db in "${DATABASES[@]}"; do
  # --- 1. newest dump, copied into the private scratch dir before anything else --
  if [ -n "$RCLONE_REMOTE" ]; then
    newest="$(rclone lsf "$RCLONE_REMOTE" --include "${db}-*.dump.gz.age" | sort | tail -1)"
    [ -n "$newest" ] || { echo "✗ drill: no ${db}-*.dump.gz.age in $RCLONE_REMOTE" >&2; exit 1; }
    rclone copyto "$RCLONE_REMOTE/$newest" "$WORKDIR/$newest"
  else
    src="$(find "$BACKUP_DIR" -maxdepth 1 -name "${db}-*.dump.gz.age" | sort | tail -1)"
    [ -n "$src" ] || { echo "✗ drill: no ${db}-*.dump.gz.age in $BACKUP_DIR" >&2; exit 1; }
    cp "$src" "$WORKDIR/"
    newest="$(basename "$src")"
  fi
  dump="$WORKDIR/$newest"
  echo "→ drill: $db ← $newest"
  # The first bytes of the file must be the age header — an unencrypted dump on disk is a
  # finding in its own right (BR-21).
  head -c 21 "$dump" | grep -q '^age-encryption.org/v1' || { echo "✗ drill: $newest does not start with the age header — the dump on disk is NOT encrypted" >&2; exit 1; }

  # --- 2..3. decrypt → restore into a fresh scratch database ------------------
  docker exec "$CONTAINER" psql -U postgres -q \
    -c "DROP DATABASE IF EXISTS scratch_restore" -c "CREATE DATABASE scratch_restore"
  age -d -i "$AGE_KEY" "$dump" | gunzip \
    | docker exec -i "$CONTAINER" pg_restore -U postgres -d scratch_restore --no-owner
  echo "→ drill: $db restored"

  # --- 4. one read per schema -------------------------------------------------
  schemas="$(psql_scratch "SELECT nspname FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast') AND nspname NOT LIKE 'pg_temp%' AND nspname NOT LIKE 'pg_toast%' ORDER BY nspname")"
  [ -n "$schemas" ] || { echo "✗ drill: $db restored with no schema at all" >&2; exit 1; }
  reads=()
  for schema in $schemas; do
    table="$(psql_scratch "SELECT tablename FROM pg_tables WHERE schemaname='${schema}' ORDER BY tablename LIMIT 1")"
    if [ -z "$table" ]; then
      # A schema with no table (e.g. `public` holding only extensions) is read as such.
      reads+=("${schema}:no-table")
      continue
    fi
    rows="$(psql_scratch "SELECT count(*) FROM \"${schema}\".\"${table}\"")"
    echo "→ drill: $db  ${schema}.${table} → $rows row(s)"
    reads+=("${schema}.${table}=${rows}")
  done
  RECORD+=("$db: $newest — ${reads[*]}")
done

# --- 5. the drill-record line — copy into trades-infra/README.md ---------------
echo ""
echo "✓ restore drill OK $(date +%F) — ${RECORD[*]}"
echo "  (record this line in trades-infra/README.md — deployment.md § Backups)"
