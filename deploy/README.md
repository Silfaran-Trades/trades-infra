# Production deploy configuration

Production is **not** the development `docker-compose.yml` one level up. That compose runs
throwaway containers with default credentials (Postgres `workspace/workspace`, Mailpit) for
local development only.

This directory is what the production host runs (production-packaging-promotion-lane, 10.4 —
every file derived from `ai-standards/templates/deploy/`; rules in
`ai-standards/standards/deployment.md`):

| File | What it is |
|---|---|
| `docker-compose.prod.yml` | the runtime set: Caddy, the app + three workers, the Mercure hub, media-service, ClamAV, MinIO (+ bucket init), PostgreSQL/PostGIS, the SPA — SHA-tagged deployables, digest-pinned infrastructure, read-only root filesystems |
| `Caddyfile` | the perimeter: TLS, one hostname per deployable (`app.` `api.` `media.` `storage.`), safe-by-construction request logs, no application security headers (ADR-120) |
| `deploy.sh` | the gated promotion: lock → backup gate → tag pin → log archive → up → perimeter + hub ensured (`--no-recreate`) → readiness → the promoted container's Docker health → worker gates → smoke → route-map canary |
| `backup-postgres.sh` | nightly encrypted dumps, 14-day retention, off-host slot (10.6) |
| `restore-drill.sh` | one command: restore the newest dump into a throwaway container, one read per schema |
| `host-sentinel.sh` | Rung-2 sentinel: unhealthy containers, DLQ depth, backup freshness |
| `postgres-init/` | the production `CREATE DATABASE` set (no `*_test` databases) |
| `RUNBOOK.md` | the 3am page |
| `rehearsal/` | the local first-deploy rehearsal harness (`rehearse.sh`) and its scratch templates |

**Secrets never live in this directory** (`ai-standards/standards/secrets.md`): the host holds
them at `/srv/trades/secrets/` and the compose file references them by `env_file:` / read-only
file mounts. `deploy/.env` is host state (tags, domain, TLS argument) — see
`rehearsal/templates/deploy.env.template`.

**What 10.6 still decides:** the host and its IaC, the production domain, the registry
credential on the host, whether PostgreSQL stays a container on the host or moves to a managed
instance (the rehearsal runs it as the container above), the off-host backup destination, and
the real mailer replacing Mailpit. Nothing in this directory presumes those answers beyond the
`DOMAIN` placeholder.

Keep engine and image versions aligned with the dev compose and
`ai-standards/standards/tech-stack.md` so dev/prod parity stays auditable.
