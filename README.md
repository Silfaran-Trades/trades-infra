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
- `deploy/` — what the **production** host runs: the compose, the perimeter, the promotion
  and backup lanes, the synthetic-data lane, the agent-role lane, the runbook. A different
  artifact from the dev compose above — see [`deploy/README.md`](deploy/README.md).
- `terraform/` — what **exists** in the cloud (production-infrastructure-first-deploy, ADR-124):
  one isolated project in the AWS account shared with KHA Energy, region `eu-south-2` —
  `environments/production/` (the one state root; `backend.tf` is the S3 backend with native
  locking, `terraform.tfvars` carries no secret, `alert_email` arrives as `TF_VAR_alert_email`)
  and `modules/` (`network` 10.81.0.0/24 with no NAT, `single-host` the t4g.medium arm64 host
  and its user-data, `access` the permissions boundary + the operator and agent roles,
  `registry` the five ECR repositories, `backups-bucket` the versioned off-host dump copy,
  `cost-guardrails` the tag-filtered budget, `host-alarms`, `backup` the daily snapshots). Every
  `terraform apply` is a human act (IA-004); the agent authors, plans and presents. Gates:
  `make terraform-fmt`, `make terraform-validate`, `make tf-plan-check PLAN_JSON=…` (AC-1 over
  the saved plan). Rules: `ai-standards/standards/infrastructure.md`.
- `scripts/` — the developer-side lanes run from this machine under the `trades-prod`
  profile: `promote.sh` (the manual SHA promotion, ADR-125), `sync-host-deploy.sh` (the
  hash-verified host sync, DE-004), `mirror-object-store-images.sh` (the one-time MinIO / mc
  push to ECR, ADR-126), `agent-db/build-mask-manifest.py` (the mask manifest from
  `trades-docs/pii-inventory.md`) and `checks/` (the `make quality` gates).

## Quality gates

`make quality` is the verification of record for every pull request (GitHub Actions is off —
ADR-125): shellcheck over every script, `docker compose config` on both compose files, the
Caddyfile adapted and read back, actionlint, the compose image pins, a gitleaks working-tree
scan, the DAST High-backstop self-test, `terraform fmt`, `terraform validate`
(`init -backend=false`, no credentials) and the plan-checker self-test. Every tool runs as a
digest-pinned container. `make mask-manifest-check` (needs the docs repo) proves the committed
mask manifest still matches the inventory.

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
