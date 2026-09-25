#!/usr/bin/env bash
#
# Trades — server-side promotion script: the gated deploy sequence from
# ai-standards/standards/deployment.md § "The deploy sequence", adapted from
# ai-standards/templates/deploy/deploy.sh.template (production-packaging-promotion-lane, BR-20).
#
# Runs on the host from /srv/trades/deploy (the DE-004 manual sync lane) — and on a
# developer machine by the rehearsal harness (rehearsal/rehearse.sh), which is why every host
# path below is an overridable variable and nothing here is Linux-only.
#
# Usage:   ./deploy.sh <service> <git-sha>        service ∈ app | media | web
#          ./deploy.sh app 3f9c2ab…(40 hex)
#
# What it does, in order — and why it refuses to skip steps:
#   0.  takes the promotion LOCK (two promotions never run at once — the second fails and says so)
#   0a. refuses anything that is not a full 40-char git SHA (never `latest`, never the sentinel)
#   0b. warns when the root volume is ≥80% full (disk pre-flight, IA-011)
#   1.  records the currently-running tag (the rollback target, printed to the log)
#   1b. pre-migration backup gate (DE-005) for the two services whose container start runs
#       migrations (app, media): refuses unless a dump newer than BACKUP_MAX_AGE_MINUTES exists,
#       taking one inline via backup-postgres.sh when the newest is stale. `SKIP_BACKUP_GATE=1`
#       is explicit and logged — legitimate only on a first boot with no data. Runs BEFORE the
#       tag pin so a gate failure leaves deploy/.env untouched.
#   2.  pins the new tag in deploy/.env; on a fresh host seeds missing sibling tags with an
#       unpromotable sentinel (2b)
#   2c. archives the OUTGOING container's log before the recreate (DE-007), redacted, and
#       prunes the archive past LOG_ARCHIVE_RETENTION_DAYS (14 — BR-31, pii-inventory.md)
#   3.  docker compose pull + up -d for THAT service only (`SKIP_PULL=1`, logged, lets the
#       rehearsal promote locally-built images that were never pushed)
#   3a. ensures the runtime set NOTHING depends on — the perimeter (`caddy`) and the Chat hub
#       (`mercure`) — with `up -d --no-recreate` (started when absent or stopped, never touched
#       when running) and gates `caddy` on its healthcheck on every promotion, `mercure` on `app`
#   4.  readiness gate: polls /api/health inside the container (the SPA: its root) until healthy
#       or 120 s — on failure prints the rollback command and exits 1
#   4a. gates the promoted container on its DOCKER healthcheck too — the state `compose ps`, the
#       Rung-2 sentinel and the rehearsal harness read, and for `media` a STRICTER probe than 4
#       (both supervisord consumers RUNNING). The promotion never returns on `starting`
#   4b. for `app`: recreates the three workers on the SAME tag and gates each on its Docker
#       healthcheck (PID-1 consumer, DE-003) — a crash-looping worker never ships green
#   5.  smoke URLs through the real perimeter, then the route-map canary on the newest surface
#       (`GET /api/v1/school-link/training-needs` must answer 401, never 404 — DE-002)
#   6.  prunes images unused for 7+ days (IA-011 — rollback re-pulls from the registry)
#
# HOST OVERRIDES (all optional; the rehearsal sets every one):
#   BACKUP_DIR, BACKUP_MAX_AGE_MINUTES, BACKUP_SCRIPT, LOG_ARCHIVE_DIR, LOG_ARCHIVE_RETENTION_DAYS,
#   DEPLOY_LOCK_DIR, SKIP_BACKUP_GATE=1, SKIP_PULL=1, SMOKE_CURL_EXTRA_ARGS (e.g. `--resolve`
#   entries for hostnames that do not resolve publicly), CURL_CA_BUNDLE (curl reads it itself —
#   the rehearsal points it at Caddy's local root; verification is never switched off).

set -euo pipefail

SERVICE="${1:?usage: deploy.sh <app|media|web> <git-sha>}"
SHA="${2:?usage: deploy.sh <app|media|web> <git-sha>}"

