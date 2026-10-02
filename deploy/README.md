# Production deploy configuration

Production is **not** the development `docker-compose.yml` one level up. That compose runs
throwaway containers with default credentials (Postgres `workspace/workspace`, Mailpit) for
local development only.

This directory is what the production host runs at `/srv/trades/deploy` (production-packaging-
promotion-lane, 10.4, adapted by production-infrastructure-first-deploy, 10.6 — every file
derived from `ai-standards/templates/deploy/`; rules in `ai-standards/standards/deployment.md`;
the stage-1 shape in ADR-124, the promotion in ADR-125, the object store in ADR-126). It
reaches the host through `scripts/sync-host-deploy.sh` — merging this repository deploys nothing
(DE-004).

| File | What it is |
|---|---|
| `docker-compose.prod.yml` | the runtime set: Caddy, the app + three workers, the Mercure hub, media-service, ClamAV, MinIO (+ bucket init, the ECR-mirrored images by digest), Mailpit (stage-1 mail capture), PostgreSQL/PostGIS, the SPA — `${REGISTRY}/trades/<name>:<sha>` deployables, digest-pinned infrastructure, read-only root filesystems |
| `Caddyfile` | the perimeter: TLS, one hostname per deployable (`app.` `api.` `media.` `storage.` + `mail.`), safe-by-construction request logs; the stage-1 perimeter — basic auth on `app.` and `mail.`, `noindex` everywhere, the security-header floor on the responses the proxy generates itself (ADR-120 amended) |
| `deploy.sh` | the gated promotion on the host: lock → backup gate (the first-boot bypass honoured only on an empty `identity.users`) → tag pin → log archive → up → perimeter + hub + mail capture ensured (`--no-recreate`) → readiness → the promoted container's Docker health → worker gates → smoke (the SPA host: a 401 carrying the floor) → route-map canary |
| `backup-postgres.sh` | nightly encrypted dumps: 14-day local retention, the off-host copy to the S3 backups bucket (put-only; expiry is the bucket's lifecycle rule) |
| `restore-drill.sh` | one command: fetch the newest off-host dump (operator profile) or a local one, restore it into a throwaway container, one read per schema |
| `host-sentinel.sh` | Rung-2 sentinel: unhealthy containers, DLQ depth, backup freshness, root-filesystem usage — notifying this project's SNS topic |
| `seed-synthetic.sh` | the one-time, guarded synthetic-data lane of stage 1 (`--confirm-production-stage-1`, empty `identity.users`, a per-run password from a 600 file) |
| `agent-db/` | the AI-agent masked read-only database role (IA-010): `agent-readonly-role.sql`, `generate-masked-views.sh`, the GENERATED `mask-manifest.txt`, and the lane `provision-agent-role.sh` |
| `postgres-init/` | the production `CREATE DATABASE` set (no `*_test` databases) |
| `production/web.build-args` | the SPA's production build arguments (`promote.sh web` reads them; filled after the first apply) |
| `RUNBOOK.md` | the 3am page — and the first-deploy sequence, the stage-1 perimeter, promotion, host sync, the records |
| `rehearsal/` | the local first-deploy rehearsal harness (`rehearse.sh`) and its scratch templates |

**Secrets never live in this directory** (`ai-standards/standards/secrets.md`): the host holds
them at `/srv/trades/secrets/` (fetched from the parameter store by the host's own
`fetch-secrets.sh`) and the compose file references them by `env_file:` / read-only file
mounts. `deploy/.env` is host state — the registry, the tags, the base hostname, the ACME
e-mail, the basic-auth credential, the backups bucket — see
`rehearsal/templates/deploy.env.template`; the sync never touches it.

Keep engine and image versions aligned with the dev compose and
`ai-standards/standards/tech-stack.md` so dev/prod parity stays auditable.
