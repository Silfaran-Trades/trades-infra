#!/bin/bash
# Regenerate the mask-schema views from the mask manifest (IA-010; production-infrastructure-
# first-deploy BR-27, AC-14, TM-3).
#
# Derived from: ai-standards/templates/deploy/generate-masked-views.sh.template
# Authoritative rules: ai-standards/standards/infrastructure.md § "AI-agent access to production"
# Adaptations (spec § "The agent's masked database role"; KHA's lane as the reference):
#   (a) the manifest is GENERATED — deploy/agent-db/mask-manifest.txt, written by
#       scripts/agent-db/build-mask-manifest.py from trades-docs/pii-inventory.md (the
#       inventory's `service | table | column` rows mapped to the schema-per-bundle names).
#       Never edit the manifest by hand: a stale or wrong row is fixed in the INVENTORY and
#       the manifest regenerated (`make mask-manifest`);
#   (b) psql runs INSIDE the postgres container by default (the prod compose publishes no host
#       port and the host has no psql client — user-data installs none); the container's own
#       POSTGRES_USER authenticates over the local socket, so no credential rides a command
#       line. DATABASE_URL overrides for a direct connection (local dev, CI);
#   (c) the role must exist (agent-readonly-role.sql has run) — otherwise the final GRANT
#       fails late with a misleading error;
#   (d) a CREDENTIAL-COLUMN FLOOR beyond the manifest: any live column whose normalised name
#       carries a credential concept (password, token, secret, apikey, credential, hash) is
#       omitted from the view even when the inventory lists no row for it — the inventory
#       deliberately calls credentials "secrets, not PII-tier rows", and an agent lane must
#       never read hash material (the users table's Argon2id hashes are the live case).
#       Over-masking is safe; the floor only ever REMOVES a column, never exposes one.
#
# Run in the SAME step that applies migrations or edits pii-inventory.md — drift between the
# inventory and the views is the failure mode. Idempotent. IA-004: the OPERATOR runs this
# against production (deploy/agent-db/provision-agent-role.sh); an agent never does.
#
# FAIL-CLOSED at both granularities:
#   * table level  — a table absent from the manifest gets NO view. It is then unreadable by
#     ai_readonly (no grant on its base schema): invisible, never exposed. Every table not
#     carrying a PII row in the inventory is in this bucket on purpose (shared.messenger_messages,
#     identity.password_reset_tokens, public.phinxlog, the catalog taxonomy tables, …);
#   * column level — a manifest column that no longer exists in the live table (renamed,
#     dropped, typo) ABORTS the run instead of silently regenerating a view that could expose
#     the renamed column. The first run may surface stale inventory rows: fix the inventory.
#
# Manifest format — one line per EXPOSED table:
#   <schema>.<table>: <sensitive-col>[,<sensitive-col>...]
#   <schema>.<table>:                       # no sensitive columns — full view
# View naming: public.<t> → mask.<t>; every other schema is PREFIXED so the schema-per-bundle
# layout cannot collide: identity.users → mask.identity__users.
#
# Usage (operator, on the host — the lane script calls it):
#   cd /srv/trades/deploy/agent-db && ./generate-masked-views.sh          # ./mask-manifest.txt
# Anywhere with a reachable DSN (local dev, published port):
#   DATABASE_URL=postgresql://trades:<password>@127.0.0.1:5432/trades_app ./generate-masked-views.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${1:-$SCRIPT_DIR/mask-manifest.txt}"
[ -f "$MANIFEST" ] || { echo "ERROR: manifest '$MANIFEST' not found — generate it with scripts/agent-db/build-mask-manifest.py (make mask-manifest)" >&2; exit 1; }

# Adaptation (d): the credential-column floor — the logging baseline's sensitive concepts
# (logging.md § "Sensitive field redaction") plus `hash`. Matched on the NORMALISED column
# name (lowercased, separators stripped), so password_hash, resetToken, api_key all match.
CREDENTIAL_TOKENS="password token secret apikey credential hash"
is_credential_column() {
  norm="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '_-')"
  for t in $CREDENTIAL_TOKENS; do
    case "$norm" in *"$t"*) return 0 ;; esac
  done
  return 1
}

if [ -n "${DATABASE_URL:-}" ]; then
  PSQL=(psql "$DATABASE_URL")
else
  COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/../docker-compose.prod.yml}"
  [ -f "$COMPOSE_FILE" ] || { echo "ERROR: compose file '$COMPOSE_FILE' not found — run from deploy/agent-db, set COMPOSE_FILE, or set DATABASE_URL for a direct connection" >&2; exit 1; }
  # Adaptation (b): the container's own POSTGRES_USER, read inside the container.
  # shellcheck disable=SC2016
  PSQL=(docker compose --project-directory "$(dirname "$COMPOSE_FILE")" -f "$COMPOSE_FILE" exec -T postgres sh -c 'exec psql -U "$POSTGRES_USER" -d trades_app "$@"' --)