case "$SERVICE" in
  app|media|web) ;;
  *) echo "✗ deploy: unknown service '$SERVICE' — one of app | media | web (the three deployables; workers ride app's tag)" >&2; exit 1 ;;
esac

# Never 'latest', never a sentinel: images are tagged with the FULL git SHA, and the
# first-boot 'bootstrap-pending' sentinel (step 2b) must be unpromotable by construction.
if ! printf '%s' "$SHA" | grep -qE '^[0-9a-f]{40}$'; then
  echo "✗ deploy: '$SHA' is not a full 40-char git SHA — refusing" >&2
  exit 1
fi

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DEPLOY_DIR/.env"
COMPOSE=(docker compose --project-directory "$DEPLOY_DIR" -f "$DEPLOY_DIR/docker-compose.prod.yml")

# --- 0. the promotion lock ------------------------------------------------------
# An atomic `mkdir` is the lock: POSIX guarantees exactly one caller creates the directory,
# and it exists on the Linux host AND on the macOS rehearsal machine (`flock(1)` is util-linux
# only, so the rehearsal could not have exercised it). The pid inside lets an operator tell a
# live promotion from a crashed one; the trap releases it on every exit path.
DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR:-/srv/trades/deploy.lock}"
if ! mkdir "$DEPLOY_LOCK_DIR" 2>/dev/null; then
  echo "✗ deploy: another promotion holds the lock $DEPLOY_LOCK_DIR (pid $(cat "$DEPLOY_LOCK_DIR/pid" 2>/dev/null || echo '?')) — refusing to run two promotions at once. If that process is dead, remove the directory and retry." >&2
  exit 1
fi
echo "$$" > "$DEPLOY_LOCK_DIR/pid"
trap 'rm -rf "$DEPLOY_LOCK_DIR"' EXIT

# --- 0b. disk pre-flight (IA-011) ---------------------------------------------
# `df --output` is GNU-only; on the macOS rehearsal machine it fails silently and the warning
# is skipped — the host is Linux, where it works.
DISK_USE="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
if [ "${DISK_USE:-0}" -ge 80 ]; then
  echo "⚠ deploy: root volume at ${DISK_USE}% — inspect before this becomes an outage (docker system df; du -sh \"\${BACKUP_DIR:-/srv/trades/backups}\")" >&2
fi

# --- 1. rollback target ------------------------------------------------------
TAG_VAR="$(printf '%s' "$SERVICE" | tr '[:lower:]-' '[:upper:]_')_TAG"
PREVIOUS="$(grep -E "^${TAG_VAR}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
echo "→ deploy: $SERVICE  ${PREVIOUS:-<none>} → $SHA  (rollback: ./deploy.sh $SERVICE ${PREVIOUS:-<none>})"

# deploy.sh does NOT source .env — DOMAIN is extracted the same way as the tag lines.
DOMAIN="$(grep -E '^DOMAIN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
[ -n "$DOMAIN" ] || { echo "✗ deploy: DOMAIN is not set in $ENV_FILE (see rehearsal/templates/deploy.env.template)" >&2; exit 1; }
# The perimeter's published HTTPS port — 443 in production; the rehearsal may move it.
HTTPS_PORT="$(grep -E '^CADDY_HTTPS_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
PORT_SUFFIX=""
[ -z "$HTTPS_PORT" ] || [ "$HTTPS_PORT" = 443 ] || PORT_SUFFIX=":${HTTPS_PORT}"

# --- 1b. pre-migration backup gate (DE-005) — app and media migrate on start; web does not ---
BACKUP_DIR="${BACKUP_DIR:-/srv/trades/backups}"
BACKUP_MAX_AGE_MINUTES="${BACKUP_MAX_AGE_MINUTES:-60}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-$DEPLOY_DIR/backup-postgres.sh}"
freshest_dump() { find "$BACKUP_DIR" -maxdepth 1 -name '*.dump.gz.age' -mmin "-${BACKUP_MAX_AGE_MINUTES}" 2>/dev/null | head -1; }
if [ "$SERVICE" = "web" ]; then
  echo "→ deploy: backup gate not applicable ($SERVICE runs no migrations)"
