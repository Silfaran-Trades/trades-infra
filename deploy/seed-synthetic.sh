#!/usr/bin/env bash
#
# Trades — the ONE explicit, guarded, one-time lane that loads the synthetic dataset into
# stage-1 production (production-infrastructure-first-deploy BR-31, BR-31a; AC-18, AC-22;
# TM-8, TM-9, TM-12). Runs ON THE HOST by the operator over an SSM session, as the deploy user,
# from /srv/trades/deploy. Deleted at 10.9 together with the guard's production branch.
#
#   sudo -u deploy /srv/trades/deploy/seed-synthetic.sh --confirm-production-stage-1
#
# What it does, in order — and what it refuses:
#   1. refuses without the literal argument `--confirm-production-stage-1`;
#   2. refuses unless `identity.users` is EMPTY (`psql` through the postgres container), naming
#      the count it found — the "already holds users" refusal of AC-18. The dataset seeds two
#      synthetic platform_admin personas, so the developer's OWN platform_admin is created
#      AFTER this lane with `app:create-user` (BR-31a), never before;
#   3. reads the per-run password from /srv/trades/secrets/synthetic-seed.env (mode 600,
#      `SYNTHETIC_SEED_PASSWORD=…`, written by the operator from a generated value and DELETED
#      after the run) — never from an argument, never printed. The backend's
#      SeedPasswordProvider refuses one under 16 characters or equal to the published dev
#      password (AC-22);
#   4. runs the steps of trades-backend's `make seed-dev`, in its order, each as
#      `docker compose run --rm` of the production `app` image with SYNTHETIC_SEED_MODE=
#      production-stage-1 (the only value SeedEnvironmentGuard accepts under APP_ENV=prod),
#      SYNTHETIC_SEED_PASSWORD and DEV_SEED_MEDIA_STORAGE_INTERNAL_HOST (see UPLOAD TARGET
#      below) — the seven console commands plus the two Phinx seeds
#      (`phinx seed:run -s DevSeedUsers -s DevSeedProfessionals` — NEVER a bare `seed:run`,
#      which would run the dormant modules' seeds); the journey seed and the pollution report
#      are NOT run. A step whose module is off in production fails fast and the lane stops: a
#      partial dataset leaves `identity.users` non-empty, so a re-run refuses — recovery is a
#      database reset of the (synthetic-only) stage-1 database (RUNBOOK.md § "Synthetic data");
#   5. prints the seeded account e-mails (never the password) and the line to paste into
#      RUNBOOK.md § "Synthetic-data record".
#
# UPLOAD TARGET (step 5/9, the validation-level photos): app:dev:seed-validation asks
# media-service for a presigned PUT and sends it EXACTLY as signed — the URL names the public
# storage endpoint, `https://storage.<base>` (port 443), and the signed Host header must survive.
# DEV_SEED_MEDIA_STORAGE_INTERNAL_HOST only tells the seed which in-network ADDRESS answers for
# that name (an HTTP-client `resolve`, never a rewrite of the URL). On this stack the `storage`
# container listens on plain HTTP 9000 and nothing on 443 (the rehearsal measured curl exit 7),
# so the address is the PERIMETER: `caddy`, whose `storage.<base>` site terminates TLS with the
# publicly trusted certificate and proxies to storage:9000 with the Host header intact. The
# development stack never showed this because its public endpoint and MinIO share port 9000.
# Verification is never switched off (SE-003): production trusts the public CA; the rehearsal
# harness makes the app image trust Caddy's local root explicitly (rehearse.sh).
#
# Rehearsal: the harness's scratch copy of deploy/ runs this with SEED_PASSWORD_FILE and
# COMPOSE_DIR overridden (the Tester's AC-18 / AC-22 rows).
#
# Env (all optional): COMPOSE_DIR (this directory), SEED_PASSWORD_FILE
# (/srv/trades/secrets/synthetic-seed.env), SEED_MEMORY_LIMIT (1G — the cold container compile
# of trades-backend's seed units does not fit the CLI's default 128M), STORAGE_INTERNAL_HOST
# (caddy — the in-network address that answers for https://storage.<base>, see UPLOAD TARGET).

set -euo pipefail

CONFIRM="${1:-}"
[ "$CONFIRM" = "--confirm-production-stage-1" ] || {
  echo "✗ seed-synthetic: refusing — this lane loads SYNTHETIC data into production and runs ONCE; pass the literal argument --confirm-production-stage-1 (BR-31)" >&2
  exit 1
}

COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
COMPOSE=(docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_DIR/docker-compose.prod.yml")
SEED_PASSWORD_FILE="${SEED_PASSWORD_FILE:-/srv/trades/secrets/synthetic-seed.env}"
SEED_MEMORY_LIMIT="${SEED_MEMORY_LIMIT:-1G}"
STORAGE_INTERNAL_HOST="${STORAGE_INTERNAL_HOST:-caddy}"   # the perimeter, not `storage` (UPLOAD TARGET above)
SEED_MODE="production-stage-1"

log() { printf '→ seed-synthetic: %s\n' "$*"; }
die() { printf '✗ seed-synthetic: %s\n' "$*" >&2; exit 1; }

# --- 2. an EMPTY identity.users, or nothing happens -------------------------------------------
[ -n "$("${COMPOSE[@]}" ps -q postgres 2>/dev/null)" ] || die "the postgres container is not running — the lane runs after the first app promotion"
# shellcheck disable=SC2016  # the container's own POSTGRES_USER, never a credential on this line
count="$("${COMPOSE[@]}" exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d trades_app -tAc "SELECT count(*) FROM identity.users"' 2>&1)" \
  || die "could not count identity.users ($count) — has the first app promotion run the migrations?"
count="$(printf '%s' "$count" | tr -d '[:space:]')"
case "$count" in
  0) log "identity.users is empty — the lane may run" ;;
  ''|*[!0-9]*) die "unexpected count '$count' from identity.users — refusing" ;;
  *) die "identity.users already holds ${count} row(s) — the synthetic-data lane runs ONLY on an empty database (AC-18, TM-9). A partial earlier run? See RUNBOOK.md § \"Synthetic data\" for the reset." ;;
