# Trades — production runbook

One page for the 3am incident: how to reach, triage, roll back and restore. Every section is a
quick reference **pointing at the canonical standard** (`ai-standards/standards/deployment.md`,
`infrastructure.md`); it never restates rules. Adapted from
`ai-standards/templates/deploy/RUNBOOK.md.template` by production-packaging-promotion-lane
(10.4). The `{placeholders}` are filled at the first deploy (10.6;
`first-deploy-checklist.md` gates on them) and kept current: a runbook with a stale instance-id
is worse than none.

The break-glass **code** lane is `ai-standards/.claude/rules/quick-fix-baseline.md` § 6 — this
file is its ops counterpart; a break-glass fix and this runbook cite each other in the incident
record (`trades-docs/lessons-learned/`).

## The runtime set (what `docker compose -f docker-compose.prod.yml ps` must show)

| Service | Image | Role | Healthy means |
|---|---|---|---|
| `caddy` | `caddy:2.11` (digest-pinned) | the perimeter: TLS, one hostname per deployable (`app.` `api.` `media.` `storage.`), the request log | admin API answers on loopback |
| `app` | `ghcr.io/silfaran-trades/trades-backend:{APP_TAG}` | trades-backend HTTP (php-fpm + nginx); **the one container that runs migrations** | `GET /api/health` (database probe) |
| `worker-default` | same image, same tag | `messenger:consume async_default` | `php` is PID 1 |
| `worker-heavy` | same image, same tag | `messenger:consume async_heavy` | `php` is PID 1 |
| `worker-scheduler` | same image, same tag | the nine `schedule://` transports — `default`, `contracts`, `labor`, `serviceorders`, `company`, `profile`, `demand`, `telemetry`, `audit` — carrying the **eighteen** registered jobs of `trades-docs/scheduled-jobs.md` (re-count there when a bundle adds one) | `php` is PID 1 |
| `mercure` | `dunglas/mercure:v0.16` | Chat's SSE hub, served at `api.{domain}/.well-known/mercure` | `/healthz` |
| `media` | `ghcr.io/silfaran-trades/media-service:{MEDIA_TAG}` | media-service HTTP + its `scan-worker` and `process-worker` under supervisord | `GET /api/health` (bucket probe) **and** both workers `RUNNING` |
| `clamav` | `clamav/clamav:1.5.2` | the antivirus daemon | `clamdscan --ping` |
| `storage` (+ `storage-init`) | MinIO (ADR-021 open) | the object store; public endpoint `storage.{domain}` | `/minio/health/live`; `storage-init` exited 0 |
| `postgres` | `imresamu/postgis:18-3.6` | one instance: `trades_app` (one schema per bundle) + `media` | `pg_isready` |
| `web` | `ghcr.io/silfaran-trades/trades-front:{WEB_TAG}` | the SPA (static, unprivileged nginx) | `GET /` |

Three tags, not four: the workers **ride `APP_TAG`** and never carry their own — `deploy.sh app`
recreates and gates them after the app. Every service runs a read-only root filesystem with
tmpfs where it writes (BR-4); every deployable runs non-root.

**Nothing depends on `caddy` or `mercure`**, so `depends_on` never starts them: every
`deploy.sh` run ensures both with `up -d --no-recreate` (started when absent or stopped, never
touched when running) and gates `caddy` on its healthcheck — `mercure` too when promoting `app`.
After a first boot or a host rebuild, `docker compose -f docker-compose.prod.yml ps` must list
**every** row of the table above (`storage-init` as exited 0); the rehearsal harness checks
exactly that, because a service no deployable depends on is what a one-service-at-a-time
promotion silently leaves out.

## Reach the host

```bash
# keyless lane (IA-009) — filled at 10.6:
aws ssm start-session --target {instance-id} --region {region}
sudo -iu deploy
cd /srv/trades/deploy
```

Host layout: `/srv/trades/deploy` (this directory, re-synced from the repo — CD promotes images,
not config, DE-004), `/srv/trades/secrets/{app,media,mercure,postgres,storage}.env` +
`/srv/trades/secrets/files/` (chmod 600, never in git), `/srv/trades/backups`,
`/srv/trades/log-archive`, `/srv/trades/deploy.lock` (the promotion lock — a directory).