elif [ "${SKIP_BACKUP_GATE:-0}" = "1" ]; then
  echo "→ deploy: BACKUP GATE SKIPPED (SKIP_BACKUP_GATE=1) — acceptable only on a first boot with an empty database"
else
  # Dead-cron tripwire (IA-011): the inline top-up below MASKS a dead nightly cron.
  if [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '*.dump.gz.age' -mmin -1560 2>/dev/null | head -1)" ]; then
    echo "⚠ deploy: no dump newer than 26h in $BACKUP_DIR — the nightly backup cron looks DEAD; fix /etc/cron.d/trades-backup (check /var/log/trades-backup.log), do not rely on this gate's inline top-up" >&2
  fi
  if [ -z "$(freshest_dump)" ]; then
    if [ -x "$BACKUP_SCRIPT" ]; then
      echo "→ deploy: no dump newer than ${BACKUP_MAX_AGE_MINUTES}min in $BACKUP_DIR — taking one now via $BACKUP_SCRIPT"
      # `|| true`: an inline-backup crash must fall through to the re-check below.
      "$BACKUP_SCRIPT" || true
    fi
    if [ -z "$(freshest_dump)" ]; then
      echo "✗ deploy: pre-migration backup gate FAILED (DE-005) — no dump newer than ${BACKUP_MAX_AGE_MINUTES}min in $BACKUP_DIR and none could be taken." >&2
      echo "✗ run $BACKUP_SCRIPT first (or point BACKUP_DIR/BACKUP_SCRIPT at the right paths); SKIP_BACKUP_GATE=1 only for a first boot with no data." >&2
      exit 1
    fi
  fi
  echo "→ deploy: backup gate OK ($(basename "$(freshest_dump)"))"
fi

# --- 2. pin the tag ----------------------------------------------------------
# Rewritten through a temp file, not `sed -i` (GNU and BSD sed disagree on its argument).
pin_env_line() {
  var="$1"; value="$2"
  touch "$ENV_FILE"
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  { grep -vE "^${var}=" "$ENV_FILE" || true; echo "${var}=${value}"; } > "$tmp"
  mv "$tmp" "$ENV_FILE"
}
pin_env_line "$TAG_VAR" "$SHA"

# --- 2b. first boot: seed missing sibling tags (first-deploy lessons, 2026-07) --
# The prod compose `:?`-guards EVERY deployable tag, so interpolation fails on a fresh host
# until each has deployed once. Seed the missing siblings with a sentinel: compose can then
# interpolate, `up -d $SERVICE` never starts a sibling, and the full-SHA guard above refuses
# the sentinel if someone tries to promote it.
grep -oE '\$\{[A-Z][A-Z0-9_]*_TAG:\?' "$DEPLOY_DIR/docker-compose.prod.yml" \
| sed 's/^..//; s/:?$//' | sort -u \
| while read -r var; do
  [ "$var" = "$TAG_VAR" ] && continue
  grep -qE "^${var}=" "$ENV_FILE" || echo "${var}=bootstrap-pending" >> "$ENV_FILE"
done

# --- 2c. archive the outgoing container's log BEFORE the recreate (DE-007) ----
LOG_ARCHIVE_DIR="${LOG_ARCHIVE_DIR:-/srv/trades/log-archive}"
LOG_ARCHIVE_RETENTION_DAYS="${LOG_ARCHIVE_RETENTION_DAYS:-14}"
# The prune is expressed in MINUTES: `find -mtime +N` truncates the age to whole days and
# matches only ages strictly greater than N, i.e. at least N+1 days — a "14-day" prune on
# `-mtime +14` kept archives aged 14d02h and 14d20h (rehearsal, AC-24). `-mmin +20160` removes
# anything older than 14 days to the minute. The RUNBOOK.md host cron uses the same expression.
LOG_ARCHIVE_RETENTION_MINUTES=$((LOG_ARCHIVE_RETENTION_DAYS * 1440))

