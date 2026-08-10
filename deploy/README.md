# Production infrastructure

Production is **not** the development `docker-compose.yml` one level up. That compose
runs throwaway containers with default credentials (Postgres `workspace/workspace`,
Mailpit) for local development only.

Production infrastructure as code lives here. For Trades that means, at minimum:

- **PostgreSQL + PostGIS** — a managed instance (RDS / Cloud SQL / Azure DB for
  PostgreSQL) with backups, HA and point-in-time recovery, PostGIS enabled. ONE database
  for the backend app (`trades_app`, one schema per bundle) plus one for media-service —
  never a database per bundle (ADR-076, which supersedes the per-service rule).
- **No message broker.** Wave 8 of the monolith migration removed RabbitMQ from every repo:
  cross-bundle messaging is in-process and deferred work is `doctrine://` against the app's
  own database. Provisioning a managed broker cluster here would be paying for infrastructure
  nothing connects to. The three triggers that would once have justified bringing one back were
  recorded only in the unversioned migration plan, which no longer exists — so it now needs a
  fresh ADR in `../trades-docs/decisions.md`.
- **ClamAV** — its own deployment/sidecar for the media-service scan worker.
- **SMTP** — a real provider (SES / SendGrid / …) replacing Mailpit.
- **Object storage / CDN** — for media-service uploads (private vs public buckets).
- **Orchestration** — Terraform / Helm / `compose.prod.yml` for the target platform.

Keep engine and image versions aligned with the dev compose and
`ai-standards/standards/tech-stack.md` so dev/prod parity stays auditable.

**Secrets never live in this repo** — see `ai-standards/standards/secrets.md`.
Source them from a secrets manager and inject per environment.
