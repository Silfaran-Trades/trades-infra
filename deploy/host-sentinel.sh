#!/usr/bin/env bash
#
# Trades — host sentinel: monitoring-ladder Rung 2 (DE-006), the failures the outside cannot
# see. Adapted from ai-standards/templates/deploy/host-sentinel.sh.template.
# Authoritative rules: ai-standards/standards/deployment.md § "Production observability".
#
# Schedule: /etc/cron.d/trades-sentinel, every 10 minutes — PROVISIONED by the host's user-data
#           (terraform/modules/single-host/user-data.sh.tpl, IA-011), which also provides the
#           two commands below as files: NOTIFY_CMD=/srv/trades/sentinel-notify.sh (publishes
#           to this project's SNS host-alerts topic, BR-30a) and
#           DLQ_DEPTH_CMD=/srv/trades/sentinel-dlq-depth.sh. Rung 2 is recorded in
#           workspace.md `environments:` ("Rung 2: external pinger + host alarms + host sentinel").
#
# ALERT-ONLY by design: it notifies, it never restarts/fixes anything.
#
# Inputs (env):
#   NOTIFY_CMD      REQUIRED — how an alert leaves the host; reads the message on stdin, e.g.
#                     curl -fsS -X POST -H 'Content-Type: text/plain' --data-binary @- "$WEBHOOK_URL"
#   DLQ_DEPTH_CMD   optional — prints the failure-transport depth as a bare integer. The app's
#                   Messenger table is `shared.messenger_messages` (config/packages/messenger.yaml)
#                   and the dead-letter queue is `failed`:
#                     docker exec trades-prod-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -d trades_app -tAc "SELECT count(*) FROM shared.messenger_messages WHERE queue_name='"'"'failed'"'"'"'
#   BACKUP_DIR      default /srv/trades/backups
#   DISK_ALERT_PERCENT  default 85 — root filesystem usage at or above it is a problem (the
#                   disk check of 10.6: no CloudWatch agent is installed, so the only disk
#                   watcher is this one; deploy.sh's ≥80% pre-flight warns only at promotion)

set -euo pipefail

COMPOSE_PROJECT="${COMPOSE_PROJECT:-trades-prod}"
BACKUP_DIR="${BACKUP_DIR:-/srv/trades/backups}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
DLQ_DEPTH_CMD="${DLQ_DEPTH_CMD:-}"
DISK_ALERT_PERCENT="${DISK_ALERT_PERCENT:-85}"

PROBLEMS=()

# 1. Container health: anything unhealthy or restarting (= crash loop between deploys —
#    the deploy-time gates only watch during a promotion). The three workers, the media
#    container and the hub are exactly the processes whose failure keeps /api/health green.
BAD_CONTAINERS="$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
  --format '{{.Names}} {{.Status}}' | grep -Ei 'unhealthy|restarting' || true)"
[ -z "$BAD_CONTAINERS" ] || PROBLEMS+=("containers unhealthy/restarting:"$'\n'"$BAD_CONTAINERS")

# 2. DLQ depth (optional — backend.md § DLQ: depth > 0 sustained is an incident).
if [ -n "$DLQ_DEPTH_CMD" ]; then
  DEPTH="$(bash -c "$DLQ_DEPTH_CMD" 2>/dev/null || echo unreadable)"
  case "$DEPTH" in
    0) : ;;
    *) PROBLEMS+=("DLQ depth is ${DEPTH} (want 0) — drain per RUNBOOK.md § DLQ") ;;
  esac
fi

# 3. Backup freshness: the same 26h tripwire as deploy.sh (IA-011), firing between promotions.
if [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '*.dump.gz.age' -mmin -1560 2>/dev/null | head -1)" ]; then
  PROBLEMS+=("no backup dump newer than 26h in $BACKUP_DIR — nightly cron looks dead (check /var/log/trades-backup.log)")
fi

# 4. Root filesystem usage (10.6 — BR-30a): old images, local dumps and the log archive
#    co-located with Postgres, MinIO and the captured mail is the classic single-host
#    disk-full outage. `df -P` is POSIX (works on the Linux host and the macOS rehearsal).
DISK_USE="$(df -P / 2>/dev/null | awk 'NR==2 {print $5}' | tr -dc '0-9' || true)"
if [ -n "${DISK_USE:-}" ] && [ "$DISK_USE" -ge "$DISK_ALERT_PERCENT" ]; then
  PROBLEMS+=("root filesystem at ${DISK_USE}% (alert at ≥${DISK_ALERT_PERCENT}%) — docker system df; du -sh $BACKUP_DIR /srv/trades/log-archive; RUNBOOK.md § Triage")
fi

# Report — one message with everything wrong, silence when healthy.
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  MSG="[trades sentinel] $(date -u +%FT%TZ) — ${#PROBLEMS[@]} problem(s):"
  for p in "${PROBLEMS[@]}"; do MSG="$MSG"$'\n'"- $p"; done
  echo "$MSG" >&2
  if [ -n "$NOTIFY_CMD" ]; then
    printf '%s\n' "$MSG" | bash -c "$NOTIFY_CMD" \
      || echo "✗ sentinel: NOTIFY_CMD failed — alert did NOT leave the host" >&2
  else
    echo "✗ sentinel: NOTIFY_CMD unset — alert did NOT leave the host (see the header)" >&2
  fi
  exit 1
fi