# Redact the request-line channels a log-format fix cannot reach (nginx's error log, an
# unconfigured `combined` access log). Anchored on shapes THIS stack emits, cut to END OF
# LINE (a boundary the adversary cannot manufacture), `LC_ALL=C` pinned (a UTF-8 locale makes
# GNU sed stop a character class at an invalid byte and silently leave the tail unredacted).
# SCOPE: a backstop over these two shapes, NOT a general scrubber — an application JSON line,
# an SDK error interpolating a URL, or a secret in a PATH segment pass through unchanged;
# those are redacted at their source (LO-001/LO-007/LO-008/LO-009). Pinned by
# ai-standards/tests/deploy/test-log-redaction.sh.
redact_request_lines() {
  LC_ALL=C sed -e 's/\(request: "[^?]*\)?.*$/\1?[REDACTED]/' \
                -e 's/\(\] "[^?]*\)?.*$/\1?[REDACTED]/'
}

archive_service_logs() {
  svc="$1"
  if ! mkdir -p "$LOG_ARCHIVE_DIR" 2>/dev/null; then
    echo "⚠ deploy: cannot create $LOG_ARCHIVE_DIR — skipping the pre-recreate log archive (the promotion continues)" >&2
    return 0
  fi
  if ! { : > "$LOG_ARCHIVE_DIR/.write-probe"; } 2>/dev/null; then
    echo "⚠ deploy: $LOG_ARCHIVE_DIR exists but is NOT WRITABLE — skipping the pre-recreate log archive (the promotion continues); fix the directory's owner/mode" >&2
    return 0
  fi
  rm -f "$LOG_ARCHIVE_DIR/.write-probe"

  # `ps -aq`, NEVER `ps -q`: a container an operator stopped mid-triage is the log worth keeping.
  cids="$("${COMPOSE[@]}" ps -aq "$svc" 2>/dev/null || true)"
  if [ -z "$cids" ]; then
    echo "→ deploy: no existing $svc container to archive (first boot?)"
    return 0
  fi

  archived=0
  for cid in $cids; do
    short="$(printf '%.12s' "$cid")"
    out="$LOG_ARCHIVE_DIR/${svc}-$(date -u +%Y%m%dT%H%M%SZ)-${short}.log.gz"
    { docker logs "$cid" 2>&1 | redact_request_lines | gzip -c > "$out"; } || true
    # gzip of an empty stream is still a ~20-byte file: probe the DECOMPRESSED stream.
    if [ ! -s "$out" ] || [ "$(gzip -cd "$out" 2>/dev/null | head -c1 | wc -c | tr -d ' ')" = "0" ]; then
      rm -f "$out"
      echo "⚠ deploy: $svc container $short — NOTHING ARCHIVED (empty capture). Check 'docker logs $short | head' before concluding the container wrote nothing" >&2
    else
      echo "→ deploy: archived $(basename "$out") ($(wc -c < "$out" | tr -d ' ') bytes gz)"
      archived=$((archived + 1))
    fi
  done
  [ "$archived" -gt 0 ] || echo "⚠ deploy: pre-recreate log archive wrote nothing for $svc" >&2

  # Retention prune (BR-31, GD-021): this archive holds personal data, and a declared
  # retention nothing enforces is evidence against you. Runs only when a service is promoted —
  # ALSO install it as a host cron beside the nightly backup (RUNBOOK.md § "Log archive").
  # `|| true` on the COUNT pipeline too: hygiene never fails a promotion.
  pruned="$(find "$LOG_ARCHIVE_DIR" -maxdepth 1 -name '*.log.gz' -mmin "+${LOG_ARCHIVE_RETENTION_MINUTES}" 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [ "${pruned:-0}" -gt 0 ] 2>/dev/null; then
    if find "$LOG_ARCHIVE_DIR" -maxdepth 1 -name '*.log.gz' -mmin "+${LOG_ARCHIVE_RETENTION_MINUTES}" -delete 2>/dev/null; then
      echo "→ deploy: pruned up to $pruned archived log(s) older than ${LOG_ARCHIVE_RETENTION_DAYS}d"
    else
      echo "⚠ deploy: retention prune FAILED in $LOG_ARCHIVE_DIR — up to $pruned file(s) past the ${LOG_ARCHIVE_RETENTION_DAYS}d window are still on disk (the promotion continues)" >&2
    fi
  fi
  return 0
}