fi

# `</dev/null` is load-bearing: psql_run is called INSIDE `while read` loops, and the
# container lane's `docker compose exec -T` forwards its stdin — without the redirect it eats
# the rest of the manifest and the run "succeeds" having generated only the first view.
psql_run() { "${PSQL[@]}" -v ON_ERROR_STOP=1 -qAt "$@" </dev/null; }

# All identifiers this script splices into SQL must match the toolkit's own English
# snake_case invariant — reject anything else rather than escape it.
check_ident() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
    || { echo "ERROR: unsafe identifier '$1' (want lowercase snake_case)" >&2; exit 1; }
}

# Adaptation (c): the role must exist first.
role_exists="$(psql_run -c "SELECT 1 FROM pg_roles WHERE rolname = 'ai_readonly';")"
if [ -z "$role_exists" ]; then
  echo "ERROR: role ai_readonly does not exist — run agent-readonly-role.sql first (a Postgres volume rebuild silently drops it)" >&2
  exit 1
fi

SQL="BEGIN;"

# Fail-closed sweep: drop every existing mask view first; only manifest entries are
# recreated below. A table removed from the manifest disappears. Command substitution (NOT
# process substitution) on purpose: set -e observes a psql failure here — a silently skipped
# sweep would leave stale views that the final GRANT re-exposes.
existing_views="$(psql_run -c "SELECT table_name FROM information_schema.views WHERE table_schema = 'mask';")"
while IFS= read -r view; do
  [ -n "$view" ] || continue
  check_ident "$view"
  SQL+=$'\n'"DROP VIEW IF EXISTS mask.\"$view\";"
done <<< "$existing_views"

generated=0
floor_hits=0

# `|| [ -n "$raw" ]` keeps the final manifest line when the file lacks a trailing newline —
# without it that entry's view is dropped and never rebuilt.
while IFS= read -r raw || [ -n "$raw" ]; do
  line="${raw%%#*}"                       # strip comments
  line="$(echo "$line" | tr -d '[:space:]')"
  [ -n "$line" ] || continue

  qualified="${line%%:*}"                 # schema.table
  masked_csv="${line#*:}"                 # col,col (possibly empty)
  schema="${qualified%%.*}"
  table="${qualified#*.}"
  check_ident "$schema"
  check_ident "$table"

  # Live columns from the catalog...
  cols="$(psql_run -c "SELECT column_name FROM information_schema.columns
                       WHERE table_schema = '$schema' AND table_name = '$table'
                       ORDER BY ordinal_position;")"
  if [ -z "$cols" ]; then
    echo "ERROR: $qualified is in the manifest but not in the database — a stale inventory row (fix pii-inventory.md, regenerate the manifest), or the migrations have not run" >&2
    exit 1
  fi

  # ...minus the manifest's sensitive columns (and the credential floor). Track which
  # manifest columns actually matched — an unmatched one means the DB and the inventory have
  # drifted (rename/typo), and regenerating would EXPOSE the renamed column.
  keep=""
  unmatched=",$masked_csv,"
  while IFS= read -r col; do
    [ -n "$col" ] || continue
    check_ident "$col"
    case ",$masked_csv," in
      *",$col,"*) unmatched="${unmatched/,$col,/,}" ;;              # inventoried — omitted
      *)
        if is_credential_column "$col"; then                         # adaptation (d) — omitted
          echo "NOTE: $qualified.$col omitted by the credential-column floor (not in the inventory; never readable by an agent)" >&2
          floor_hits=$((floor_hits + 1))
        else
          keep+="${keep:+, }\"$col\""
        fi
        ;;
    esac
  done <<< "$cols"

  if [ -n "$masked_csv" ] && [ "$unmatched" != "," ]; then
    leftover="${unmatched#,}"; leftover="${leftover%,}"
    echo "ERROR: $qualified: manifest sensitive column(s) '$leftover' do not exist in the live table (renamed? dropped? typo?) - refusing to regenerate a view that could expose them. Fix pii-inventory.md and regenerate the manifest." >&2
    exit 1
  fi

  if [ -z "$keep" ]; then
    echo "NOTE: $qualified has only sensitive columns - no view generated" >&2
    continue
  fi

  view_name="$table"
  [ "$schema" != "public" ] && view_name="${schema}__${table}"

  SQL+=$'\n'"CREATE VIEW mask.\"$view_name\" WITH (security_barrier = true) AS SELECT $keep FROM \"$schema\".\"$table\";"
  generated=$((generated + 1))
done < "$MANIFEST"

SQL+=$'\n'"GRANT SELECT ON ALL TABLES IN SCHEMA mask TO ai_readonly;"
SQL+=$'\n'"COMMIT;"

echo "$SQL" | "${PSQL[@]}" -v ON_ERROR_STOP=1 -q
echo "mask schema regenerated from $MANIFEST ($generated views; $floor_hits column(s) omitted by the credential floor)"