## Triage a down / degraded service

```bash
docker compose -f docker-compose.prod.yml ps                 # who is unhealthy/restarting?
docker compose -f docker-compose.prod.yml logs --tail 100 {service}
docker compose -f docker-compose.prod.yml exec app curl -s http://127.0.0.1:8000/api/health
docker compose -f docker-compose.prod.yml exec media supervisorctl -c /etc/supervisor/conf.d/supervisord.conf status
df -h / && docker system df                                   # disk full? (deploy.sh warns at 80%)
```

**A worker "silent" (jobs not processed, chat not delivered, mails not sent)?** Check its health —
a crash-looping worker keeps `/api/health` green (DE-003). The three usual causes, in order: its
own `cache:warmup` failed at boot (`logs --tail 50 worker-…`), the scheduler's transport list drifted
from `trades-backend/docker-compose.yml` (the two lists must be equal), a flag flip applied with
`restart` instead of a recreate (below).

**`caddy:2.11` is a deliberate minor pin, and bumping it is yours to do.** The Caddyfile's
request-log block relies on version-dependent options (`roll_interval`, `ip_mask`); re-run the
checks in `deployment.md` § "Editing deploy config is not a deploy (DE-004)" on every bump.

**`logs` only shows the CURRENT container.** Every promotion REPLACES the container and takes
its log with it (DE-007). The two lanes that reach further back:

```bash
# 1. The perimeter's request log — a FILE on the caddy-logs volume; rolled daily, kept 14 days.
docker compose -f docker-compose.prod.yml exec caddy sh -c 'ls -l /var/log/caddy/; tail -n 100 /var/log/caddy/access.log'

# 2. Everything that only writes stdout (the app, the workers, media, the hub): deploy.sh
#    archives each outgoing container's output immediately BEFORE its recreate, redacted, gzipped,
#    kept 14 days (BR-31).
ls -lt ${LOG_ARCHIVE_DIR:-/srv/trades/log-archive} | head
gzip -cd ${LOG_ARCHIVE_DIR:-/srv/trades/log-archive}/{service}-*.log.gz | less
```