archive_service_logs "$SERVICE"
if [ "$SERVICE" = "app" ]; then
  for w in worker-default worker-heavy worker-scheduler; do archive_service_logs "$w"; done
fi

# --- 3. promote --------------------------------------------------------------
if [ "${SKIP_PULL:-0}" = "1" ]; then
  echo "→ deploy: PULL SKIPPED (SKIP_PULL=1) — promoting a locally-built image; acceptable only in the rehearsal"
else
  "${COMPOSE[@]}" pull "$SERVICE"
fi
"${COMPOSE[@]}" up -d "$SERVICE"

# Gate a service on its DOCKER healthcheck (used by 3a and 4b). `docker inspect` on the
# container id, until `healthy` or the budget runs out — then the last 50 log lines and exit 1.
gate_healthy() {
  svc="$1"; budget="${2:-150}"
  cid="$("${COMPOSE[@]}" ps -q "$svc")"
  [ -n "$cid" ] || { echo "✗ deploy: $svc has no container after up -d" >&2; return 1; }
  wdeadline=$(( $(date +%s) + budget ))
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null)" = healthy ]; do
    if [ "$(date +%s)" -ge "$wdeadline" ]; then
      echo "✗ deploy: $svc not healthy after ${budget}s ($(docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' "$cid" 2>/dev/null))" >&2
      "${COMPOSE[@]}" logs --tail 50 "$svc" >&2 || true
      return 1
    fi
    sleep 5
  done
  echo "→ deploy: $svc healthy"
}

# --- 3a. the runtime set nothing depends on: the perimeter and the hub ------------
# `depends_on` brings postgres up with `app` and storage/storage-init/clamav up with `media`,
# but NO service depends on `caddy` or `mercure` — so a first boot or a host rebuild that only
# ran this script left the hub down (502 on api.{DOMAIN}/.well-known/mercure, rehearsal AC-23)
# and, in production, no perimeter at all. `--no-recreate` is the whole contract: start them
# when absent or stopped, NEVER touch a running one — a Caddyfile or mercure.env change is the
# explicit DE-004 / rotation lane (`up -d caddy`; RUNBOOK.md § "Rotate a secret"), not a side
# effect of promoting a service. `caddy` is gated on every promotion (step 5's smoke goes
# through it); `mercure` is gated with `app` (its keys are app.env's twins, its host is api.).
"${COMPOSE[@]}" up -d --no-recreate caddy mercure
gate_healthy caddy 90 || { echo "✗ deploy: the perimeter is not healthy — nothing behind it is reachable; investigate before retrying" >&2; exit 1; }
if [ "$SERVICE" = "app" ]; then
  gate_healthy mercure 90 || { echo "✗ rollback with: ./deploy.sh app ${PREVIOUS:-<no previous tag>}" >&2; exit 1; }
fi

# --- 4. readiness gate -----------------------------------------------------------
# Probe 127.0.0.1, NEVER localhost. The probe execs the binary the image ships.
readiness_probe() {
  case "$1" in
    app)   "${COMPOSE[@]}" exec -T app   curl -fsS http://127.0.0.1:8000/api/health ;;
    media) "${COMPOSE[@]}" exec -T media curl -fsS http://127.0.0.1:8008/api/health ;;
    web)   "${COMPOSE[@]}" exec -T web   wget -qO- http://127.0.0.1:8080/ ;;
  esac
}
DEADLINE=$(( $(date +%s) + 120 ))
until readiness_probe "$SERVICE" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "✗ deploy: $SERVICE not ready after 120s — readiness gate FAILED." >&2
    "${COMPOSE[@]}" logs --tail 50 "$SERVICE" >&2 || true
    echo "✗ rollback with: ./deploy.sh $SERVICE ${PREVIOUS:-<no previous tag — investigate before retrying>}" >&2
    exit 1
  fi
  sleep 5
done
echo "→ deploy: $SERVICE readiness OK"

