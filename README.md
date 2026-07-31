# Trades — Infrastructure

Versioned home for the Trades project's **shared infrastructure as code**. Created
following the `ai-standards` infra-repo convention (see
`ai-standards/commands/init-project-command.md`).

## What lives here

- `docker-compose.yml` — shared **development** infrastructure that every service
  joins via the external `workspace-network`:
  - `imresamu/postgis:18-3.6` (`trades-postgres`) — `trades_app` for the modular-monolith
    backend (one schema per bundle) plus `media` for media-service
  - `axllent/mailpit` (`trades-mailpit`) — dev SMTP capture
  - `clamav/clamav:1.5.2-debian13-slim` (`trades-clamav`) — media-service scan worker
  Image versions track `ai-standards/standards/tech-stack.md`. Owned/maintained by
  the DevOps agent.
- `infra/postgres/init/00-create-databases.sql` — `trades_app` (+ its test database) for the
  modular-monolith backend, and `media` (+ `media_test`) for media-service. A new bounded
  context is a new **bundle** with a **schema** inside `trades_app`, created by the app's own
  migrations — do NOT add a line here for it (ADR-076). Runs only on first container startup,
  while the data volume is empty, so editing it never changes an existing cluster.
- `deploy/` — **production** infrastructure as code. A different artifact from the
  dev compose above — see [`deploy/README.md`](deploy/README.md).

## How it starts

`make infra-up` (run from `ai-standards/`) resolves this repo through
`INFRA_DIR = ../trades-infra` in `trades-docs/workspace.mk` and runs the compose
here. Services then start with `make up`.

The compose pins `name: workspacetrades` so the existing Docker volumes
(`workspacetrades_postgres_data`, `workspacetrades_clamav_db`) and running
containers stay attached after the move from the workspace root. Do not change it.

## Why a dedicated repo

The workspace root is not a git repository — it only aggregates per-service
checkouts. Before this repo existed, the shared compose and DB init scripts lived
unversioned on a single machine and a fresh clone could not reconstruct the
environment.
