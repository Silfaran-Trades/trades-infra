# Trades — production runbook

One page for the 3am incident: how to reach, triage, roll back and restore — and, since 10.6,
the first-deploy sequence, the stage-1 perimeter and the lanes the developer runs from the Mac.
Every section is a quick reference **pointing at the canonical standard**
(`ai-standards/standards/deployment.md`, `infrastructure.md`, `first-deploy-checklist.md`); it
never restates rules. Adapted from `ai-standards/templates/deploy/RUNBOOK.md.template` by
production-packaging-promotion-lane (10.4) and filled by production-infrastructure-first-deploy
(10.6 — ADR-124 the stage-1 shape, ADR-125 manual promotion, ADR-126 object storage). The values
that only exist after the first `terraform apply` are the `terraform output` names given beside
them; a runbook with a stale instance id is worse than none, so they are read from the outputs
and from `trades-docs/workspace.md` `environments.production`, never copied here.

The break-glass **code** lane is `ai-standards/.claude/rules/quick-fix-baseline.md` § 6 — this
file is its ops counterpart; a break-glass fix and this runbook cite each other in the incident
record (`trades-docs/lessons-learned/`).

## The shared account — what is KHA's and what is ours

Production lives in the AWS account that also hosts **KHA Energy** (`eu-south-2`), as a
separate, isolated project (BR-1, BR-2). Everything of ours carries the `trades-` /
`trades/` / `/trades/production/` prefix: the VPC (10.81.0.0/24 — KHA's is 10.80.0.0/24), the
host, the roles, the registry repositories, the buckets, the parameters, the budget. The
permissions boundary every one of our principals carries (`trades-production-boundary`)
**denies** touching anything tagged or named `kha-energy` — by design, a mistake here cannot
reach KHA.

Two account-wide singletons are **KHA's and stay KHA's**: the `EstimatedCharges` billing alarm
and the Cost Explorer anomaly monitor (one per account). Both fire on our spend too, so anomaly
coverage is shared; our own guardrail is the **tag-filtered budget** (50 USD, taxes included,
`user:project$trades`, 50 / 80 / 100 % actual + 100 % forecast). KHA's side needs a change we
never make from here (raise its 12 USD threshold or filter its budget by tag) — listed as a
follow-up for KHA's own workspace (BR-9). Never create or import a second anomaly monitor.

Three named profiles, never a static key (SC-012): the owner's Identity Center session
(`AdministratorAccess` — the first apply and any later edit of the boundary itself), `trades-prod`
(assumes `trades-production-operator`: plan, apply, image push, promotion, host sync, restore
drill, promotion records) and `trades-agent` (assumes `trades-production-agent`: read-only, denied
every parameter outside `/trades/production/agent/*`, every SSM session and command, every
backup / state object read, every image pull). `kha-prod` is never used for this project.

```ini
# ~/.aws/config — written by the owner after the first apply (terraform output *_role_arn)
[profile trades-prod]
sso_session   = <the Identity Center session>
sso_account_id = <account id>
sso_role_name = AdministratorAccess
role_arn      = <operator_role_arn output>
source_profile = <the owner's SSO profile>
region        = eu-south-2

[profile trades-agent]
role_arn       = <agent_role_arn output>
source_profile = <the owner's SSO profile>
region         = eu-south-2
```

`AWS_PROFILE=trades-agent aws ssm get-parameter --name /trades/production/env/app` must answer
`AccessDenied` — that is the control working (AC-12).

## The runtime set (what `docker compose -f docker-compose.prod.yml ps` must show)

| Service | Image | Role | Healthy means |
|---|---|---|---|
| `caddy` | `caddy:2.11` (digest-pinned) | the perimeter: TLS (Let's Encrypt with the ZeroSSL fallback), one hostname per deployable (`app.` `api.` `media.` `storage.` `mail.`), basic auth on `app.` and `mail.`, the request log | admin API answers on loopback |
| `app` | `${REGISTRY}/trades/trades-backend:{APP_TAG}` | trades-backend HTTP (php-fpm + nginx); **the one container that runs migrations** | `GET /api/health` (database probe) |
| `worker-default` | same image, same tag | `messenger:consume async_default` | `php` is PID 1 |
| `worker-heavy` | same image, same tag | `messenger:consume async_heavy` | `php` is PID 1 |
| `worker-scheduler` | same image, same tag | the nine `schedule://` transports carrying the registered jobs of `trades-docs/scheduled-jobs.md` | `php` is PID 1 |
| `mercure` | `dunglas/mercure:v0.16` | Chat's SSE hub, served at `api.{domain}/.well-known/mercure` | `/healthz` |
| `media` | `${REGISTRY}/trades/media-service:{MEDIA_TAG}` | media-service HTTP + its `scan-worker` and `process-worker` under supervisord | `GET /api/health` (bucket probe) **and** both workers `RUNNING` |
| `clamav` | `clamav/clamav:1.5.2` | the antivirus daemon | `clamdscan --ping` |
| `storage` (+ `storage-init`) | `${REGISTRY}/trades/minio@sha256:…` / `…/mc@sha256:…` (ADR-126) | the object store (synthetic media only in stage 1); public endpoint `storage.{domain}` | `/minio/health/live`; `storage-init` exited 0 |
| `mailpit` | `axllent/mailpit:v1.31.2` | stage-1 mail capture: every message the platform sends, nothing leaves the host; viewer at `mail.{domain}` behind basic auth; bounded 500 messages / 14 days | `mailpit readyz` |
| `postgres` | `imresamu/postgis:18-3.6` | one instance: `trades_app` (one schema per bundle) + `media` | `pg_isready` |
| `web` | `${REGISTRY}/trades/trades-front:{WEB_TAG}` | the SPA (static, unprivileged nginx) | `GET /` |

Three tags, not four: the workers **ride `APP_TAG`** and never carry their own — `deploy.sh app`
recreates and gates them after the app. Every service runs a read-only root filesystem with
tmpfs where it writes; every deployable runs non-root.

**Nothing depends on `caddy`, `mercure` or `mailpit`**, so `depends_on` never starts them: every
`deploy.sh` run ensures the three with `up -d --no-recreate` (started when absent or stopped,
never touched when running) and gates `caddy` on its healthcheck — `mercure` and `mailpit` too
when promoting `app`. After a first boot or a host rebuild, `ps` must list **every** row of the
table above (`storage-init` as exited 0); the rehearsal harness checks exactly that.

## Reach the host

```bash
# keyless lane (IA-009, BR-6) — the operator profile; the agent profile is DENIED this
AWS_PROFILE=trades-prod aws ssm start-session --target "$(terraform -chdir=terraform/environments/production output -raw instance_id)" --region eu-south-2
sudo -iu deploy
cd /srv/trades/deploy
```

Host layout: `/srv/trades/deploy` (this directory, synced by `scripts/sync-host-deploy.sh` —
never a `git pull` on the host), `/srv/trades/secrets/{app,media,mercure,postgres,storage}.env`
(fetched by `/srv/trades/fetch-secrets.sh` from `/trades/production/env/*`) +
`/srv/trades/secrets/files/` (chmod 600, never in git), `/srv/trades/backups`,
`/srv/trades/log-archive` (the pre-recreate archive, `backup-gate-bypass.log`,
`promotions.log`), `/srv/trades/deploy.lock` (the promotion lock — a directory),
`/srv/trades/sentinel-notify.sh` + `sentinel-dlq-depth.sh` (the sentinel's commands),
`/etc/cron.d/trades-{backup,log-archive,sentinel}` (provisioned by user-data — never edit them on
the host; they are rewritten only on a host rebuild).

## The stage-1 perimeter — and its removal at 10.9

Until the 10.9 go-live production holds **synthetic data only** (ADR-124). The perimeter is:

- the base hostname `<eip-with-dashes>.sslip.io` (`terraform output public_hostname`) — no
  domain; `app.` `api.` `media.` `storage.` `mail.` hang off it and all resolve to the Elastic
  IP (confirm with `dig +short app.<base>` before consuming any output, BR-15);
- **basic auth on `app.` and `mail.`** with one shared operational credential (BR-18). `api.`,
  `media.` and `storage.` are exempt — HTTP Basic and the API's Bearer token share the
  `Authorization` header, so gating the API would break every SPA call and the login itself;
- `X-Robots-Tag: noindex` on every host;
- the security-header floor on the responses the proxy generates itself — the 401 challenge,
  a down upstream's 502 / 503 — as deferred defaults an upstream header always wins over
  (BR-20; ADR-120 amended). The floor is permanent posture.

**Removed together at 10.9, as one deliberate act** (BR-21): basic auth, `noindex` and the
sslip.io hostname (the real domain arrives with the `dns` module and a `DOMAIN` edit). The floor
stays.

### The basic-auth credential (BR-19)

The username and the password **hash** live only in the host's `deploy/.env`
(`BASIC_AUTH_USER`, `BASIC_AUTH_HASH`); the password itself is the SSM SecureString
`/trades/production/operator/web-login` (user + password; host and agent are denied the
`operator/` path) and is handed to the partner out of band. **Forgot it?** From `trades-infra/`:
`make web-login`. The backup restore identity sits beside it, `/trades/production/operator/backup-age-key`. Generate the hash in the pinned image, and
**single-quote it**: Compose interpolates an unquoted `$` and silently corrupts a bcrypt hash.

```bash
docker run --rm caddy:2.11@sha256:0c994536bddb66445885237f1a5dcc1916bccea922661c76b4e9fc24061f9b52 caddy hash-password
# deploy/.env:   BASIC_AUTH_HASH='$2a$14$…'
cd /srv/trades/deploy && docker compose -f docker-compose.prod.yml config 2>&1 | grep -E 'BASIC_AUTH_HASH|variable is not set'
# EXPECT the full hash (compose's canonical output doubles the $ signs — that display is
# correct) and ZERO "variable is not set" warnings — before the first start.
```

Rotate: replace the hash in `deploy/.env`, then `docker compose up -d caddy` (the value is a
compose `environment:` line — a recreate, not a restart; see the two lanes below).

### The two Caddy lanes (BR-26a)

| What changed | The command | Why |
|---|---|---|
| the **content** of `Caddyfile` (after a host sync) | `docker compose -f docker-compose.prod.yml restart caddy` | the file is bind-mounted; a restart re-reads it |
| Caddy's **compose definition** — a volume, a port, an `environment:` line (`DOMAIN`, `CADDY_TLS_ARG`, `BASIC_AUTH_*`) | `docker compose -f docker-compose.prod.yml up -d caddy` | a restart silently keeps the old mount set and the old environment |

A configuration `reload` is not a documented lane. Confirm a volume landed with
`docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$(docker compose -f docker-compose.prod.yml ps -q caddy)"`
(expect `trades-prod_caddy-logs` in the list).

## Certificates / ACME (BR-16)

Caddy obtains one certificate per hostname (five). **Every `sslip.io` certificate in the world
shares Let's Encrypt's rate limits** (`sslip.io` is not a public suffix), so issuance can be
refused through no fault of ours. The ACME e-mail in `CADDY_TLS_ARG` also enables Caddy's ZeroSSL
fallback — the first mitigation. When both fail: **wait out the window** (up to an hour for the
per-hostname limit), never loop restarts, never delete the `caddy-data` volume (it holds the
issued certificates; re-issuance is what is rate-limited). The real domain at 10.9 removes the
exposure. Check: `docker compose -f docker-compose.prod.yml logs caddy | grep -i acme`. The
external pinger validates TLS (DE-006 Rung 0), so expiry warns before users see it — **deferred
to 10.9** (spec AC-17): until then nothing outside the host watches certificate expiry.

## Triage a down / degraded service

```bash
docker compose -f docker-compose.prod.yml ps                 # who is unhealthy/restarting?
docker compose -f docker-compose.prod.yml logs --tail 100 {service}
docker compose -f docker-compose.prod.yml exec app curl -s http://127.0.0.1:8000/api/health
docker compose -f docker-compose.prod.yml exec media supervisorctl -c /etc/supervisor/conf.d/supervisord.conf status
df -h / && docker system df                                   # disk full? (the sentinel alerts at 85%, deploy.sh warns at 80%)
```

**A worker "silent" (jobs not processed, chat not delivered, mails not captured)?** Check its
health — a crash-looping worker keeps `/api/health` green (DE-003). The three usual causes, in
order: its own `cache:warmup` failed at boot (`logs --tail 50 worker-…`), the scheduler's transport
list drifted from `trades-backend/docker-compose.yml` (the two lists must be equal), a flag flip
applied with `restart` instead of a recreate (below).

**`caddy:2.11` is a deliberate minor pin, and bumping it is yours to do.** The Caddyfile's
request-log block relies on version-dependent options (`roll_interval`, `ip_mask`); re-run
`make caddy-adapt` and the checks in `deployment.md` § DE-004 on every bump.

**`logs` only shows the CURRENT container.** Every promotion REPLACES the container and takes
its log with it (DE-007). The two lanes that reach further back:

```bash
# 1. The perimeter's request log — a FILE on the caddy-logs volume; rolled daily, kept 14 days.
docker compose -f docker-compose.prod.yml exec caddy sh -c 'ls -l /var/log/caddy/; tail -n 100 /var/log/caddy/access.log'

# 2. Everything that only writes stdout (the app, the workers, media, the hub): deploy.sh
#    archives each outgoing container's output immediately BEFORE its recreate, redacted, gzipped,
#    kept 14 days. promote.sh's SSM output is appended to promotions.log as well.
ls -lt /srv/trades/log-archive | head
gzip -cd /srv/trades/log-archive/{service}-*.log.gz | less
```

**What these logs do and do not contain.** The perimeter log (lane 1) is safe *by construction*:
query strings, bodies and headers dropped before writing, on both the access and the error
channel (LO-009), client IP pseudonymised to `/24` · `/48` (GD-005) — expect a network, not a
host. The in-image nginx of `app`, `media` and `web` writes the same shape. The **archive**
(lane 2) is weaker: a *backstop* that redacts the request-line shapes it knows and passes
everything else through. During a credential-leak investigation **do search the archive**.

## Log archive retention — the host cron beside the backup

`deploy.sh` prunes `/srv/trades/log-archive` past 14 days **only when something is promoted**. A
host that stops deploying stops pruning, and the 14-day row in `pii-inventory.md` is a
compliance commitment — so the host's user-data ALSO installs it as `/etc/cron.d/trades-log-archive`:

```
15 3 * * * deploy find /srv/trades/log-archive -maxdepth 1 -name '*.log.gz' -mmin +20160 -delete
```

The window is in **minutes** (14 × 1440), the same expression `deploy.sh` and `backup-postgres.sh`
use: `find -mtime +14` truncates the age to whole days and matches only *more than* 14, so it is a
15-day prune — the rehearsal caught archives aged 14d02h surviving it.

## Promote — the manual, scripted act from the Mac (ADR-125)

```bash
AWS_PROFILE=trades-prod scripts/promote.sh {app|media|web} <full-40-char-sha>
```

`promote.sh` refuses before any build on a dirty tree, a `master` behind `origin/master`, a SHA
not on `master`, a short SHA, a red full `make quality`; builds linux/arm64 from `git archive`
(never the working copy), scans the image (HIGH / CRITICAL with a fix available blocks), pushes
to ECR (IMMUTABLE tags — a second push of an existing tag with different content is refused,
AC-10), runs the host's `deploy.sh` over SSM and writes a **promotion record**
(`promotions/<stamp>-<deployable>-<sha>.json` in the backups bucket: deployable, sha, previous
sha, times, outcome, lane, backup-gate verdict, the operator role without its session name).
There is no workflow run history: the record is the durable answer to "what is live". While
Actions is off, the local full-repository gate is the verification of record, and every PR says so.

Order for a multi-service release: `app` (migrations run here; its workers follow
automatically), then `media`, then `web`. The host's `deploy.sh` refuses to `up -d` `app` or
`media` without a dump newer than `BACKUP_MAX_AGE_MINUTES` (DE-005) and takes one inline when it
can (the inline dump is shipped off-host like the nightly one).

**The one legitimate backup-gate bypass** is the first `app` promotion on the empty database:
`scripts/promote.sh app <sha> --first-boot-skip-backup-gate` passes `SKIP_BACKUP_GATE=1` through
`sudo -u deploy env`; `deploy.sh` honours it **only** when `identity.users` is missing or empty,
refuses otherwise naming the count (AC-23), and logs every bypass to
`/srv/trades/log-archive/backup-gate-bypass.log`.

What this lane does **not** give, compared with a CI lane: no provenance or SBOM attestation,
arm64 only, no run history beyond the promotion record.

## Roll back a bad deploy — the one-liner

```bash
AWS_PROFILE=trades-prod scripts/promote.sh {app|media|web} <previous-sha>      # from the Mac
./deploy.sh {app|media|web} <previous-sha>                                      # or on the host
```

The previous SHA is in the promotion record and in the deploy log (`deploy.sh` prints
`old → new` on every promotion). A rollback SHA must already be in ECR (it was gated when first
promoted); `promote.sh` refuses to build an older SHA. Code rolls back, schemas roll forward —
never write a down migration. Rolling back `app` rolls the three workers back with it.

## Host sync — the deploy/ directory is synced deliberately (BR-26, DE-004)

```bash
AWS_PROFILE=trades-prod scripts/sync-host-deploy.sh [--dry-run]
```

From a clean `master` equal to `origin/master`: hashes every host file in scope, **stops** when a
host file matches no commit of this repository (a hand edit — commit it or discard it on the
host, then re-run), keeps `/srv/trades/deploy.bak-<ts>`, transfers the committed files, proves
every host hash equals the source commit and records it in `/srv/trades/deploy/.synced-commit`.
`deploy/.env` and `secrets/` are never touched. The sync restarts nothing: apply the matching
Caddy lane above afterwards, or promote.

## Feature flags — a flip is a RECREATE, never a restart

The `MODULE_*_ENABLED` flags and `DEMAND_AI_WRITTEN_PARSE_ENABLED` live in the `app` parameter
(`/trades/production/env/app`) and are resolved when the Symfony container is **compiled**, i.e.
at container start. The app and the scheduler worker MUST resolve identical values, so a flip is:
rewrite the parameter from a throwaway file, `fetch-secrets.sh` on the host, then
`docker compose -f docker-compose.prod.yml up -d --force-recreate app worker-scheduler`.
`restart` reuses the old environment and changes nothing — silently.

## Rotate a secret

Every secret is a row in `trades-docs/secrets-manifest.md`. Production values live in the
parameter store under `/trades/production/env/<service>` (one SecureString per env file, seeded
from local files that are deleted afterwards — never one value on a command line, BR-26b); the
host materialises them with `/srv/trades/fetch-secrets.sh`, and an env file is read at container
CREATE, so every rotation ends with a `--force-recreate` of the readers:

| Secret | Where | How |
|---|---|---|
| any `app` / `media` value (`APP_SECRET`, `DATABASE_URL`, the `*_ENCRYPTION_KEY`s, …) | the parameter → the env file | rewrite the parameter, `fetch-secrets.sh`, recreate `app` + the three workers / `media`. Data-at-rest keys need the two-key window of `secrets.md` |
| JWT key pair | `/srv/trades/secrets/files/` (mounted read-only at `/run/secrets/files/`) | two-key window (`secrets.md` § Key material): the new PUBLIC key reaches `media` BEFORE the app signs with the new private key |
| Mercure keys | the `app` AND `mercure` parameters — same value in both | change both, recreate `app`, the workers and `mercure` together; a mismatch is silent |
| Postgres password | the `postgres` parameter + `DATABASE_URL` in `app` and `media` | `ALTER USER` first, then the three parameters, then recreate |
| MinIO root credentials | the `storage` parameter + `MEDIA_STORAGE_DSN` in `media` | rotate in MinIO, then the parameters, then recreate `media` |
| the backup `age` key pair | recipient in `/srv/trades/secrets/backup-age.recipient`; the identity OFF-HOST in the SSM SecureString `/trades/production/operator/backup-age-key` | generate a new pair, update the recipient, keep the OLD identity until every dump encrypted with it has aged out (14 days) |
| the basic-auth credential | `deploy/.env` on the host (hash) + `/trades/production/operator/web-login` | `caddy hash-password`, single-quote it, `up -d caddy` (above) |
| `ai_readonly` (the agent role) | `/srv/trades/secrets/ai-readonly.env` + the `/trades/production/agent/database-url` parameter | re-run `agent-db/provision-agent-role.sh` with the new value, rewrite the parameter |
| `SYNTHETIC_SEED_PASSWORD` | `/srv/trades/secrets/synthetic-seed.env`, ONE run | not rotated: deleted after the run; the seeded accounts keep it until the 10.9 wipe |

The host holds **no registry token** (the instance profile pulls through the ECR credential
helper, BR-23) and no cloud key of any kind (TM-10).

## Backups, the off-host copy and the restore drill (BR-28, BR-30)

`/etc/cron.d/trades-backup` runs `backup-postgres.sh` at 03:15 UTC: one encrypted dump per
database, 14-day local retention, and each new file copied to
`s3://<backups_bucket>/postgres/` (`BACKUPS_BUCKET` in `deploy/.env`). The host can **only list
and put** there — never read, delete or touch versions: expiry is the bucket's lifecycle rule
(current 7 days + noncurrent 7 days, so an overwritten dump stays recoverable for 7 days and no
copy outlives 14). The script hard-stops without a bucket. Daily EBS snapshots (7 kept) are a
separate, crash-consistent machine copy — not the database backup.

```bash
# the drill, from the Mac, with the off-host age identity (never on the host):
AWS_PROFILE=trades-prod BACKUPS_BUCKET=<backups_bucket output> deploy/restore-drill.sh /path/to/backup-age.key
```

### Restore drill evidence (AC-16)

One drill is run against a real production dump fetched from the off-host copy before the
pilot, then quarterly. Record each drill's output line here:

| Date | Dump restored | Result |
|---|---|---|
| 2026-10-03 | `trades_app-20261003-070229` + `media-20261003-070229`, fetched from the off-host copy on the Mac (operator profile) | OK — every schema read (e.g. `audit.audit_log`=163, `company.companies`=4, `demand.candidacies`=16); first run failed on the `ai_readonly` GRANTs until `--no-privileges` |

## Restore the database

Bad migration / data corruption — the dump taken by the DE-005 gate right before the promotion
is the restore point:

1. Drill-tested procedure: `restore-drill.sh` restores the newest dump of `trades_app` and
   `media` into a scratch database and reads every schema — verify there first, then restore into
   the real database the same way — `pg_restore --no-owner --no-privileges` (drop the real
   target only on a deliberate, spelled-out decision; `deploy.sh` and every worker stopped first).
2. The age private key is **off-host by design** — the SSM SecureString
   `/trades/production/operator/backup-age-key` (host and agent denied the path).
3. Posture and sequencing: `deployment.md` § "Backups and the restore drill" +
   `data-migrations.md` § "Rollback posture". **A restore that rebuilds the Postgres volume loses
   the `ai_readonly` role and the `mask` schema** — re-run the agent-role lane afterwards.

## Monitoring — Rung 2 (DE-006, BR-30a)

Recorded in `trades-docs/workspace.md` `environments.production.monitoring`: "Rung 2: external
pinger + host alarms + host sentinel".

- **Rung 0 — the external pinger — DEFERRED to 10.9** (the developer, 2026-10-03; spec AC-17):
  stage 1 holds synthetic data for about a month, and Rungs 1–2 cover host death and unhealthy
  containers. The gap is an outside-in failure (an expired certificate, the network) on a host
  that otherwise looks healthy. Register it before the first real data. When registered
  (HUMAN, TLS-validating), it polls
  `https://api.<base>/api/health` and `https://media.<base>/api/health` from outside — the host
  cannot report its own death.
- **Rung 1 — the host alarms** (`terraform/modules/host-alarms`): `StatusCheckFailed` (two
  minutes, missing data breaching) and `CPUCreditBalance` below 30 for 15 minutes → the SNS topic
  `trades-production-host-alerts` → e-mail. **Confirm the subscription from the inbox after the
  apply** — a pending subscription delivers nothing.
- **Rung 2 — the host sentinel** (`/etc/cron.d/trades-sentinel`, every 10 minutes): unhealthy or
  restarting containers, DLQ depth, a stale backup, the root filesystem at ≥ 85 % — published to
  the same topic through `/srv/trades/sentinel-notify.sh`. Log: `/var/log/trades-sentinel.log`.

Disk is the sentinel's alone (no CloudWatch agent is installed).

## Synthetic data — the stage-1 lane (BR-31, BR-31a)

Production holds only the coherent demo dataset, loaded on the still-empty database by the
operator. The passwords are kept as SecureStrings under `/trades/production/operator/`
(`demo-users` — the synthetic accounts, `my-admin` — the owner's `platform_admin`; `make web-login`
prints them) and reach the host for ONE run only: staged under `/trades/production/env/`,
materialised by `fetch-secrets.sh` as mode-600 files, and deleted (files and staged parameters)
after the run. Writes to the parameter store are the developer's acts.

```bash
# Mac (operator profile): stage the run's passwords from their operator/ copies
#   /trades/production/env/synthetic-seed  → SYNTHETIC_SEED_PASSWORD=…  (from operator/demo-users)
#   /trades/production/env/owner-admin     → OWNER_ADMIN_PASSWORD=…     (from operator/my-admin)
# host, as deploy:
/srv/trades/fetch-secrets.sh
/srv/trades/deploy/seed-synthetic.sh --confirm-production-stage-1
# then the owner's platform_admin (BR-31a), password from owner-admin.env, never an argument
# you type: app:create-user <owner e-mail> "$OWNER_ADMIN_PASSWORD" platform_admin in a one-off app container
rm -f /srv/trades/secrets/synthetic-seed.env /srv/trades/secrets/owner-admin.env
# Mac: aws ssm delete-parameter for env/synthetic-seed and env/owner-admin
```

The lane refuses without the literal argument, refuses when `identity.users` is non-empty
(naming the count), reads the password only from that 600 file, runs the seven seed commands and
the two Phinx seeds of `make seed-dev` in its order through one-off containers of the production
`app` image (`SYNTHETIC_SEED_MODE=production-stage-1` — the only value the backend's guard
accepts under `APP_ENV=prod`), and prints the seeded e-mails and the record line. The validation
step uploads its photos exactly as media-service presigns them — a `PUT` to
`https://storage.<base>` — so the lane points the seed's in-network address at the perimeter
(`caddy`, whose `storage.` site terminates TLS and proxies to MinIO with the signed `Host` header
intact; MinIO itself listens on plain 9000). The seeded
accounts — the two synthetic `platform_admin` personas included — carry the per-run password,
never the one published in `test-users.md` (AC-22); the password is handed to the partner out of
band. **Then** the developer's own `platform_admin` is created with `app:create-user` (BR-31a),
and the agent-role lane below runs.

The seed leaves known noise in the DLQ (push without a device token, notifications to the journey
seed's fixed recipients — pending-items-log B-39). Diagnose with `messenger:failed:show` (§ DLQ)
and drain it only once every message is one of those known classes; anything else is a bug.

### Reload the dataset (stage 1 only — synthetic data)

A partial load (a step failed midway, and the lane now refuses to re-run) and a deliberate
replacement of the dataset take the same path. Used on 2026-10-04 to load the partner's taxonomy:

1. Host: stop `app` and the three workers; drop and recreate `trades_app` through the `postgres`
   container (pipe SQL over SSM base64-encoded — nested quotes break; and wrap any piped command in
   `bash -c 'set -o pipefail; …'`, because `AWS-RunShellScript` runs `dash`).
2. Mac: `make test-db-reset` in `trades-backend` FIRST (`promote.sh` runs `make quality` on the
   existing test database, and a polluted one refuses the promotion), then
   `scripts/promote.sh app <sha> --first-boot-skip-backup-gate` (accepted: the database is empty).
3. Re-stage the EXISTING passwords (`operator/demo-users`, `operator/my-admin`, and the
   `ai_readonly` password the agent DSN carries) into
   `/trades/production/env/{synthetic-seed,owner-admin,ai-readonly}` — the same values, so the
   partner's and the owner's logins and the agent DSN stay valid — and run `fetch-secrets.sh`.
4. `seed-synthetic.sh`, then the owner's `platform_admin`, then
   `agent-db/provision-agent-role.sh` (the masked views are rebuilt for the new database); then
   delete the staged files and the three staged parameters.
5. Drain the known DLQ noise (above) after checking every message's class.

### Synthetic-data record

| Date (UTC) | Record line printed by `seed-synthetic.sh` |
|---|---|
| 2026-10-03 | first load (Phase 7 step 10): 24 users, then the owner's `platform_admin`; a second run refused (`identity.users already holds 24 row(s)`) |
| 2026-10-04 | reload with the partner's taxonomy (pending-items-log B-40): 24 users, 20 trades, 83 microskills, 11 demands; 76 mask views; 40 DLQ messages of the known classes drained |

At 10.9 the synthetic data is wiped by a documented, evidenced step and this lane is deleted.

## The agent-role lane (IA-010, BR-27)

The only production database credential an AI-agent session may ever hold is `ai_readonly`:
read-only by construction, blind to every inventoried column by construction (the `mask` views
generated from `deploy/agent-db/mask-manifest.txt`, itself generated from
`trades-docs/pii-inventory.md`), revoked on every base schema — every grant made to `PUBLIC` on a
base relation withdrawn too, which is how PostGIS's `spatial_ref_sys` / `geometry_columns` /
`geography_columns` would otherwise leak through (the application connects as the bootstrap
superuser, which no ACL binds) — fail-closed for any table without
an inventory row, no `CONNECT` on `media`, connection-limited, statement-timed-out, every
statement logged; the role SQL aborts itself if any base relation is still readable. Provisioned on the host by the operator **after the first `app` promotion and
after every later migration or inventory change**:

```bash
sudo -iu deploy
# Mac: stage AI_READONLY_PASSWORD=… as /trades/production/env/ai-readonly (a new value only on
# the first run or a rotation; otherwise the value the DSN /trades/production/agent/database-url carries)
/srv/trades/fetch-secrets.sh
/srv/trades/deploy/agent-db/provision-agent-role.sh
rm -f /srv/trades/secrets/ai-readonly.env   # then delete the staged env/ai-readonly parameter
```

The script prints the HUMAN step that brokers the masked DSN under
`/trades/production/agent/database-url` (OUTSIDE `env/*` — the one path the agent role may
read) and the SSM port-forward the developer opens, under the **operator** profile, when an agent
needs the data: the agent gets a local port and the masked DSN for the session, nothing else.
A generator abort on a stale inventory row is the feature: fix `pii-inventory.md`, regenerate
(`make mask-manifest`), sync the host, re-run. **Where the role lives:** in the database volume —
a volume rebuild loses it; re-run the lane.

## Rebuild the host (rebuild-not-repair, IA-009)

1. `terraform apply` in `environments/production` (the operator profile; user-data
   re-provisions the runtime, the `/srv/trades` layout, the three crons). An edit to user-data
   plans as an in-place stop/modify/start and never re-runs cloud-init on a live host — the new
   script takes effect on a REBUILT host only. A boundary edit needs the administrator session
   (`ProtectBoundary` denies it to the operator).
2. `scripts/sync-host-deploy.sh` (the first sync copies everything), then write `deploy/.env`
   by hand (registry, `bootstrap-pending` tags, base hostname, ACME e-mail, the basic-auth
   credential, the backups bucket) and verify it with `docker compose config`.
3. `/srv/trades/fetch-secrets.sh` on the host; `/srv/trades/secrets/files/` (the JWT key pair,
   the FCM file, the dummy password hash) and `backup-age.recipient` are restored from their
   off-host copies. `files/` must be mode `755` so the containers' uid 33 can traverse it (set by
   hand on the first host; not yet in the user-data).
4. Re-promote every deployable at its current SHA with `scripts/promote.sh` (`app` first with
   `--first-boot-skip-backup-gate` only when the database is genuinely empty — a restored volume
   is not), then `media`, then `web`; confirm the whole runtime set is up.
5. Restore the database from the newest off-host dump (above), then re-run the agent-role lane.

## DLQ — failed async messages

Depth > 0 sustained is an incident (`backend.md` § DLQ). The dead-letter queue is `failed` in
`shared.messenger_messages`; **never** run `messenger:consume failed`:

```bash
docker compose -f docker-compose.prod.yml exec app php bin/console messenger:failed:show
docker compose -f docker-compose.prod.yml exec app php bin/console messenger:failed:show {id} -vv
docker compose -f docker-compose.prod.yml exec app php bin/console messenger:failed:retry {id}   # once, after the fix is deployed
```

`media` has its own `failed` queue in the `media` database.

## Personal data — what the deploy surface holds and for how long

Six stores outside the application database (`trades-docs/pii-inventory.md`): the perimeter
request log (pseudonymised IP, 14 days), the nightly dumps (every inventoried field, encrypted,
14 days local and off-host by the lifecycle rule), the pre-recreate log archive (14 days), the
daily volume snapshots (7 days — the whole disk, captured mail and fetched secrets included), the
captured mail (500 messages / 14 days, synthetic recipients only, ends at 10.9) and the promotion
records (no personal data: the operator ARN without its session name). **An erasure request is
fully effective at most 14 days after the last dump taken before it.** A breach in any of them
starts the 72-hour clock of `gdpr-pii.md` § "Personal-data breach response" at awareness.

## The cookie rule that binds every future subdomain

`csrf_refresh` is scoped to the base hostname so the SPA on `app.` can read what the API on
`api.` sets. **No untrusted or third-party content may ever be served from a sibling sub-label
of the base hostname.** In stage 1 one exposure remains that a real domain removes: any other
`sslip.io` user can set a cookie scoped to `sslip.io` itself (cookie tossing). The refresh
endpoint runs with `CSRF_REFRESH_ENFORCEMENT=true`, so the worst case is a failed refresh or a
forced sign-out, never a forged request (TM-6, ADR-120 amended). `refresh_token` and
`mercureAuthorization` stay host-only on `api.`.

## First deploy — the sequence (Phase 7; HUMAN steps are the developer's acts, IA-004)

`ai-standards/standards/first-deploy-checklist.md` adapted: no DNS delegation, no CI roles,
manual promotion. Every **HUMAN** step pauses the run; the Tester verifies the live rows after
each one.

1. **HUMAN** — activate `project` as a cost-allocation tag (Billing console) **≥ 48 h before
   step 4**; confirm the Identity Center `AdministratorAccess` sign-in works.
2. **HUMAN** — bootstrap the state bucket (versioned, SSE, public access blocked):
   ```bash
   ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   aws s3api create-bucket --bucket "trades-terraform-state-${ACCOUNT_ID}" --region eu-south-2 --create-bucket-configuration LocationConstraint=eu-south-2
   aws s3api put-bucket-versioning --bucket "trades-terraform-state-${ACCOUNT_ID}" --versioning-configuration Status=Enabled
   aws s3api put-bucket-encryption --bucket "trades-terraform-state-${ACCOUNT_ID}" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
   aws s3api put-public-access-block --bucket "trades-terraform-state-${ACCOUNT_ID}" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
   ```
3. DevOps — with the administrator session: `terraform init -backend-config="bucket=trades-terraform-state-${ACCOUNT_ID}"`,
   `TF_VAR_alert_email=<inbox> terraform plan -out=production.tfplan`,
   `terraform show -json production.tfplan > production.tfplan.json`; Tester:
   `make tf-plan-check PLAN_JSON=terraform/environments/production/production.tfplan.json` (AC-1).
   The plan and its JSON stay local (SC-013).
4. **HUMAN** — read the WHOLE plan; `terraform apply production.tfplan`; write the `trades-prod`
   and `trades-agent` profiles; confirm the SNS and budget e-mail subscriptions.
5. **HUMAN** — Google console check: does it accept the `https://api.<base>/api/oauth/google/callback`
   redirect URI? That answer is `VITE_GOOGLE_SIGN_IN_ENABLED` for the production build.
6. DevOps — record the outputs; `dig +short` every hostname → the Elastic IP;
   `AWS_PROFILE=trades-prod scripts/mirror-object-store-images.sh`; in ONE trades-infra PR pin the
   ECR digests it prints in `docker-compose.prod.yml` and fill `deploy/production/web.build-args`
   (the base hostname, step 5's answer); merge before step 8.
7. **HUMAN** — seed `/trades/production/env/{app,media,mercure,postgres,storage}` from the rows of
   `secrets-manifest.md` (from local files, deleted afterwards; `MAILER_DSN=smtp://mailpit:1025`,
   `CSRF_REFRESH_ENFORCEMENT=true`, the stage-1 placeholders); write the host `deploy/.env`
   (registry, `bootstrap-pending` tags, base hostname, ACME e-mail, the basic-auth user and
   single-quoted hash, the backups bucket) and verify it with `docker compose config`; put the
   JWT key pair, the FCM file, the dummy password hash and `backup-age.recipient` under
   `/srv/trades/secrets/`.
8. DevOps — `scripts/sync-host-deploy.sh` (first sync); `/srv/trades/fetch-secrets.sh` on the
   host; Tester verifies AC-11.
9. **HUMAN** — first promotions: `scripts/promote.sh app <sha> --first-boot-skip-backup-gate`
   (the one legitimate bypass), then `media`, then `web`; Tester verifies AC-9, AC-10, AC-23, AC-24.
10. **HUMAN** — the synthetic-data lane (above) on the still-empty database, the password handed
    to the partner out of band; **then** the developer's own `platform_admin` via
    `app:create-user`. Tester verifies, live and in that order, AC-18, AC-22, TM-12.
11. **HUMAN** — the agent-role lane (above) and the masked DSN parameter; Tester verifies AC-12,
    AC-13, AC-14, TM-10.
12. **HUMAN** — register the external pinger; one manual `backup-postgres.sh` run; after the first
    night the restore drill from the off-host copy (its line in the table above); Tester verifies
    AC-15, AC-16, AC-17.
13. Tester — the perimeter as served, the canary and smoke URLs, `/check-web` anonymous against
    `app.`, the `public-facing-deploy.md` walk, `make dast-baseline URL=https://api.<base>`, the
    budget definition (AC-2..AC-7, AC-19, AC-20); the HUMAN partner-style walk recorded for AC-4.
14. DevOps — fill the `workspace.md` values only known after the apply (instance id, registry
    host, base hostname); commit the first-deploy evidence to `trades-docs/specs/Deployment/_evidence/`.

## Severity quick-reference (declared by the standards)

| Signal | Severity | Canonical source |
|---|---|---|
| `audit_write_failures_total` > 0 — actions landing without trail | SEV-2 | `audit-log.md` § Observability |
| Ledger divergence (payments reconciliation) | SEV-2 | `payments-and-money.md` § Reconciliation |
| DLQ depth > 0 sustained | incident | `backend.md` § DLQ |
| A worker `unhealthy`/`restarting` between promotions | incident | `deployment.md` DE-003, DE-006 rung 2 |
| The budget's 80 % actual threshold | investigate the same day | `infrastructure.md` IA-007 |
| Sustained swap use or an OOM kill on the host | graduation signal → ADR (t4g.large is pre-allowed by the boundary) | spec BR-11 |

## Where the values live (nothing is copied into this file)

| Value | Source |
|---|---|
| instance id, Elastic IP, base hostname, registry host, backups bucket, role ARNs, topic ARN | `terraform output` in `terraform/environments/production` (operator profile) and `trades-docs/workspace.md` `environments.production` |
| the three profiles | `~/.aws/config` (above) |
| the age private key, the basic-auth login, the synthetic accounts' and the owner's passwords | SSM SecureStrings under `/trades/production/operator/` (operator only; host and agent denied) — `make web-login` prints the logins |
| the `ai_readonly` password | the masked DSN `/trades/production/agent/database-url` carries it; staged under `env/ai-readonly` only for a run |
| the external pinger | its dashboard, URL recorded in `workspace.md` |
| what is live | the promotion records under `promotions/` in the backups bucket |