# --- 4a. the promoted container's DOCKER health state (the state everything else reads) ---
# The exec probe above proves the HTTP surface answers; it does not wait for Docker's own
# healthcheck, which has its own interval and had not run its first probe when the rehearsal
# harness read `running/starting` on a healthy `web` (rehearsal, D6). That state is what
# `compose ps`, the Rung-2 sentinel (host-sentinel.sh) and `rehearse.sh` verify — and for
# `media` the healthcheck is STRICTER than step 4 (`/api/health` AND both supervisord consumers
# RUNNING), so returning on the exec probe alone could ship a media image whose workers are
# down. The budget covers several healthcheck intervals (15 s) after a readiness that already
# passed; `starting` past it is a failure, exactly like `unhealthy`.
gate_healthy "$SERVICE" 90 || { echo "✗ rollback with: ./deploy.sh $SERVICE ${PREVIOUS:-<no previous tag — investigate before retrying>}" >&2; exit 1; }

# --- 4b. the three workers ride app's tag — recreate and GATE them (DE-003) ------
if [ "$SERVICE" = "app" ]; then
  "${COMPOSE[@]}" up -d worker-default worker-heavy worker-scheduler
  for w in worker-default worker-heavy worker-scheduler; do
    gate_healthy "$w" 240 || { echo "✗ rollback with: ./deploy.sh app ${PREVIOUS:-<no previous tag>}" >&2; exit 1; }
  done
fi

# --- 5. smoke check through the real perimeter --------------------------------
# SMOKE_CURL_EXTRA_ARGS: word-split on purpose (the rehearsal passes `--resolve` entries).
# shellcheck disable=SC2206
CURL_EXTRA=(${SMOKE_CURL_EXTRA_ARGS:-})
smoke() {
  url="$1"
  curl -fsS -o /dev/null --max-time 15 ${CURL_EXTRA[@]+"${CURL_EXTRA[@]}"} "$url" \
    || { echo "✗ deploy: smoke check failed: $url" >&2; exit 1; }
  echo "→ deploy: smoke OK $url"
}
case "$SERVICE" in
  app)   smoke "https://api.${DOMAIN}${PORT_SUFFIX}/api/health" ;;
  media) smoke "https://media.${DOMAIN}${PORT_SUFFIX}/api/health" ;;
  web)   smoke "https://app.${DOMAIN}${PORT_SUFFIX}/" ;;
esac

# --- 5b. route-map canary (DE-002) — the NEWEST surface must RESOLVE, never 404 -------
# /api/health survives a stale route map; this does not. Protected route → 401 expected
# (a 404-vs-401 flip is unambiguous). Update the path as the newest surface moves
# (today: the versioned SchoolLink contract, ADR-119).
CANARY_PATH="${SMOKE_CANARY_PATH:-/api/v1/school-link/training-needs}"
CANARY_EXPECT="${SMOKE_CANARY_EXPECT:-401}"
if [ "$SERVICE" = "app" ] && [ -n "$CANARY_PATH" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 ${CURL_EXTRA[@]+"${CURL_EXTRA[@]}"} "https://api.${DOMAIN}${PORT_SUFFIX}${CANARY_PATH}") || code=000
  if [ "$code" = 404 ]; then
    echo "✗ deploy: $CANARY_PATH is 404 — STALE/incomplete route map (cache not rebuilt on deploy)" >&2
    echo "✗ rollback with: ./deploy.sh $SERVICE ${PREVIOUS:-<no previous tag — investigate before retrying>}" >&2
    exit 1
  fi
  case " $CANARY_EXPECT " in
    *" $code "*) echo "→ deploy: route map current ($CANARY_PATH → $code)" ;;
    *) echo "✗ deploy: canary $CANARY_PATH → HTTP $code, expected [$CANARY_EXPECT] (SMOKE_CANARY_EXPECT)" >&2; exit 1 ;;
  esac
fi

# --- 6. image prune (IA-011) — disk hygiene after a successful promotion ------
docker image prune -af --filter "until=168h" >/dev/null 2>&1 || true
echo "→ deploy: pruned images unused for 7+ days"

echo "✓ deploy: $SERVICE is on $SHA"