esac

# --- 3. the per-run password, from a 600 file ---------------------------------------------------
[ -f "$SEED_PASSWORD_FILE" ] || die "$SEED_PASSWORD_FILE missing — write it from a generated value (RUNBOOK.md § \"Synthetic data\"): SYNTHETIC_SEED_PASSWORD=<at least 16 characters>"
mode="$(stat -c '%a' "$SEED_PASSWORD_FILE" 2>/dev/null || stat -f '%Lp' "$SEED_PASSWORD_FILE" 2>/dev/null || echo '?')"
[ "$mode" = 600 ] || die "$SEED_PASSWORD_FILE must be mode 600 (is $mode)"
SYNTHETIC_SEED_PASSWORD="$(grep -E '^SYNTHETIC_SEED_PASSWORD=' "$SEED_PASSWORD_FILE" | head -1 | cut -d= -f2- || true)"
[ -n "$SYNTHETIC_SEED_PASSWORD" ] || die "$SEED_PASSWORD_FILE carries no SYNTHETIC_SEED_PASSWORD= line"
[ "${#SYNTHETIC_SEED_PASSWORD}" -ge 16 ] || die "SYNTHETIC_SEED_PASSWORD is shorter than 16 characters — the backend refuses it too (AC-22)"
export SYNTHETIC_SEED_PASSWORD
log "password read from $SEED_PASSWORD_FILE (${#SYNTHETIC_SEED_PASSWORD} characters; never printed) — delete the file after this run"

# --- 4. the seed units, in make seed-dev's order ---------------------------------------------
# `run --rm --no-deps`: a one-off container of the production app image (read-only root,
# tmpfs var/ — every unit compiles the container cold, hence the memory limit); the running
# stack is not touched. The three variables ride the process environment only (never an env
# file — the guard reads the switch raw from the environment, BR-31).
seed_run() {   # seed_run <description> <command…>
  desc="$1"; shift
  log "$desc"
  "${COMPOSE[@]}" run --rm --no-deps -T \
    -e "SYNTHETIC_SEED_MODE=$SEED_MODE" -e SYNTHETIC_SEED_PASSWORD \
    -e "DEV_SEED_MEDIA_STORAGE_INTERNAL_HOST=$STORAGE_INTERNAL_HOST" \
    app "$@" \
    || die "step failed: $desc — identity.users may now be non-empty, so a re-run will refuse; see RUNBOOK.md § \"Synthetic data\" for the reset"
}
console=(php -d "memory_limit=$SEED_MEMORY_LIMIT" bin/console)

seed_run "1/9 catalog (the taxonomy every later unit resolves by slug)"     "${console[@]}" app:dev:seed-catalog
seed_run "2/9 Phinx seeds DevSeedUsers + DevSeedProfessionals (the lane's two, never a bare seed:run)" \
  php vendor/bin/phinx seed:run --environment=default -s DevSeedUsers -s DevSeedProfessionals
seed_run "3/9 comms recipients (before any unit that notifies)"              "${console[@]}" app:dev:seed-recipients
seed_run "4/9 companies"                                                    "${console[@]}" app:dev:seed-companies
seed_run "5/9 validation levels (uploads: presigned PUT to https://storage.<base> via $STORAGE_INTERNAL_HOST)" "${console[@]}" app:dev:seed-validation
seed_run "6/9 demands + matching + candidacies"                              "${console[@]}" app:dev:seed-demands
seed_run "7/9 written-demand parses"                                        "${console[@]}" app:dev:seed-demand-text-parses
seed_run "8/9 conversations"                                                "${console[@]}" app:dev:seed-conversations
seed_run "9/9 comms recipients again (after every unit that creates a user)" "${console[@]}" app:dev:seed-recipients

# --- 5. the record (e-mails only — never the password) -----------------------------------------
# shellcheck disable=SC2016
emails="$("${COMPOSE[@]}" exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d trades_app -tAc "SELECT email FROM identity.users ORDER BY email"' 2>/dev/null || true)"
n="$(printf '%s\n' "$emails" | grep -c '@' || true)"
echo ""
echo "✓ seed-synthetic: the dataset is loaded — ${n} seeded account(s):"
printf '%s\n' "$emails" | sed 's/^/    /'
echo ""
echo "  RUNBOOK line (paste into deploy/RUNBOOK.md § \"Synthetic-data record\"):"
echo "    $(date -u +%FT%TZ) — synthetic dataset loaded (SYNTHETIC_SEED_MODE=${SEED_MODE}, ${n} accounts, password handed to the partner out of band) — operator: $(whoami)@$(hostname)"
echo "  Next: delete $SEED_PASSWORD_FILE; then create YOUR platform_admin with app:create-user (BR-31a); then provision the agent role (deploy/agent-db/provision-agent-role.sh)."
