# Production infrastructure

Production is **not** the development `docker-compose.yml` one level up. That compose
runs throwaway containers with default credentials (Postgres `workspace/workspace`,
RabbitMQ `guest/guest`, Mailpit) for local development only.

Production infrastructure as code lives here. For Trades that means, at minimum:

- **PostgreSQL + PostGIS** — a managed instance (RDS / Cloud SQL / Azure DB for
  PostgreSQL) with backups, HA and point-in-time recovery, PostGIS enabled. One
  database per service, never a shared database.
- **RabbitMQ** — a managed or operated cluster (not a throwaway container).
- **ClamAV** — its own deployment/sidecar for the media-service scan worker.
- **SMTP** — a real provider (SES / SendGrid / …) replacing Mailpit.
- **Object storage / CDN** — for media-service uploads (private vs public buckets).
- **Orchestration** — Terraform / Helm / `compose.prod.yml` for the target platform.

Keep engine and image versions aligned with the dev compose and
`ai-standards/standards/tech-stack.md` so dev/prod parity stays auditable.

**Secrets never live in this repo** — see `ai-standards/standards/secrets.md`.
Source them from a secrets manager and inject per environment.