**What these logs do and do not contain.** The perimeter log (lane 1) is safe *by construction*:
query strings, bodies and headers dropped before writing, on both the access and the error
channel (LO-009), client IP pseudonymised to `/24` · `/48` (GD-005) — expect a network, not a
host. The in-image nginx of `app`, `media` and `web` writes the same shape (`lo009`). The
**archive** (lane 2) is weaker: a *backstop* that redacts the request-line shapes it knows
(nginx's error log, a `combined` access line) and passes everything else through. During a
credential-leak investigation **do search the archive** — an application log line, an SDK error
that interpolated a URL, or a secret in a *path* segment will be present verbatim.

## Log archive retention — the host cron beside the backup

`deploy.sh` prunes `/srv/trades/log-archive` past 14 days **only when something is promoted**. A
host that stops deploying stops pruning, and the 14-day row in `pii-inventory.md` is a
compliance commitment — so 10.6's user-data ALSO installs it as a cron next to the backup:

```
15 3 * * * deploy find /srv/trades/log-archive -maxdepth 1 -name '*.log.gz' -mmin +20160 -delete
```

The window is in **minutes** (14 × 1440), the same expression `deploy.sh` and `backup-postgres.sh`
use: `find -mtime +14` truncates the age to whole days and matches only *more than* 14, so it is a
15-day prune — the rehearsal caught archives aged 14d02h surviving it.

## Roll back a bad deploy — the one-liner

```bash
./deploy.sh {app|media|web} <previous-sha>
```

The previous SHA is **in the deploy log** (`deploy.sh` prints `old → new` on every promotion;
the CD run log has it too). Code rolls back, schemas roll forward — never write a down
migration (`deployment.md` § Rollback, `data-migrations.md` § "Rollback posture"). Rolling back
`app` rolls the three workers back with it.

## Promote (merge-as-promotion, ADR-121)

`master` is always deployable; merging the PR IS the sign-off. Until 10.6 wires the deploy half
of the pipeline there is no deploy job, so a merge builds and publishes an image
(`.github/workflows/build-image.yml` in each code repo) and promotes nothing; the promotion is
`./deploy.sh {service} <sha>` on the host. **While GitHub Actions is not executing (B-6) the
local full-repository gate is the verification of record, and every PR says so.**

Order for a multi-service release: `app` (migrations run here; its workers follow
automatically), then `media`, then `web`. `deploy.sh` refuses to `up -d` `app` or `media` without
a dump newer than `BACKUP_MAX_AGE_MINUTES` (DE-005) and takes one inline when it can.

## Feature flags — a flip is a RECREATE, never a restart

The five `MODULE_*_ENABLED` flags and `DEMAND_AI_WRITTEN_PARSE_ENABLED` live in
`/srv/trades/secrets/app.env` and are resolved when the Symfony container is **compiled**, i.e.
at container start (`trades-docs/feature-flags.md`, ADR-100/ADR-107). The app and the
scheduler worker MUST resolve identical values (a scheduler seeing different flags than the
app is a split-brain), so a flip is:

```bash
$EDITOR /srv/trades/secrets/app.env          # flip the value
docker compose -f docker-compose.prod.yml up -d --force-recreate app worker-scheduler
```

`restart` reuses the old environment and changes nothing — silently.

## Rotate a secret

Every secret is a row in `trades-docs/secrets-manifest.md`; the mechanics per shape:

| Secret | Where | How |
|---|---|---|
| any `app.env` / `media.env` value (`APP_SECRET`, `DATABASE_URL`, provider keys, the `*_ENCRYPTION_KEY`s, `*_PSEUDONYM_KEY`s) | the env file | edit, then `up -d --force-recreate` the services that read it (`app` + the three workers; `media`). Data-at-rest keys need the two-key window of `secrets.md` — never rotate one without the re-encryption path |
| JWT key pair (`JWT_SECRET_KEY` / `JWT_PUBLIC_KEY`, `JWT_PASSPHRASE`) | `/srv/trades/secrets/files/` (mounted read-only at `/run/secrets/files/`) | two-key window (`secrets.md` § Key material): the new PUBLIC key reaches `media` (a verifier) BEFORE the app signs with the new private key; 15-minute grace (`JWT_TTL`) |
| Mercure keys (`MERCURE_JWT_SECRET` ≡ `MERCURE_PUBLISHER_JWT_KEY`, `MERCURE_SUBSCRIBER_JWT_KEY`) | `app.env` AND `mercure.env` — same value in both files | change both, recreate `app`, the workers and `mercure` together; a mismatch is silent (publishes answer 401 and are only logged) |
| Postgres password | `postgres.env` + `DATABASE_URL` in `app.env` and `media.env` | `ALTER USER` first, then the two URLs, then recreate |
| MinIO root credentials | `storage.env` + `MEDIA_STORAGE_DSN` in `media.env` | rotate in MinIO, then the DSN, then recreate `media` |
| the backup `age` key pair | recipient in `/srv/trades/secrets/backup-age.recipient`; the identity OFF-HOST at `{age-key-location}` | generate a new pair, update the recipient, keep the OLD identity until every dump encrypted with it has aged out (14 days) |
| the host's read-only GHCR pull token | `docker login ghcr.io` on the host | re-login with the new token; nothing else changes |

## Restore the database

Bad migration / data corruption — the dump taken by the DE-005 gate right before the promotion
is the restore point:

1. Drill-tested procedure: `./restore-drill.sh /path/to/age-key.txt` restores the newest dump of
   `trades_app` and `media` into a scratch database and reads every schema — verify there first,
   then restore into the real database the same way (drop the real target only on a deliberate,
   spelled-out decision; `deploy.sh` and every worker stopped first).
2. The age private key is **off-host by design** — fetch it from `{age-key-location}`.
3. Posture and sequencing: `deployment.md` § "Backups and the restore drill" +
   `data-migrations.md` § "Rollback posture".

## Personal data — what the deploy surface holds and for how long

Three stores outside the database (`trades-docs/pii-inventory.md`): the perimeter request log
(pseudonymised IP, 14 days by Caddy's time-based roll), the nightly dumps (every inventoried field,
encrypted, 14 days local and off-host) and the pre-recreate log archive (14 days, pruned by
`deploy.sh` and the cron above). **An erasure request is fully effective at most 14 days after
the last dump and the last archived log taken before it.** A breach in any of them starts the
72-hour clock of `gdpr-pii.md` § "Personal-data breach response" at awareness.

## The cookie rule that binds every future subdomain

`csrf_refresh` is scoped to the parent domain (`Domain={domain}`, BR-29) so the SPA on `app.`
can read what the API on `api.` sets. **No untrusted or third-party content may ever be served
from a sibling subdomain of the production domain** — such a host could read and overwrite that
cookie. `refresh_token` and `mercureAuthorization` stay host-only on `api.`.

## Rebuild the host (rebuild-not-repair, IA-009)

1. `terraform apply` in `environments/production` (10.6's IaC — user-data re-provisions the
   runtime, the `/srv/trades` layout, the backup + sentinel + archive-prune crons).
2. Clone this repo on the host, copy `deploy/` into `/srv/trades/deploy` (DE-004).
3. Materialise `/srv/trades/secrets/` from the parameter store (`fetch-secrets.sh`, 10.6).
4. Re-promote every deployable at its current SHA: `./deploy.sh app <sha>`, `media`, `web`
   (first boot only: `SKIP_BACKUP_GATE=1`, legitimate only with an empty database). `app` also
   brings up and gates the perimeter and the hub; then confirm the whole runtime set is up
   (`ps` — every row of the table above).
5. Restore the database from the newest dump (section above).

## Certificates / ACME

Caddy renews automatically; renewal breaks silently if port 80 is blocked or DNS moved. **Never
delete the `caddy-data` volume casually** — it holds the certs, and re-issuance is rate-limited.
Check: `docker compose -f docker-compose.prod.yml logs caddy | grep -i acme`. The Rung-0 uptime
check validates TLS (DE-006), so expiry warns before users see it.

## DLQ — failed async messages

Depth > 0 sustained is an incident (`backend.md` § DLQ). The dead-letter queue is `failed` in
`shared.messenger_messages`; **never** run `messenger:consume failed` (it shreds the queue —
`trades-backend/CLAUDE.md`):

```bash
docker compose -f docker-compose.prod.yml exec app php bin/console messenger:failed:show
docker compose -f docker-compose.prod.yml exec app php bin/console messenger:failed:show {id} -vv
docker compose -f docker-compose.prod.yml exec app php bin/console messenger:failed:retry {id}   # once, after the fix is deployed
```

`media` has its own `failed` queue in the `media` database (`exec media php bin/console
messenger:failed:show`).

## Severity quick-reference (declared by the standards)

| Signal | Severity | Canonical source |
|---|---|---|
| `audit_write_failures_total` > 0 — actions landing without trail | SEV-2 | `audit-log.md` § Observability |
| Ledger divergence (payments reconciliation) | SEV-2 | `payments-and-money.md` § Reconciliation |
| DLQ depth > 0 sustained | incident | `backend.md` § DLQ |
| A worker `unhealthy`/`restarting` between promotions | incident | `deployment.md` DE-003, DE-006 rung 2 |

## Fill-in values (first-deploy checklist gates on these — 10.6)

| Placeholder | Value |
|---|---|
| `{domain}` / `DOMAIN` in `deploy/.env` | _10.6's decision_ |
| `{instance-id}` | _from the production apply output_ |
| `{region}` | _the declared region_ |
| `{age-key-location}` | _where the off-host age private key lives_ |
| `RCLONE_REMOTE` (off-host backup copy) | _10.6_ |
| Uptime pinger dashboard | _URL_ |
| Alert inbox (SNS/budget/anomaly) + `NOTIFY_CMD` for the sentinel | _address_ |
