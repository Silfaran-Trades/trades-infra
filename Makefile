# trades-infra — the shared development infrastructure + the production deploy configuration.
#
# `make quality` is this repository's FIRST CI check (production-packaging-promotion-lane,
# BR-25; .github/workflows/ci.yml runs exactly this target). Every tool runs as a
# DIGEST-PINNED CONTAINER — nothing is installed on the host beyond Docker, and every target
# FAILS CLOSED (no Docker → red, never a skip). Re-resolve a digest after a version bump with
#   docker buildx imagetools inspect <image>:<tag>
#
#   make quality          — shellcheck · compose config (dev + prod) · caddy adapt (read back)
#                           · actionlint · image pins · gitleaks · the DAST High-backstop self-test
#                           · terraform fmt · terraform validate · the plan-checker self-test
#                           (production-infrastructure-first-deploy BR-36 — Actions is off, so
#                           this target is the verification of record for every trades-infra PR)
#   make terraform-fmt / terraform-validate — the IaC gates alone (digest-pinned container;
#                           `init -backend=false`: no state, no credentials, no cloud)
#   make tf-plan-check PLAN_JSON=…   — AC-1 over the HUMAN-saved `terraform show -json` plan
#   make mask-manifest    — regenerate deploy/agent-db/mask-manifest.txt from pii-inventory.md
#   make mask-manifest-check         — drift between the inventory and the committed manifest
#   make rehearse         — the local first-deploy rehearsal (deploy/rehearsal/rehearse.sh up)
#   make rehearse-down    — tear it down
#   make dast-baseline URL=https://app.trades.test   — passive ZAP baseline (AS-021 rung 1)
#   make dast-high-check REPORT=… URL=…              — the High backstop alone, over a given report
#   make infra-up / infra-down — the shared DEV stack (normally driven from ai-standards)

.PHONY: quality shellcheck compose-config caddy-adapt actionlint image-pins gitleaks dast-baseline dast-high-check dast-high-selftest terraform-fmt terraform-validate tf-plan-check tf-plan-check-selftest mask-manifest mask-manifest-check rehearse rehearse-down infra-up infra-down web-login _require-docker _security-reports-dir

SHELLCHECK_IMAGE ?= koalaman/shellcheck-alpine:v0.11.0@sha256:9955be09ea7f0dbf7ae942ac1f2094355bb30d96fffba0ec09f5432207544002
ACTIONLINT_IMAGE ?= rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667
GITLEAKS_IMAGE   ?= ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
ZAP_IMAGE        ?= ghcr.io/zaproxy/zaproxy:stable@sha256:781a2bdaea47324e7bab583e2263f21d257b0aee61ed51521a5be45f5f5081ef
# Terraform >= 1.11 (native S3 locking, IA-001). The multi-arch index digest (arm64 dev
# machine + amd64 CI runner share the line); re-resolve with `docker buildx imagetools inspect`.
TERRAFORM_IMAGE  ?= hashicorp/terraform:1.14.1@sha256:1de2a42a99e36490585dcb60c43daf9f11381b10f40a0c7ddfd1e03733009aec
# The AWS provider is ~700 MB: a NAMED VOLUME caches it across runs (TF_PLUGIN_CACHE_DIR), so
# only the first validate downloads. The lock file is read-only in the gate — a provider bump is
# a deliberate `terraform init -upgrade` by hand, committed with the new .terraform.lock.hcl.
TF_PLUGIN_CACHE  ?= trades-infra-tf-plugin-cache
TF_ENVIRONMENTS  := production
REPORTS_DIR      ?= security/reports
# The PII inventory the mask manifest is generated from (the docs repo, a sibling checkout) —
# override with PII_INVENTORY=… (a per-session docs worktree, for instance).
PII_INVENTORY    ?= ../trades-docs/pii-inventory.md

_require-docker:
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker not found — every gate here runs as a digest-pinned container and does NOT skip"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "✗ docker daemon unreachable — every gate here runs as a digest-pinned container and does NOT skip"; exit 1; }

# Every shell script this repo ships: the host lanes (deploy, backup, restore, sentinel, the
# synthetic seed, the agent role), the developer lanes (promote, host sync, the mirror push),
# the rehearsal and the checks.
SHELL_SCRIPTS := deploy/deploy.sh deploy/backup-postgres.sh deploy/restore-drill.sh deploy/host-sentinel.sh \
	deploy/seed-synthetic.sh deploy/agent-db/generate-masked-views.sh deploy/agent-db/provision-agent-role.sh \
	deploy/rehearsal/rehearse.sh \
	scripts/promote.sh scripts/sync-host-deploy.sh scripts/mirror-object-store-images.sh \
	scripts/checks/check-compose-image-pins.sh scripts/checks/check-caddyfile.sh
shellcheck: _require-docker
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) \
		shellcheck -x $(SHELL_SCRIPTS)
	@echo "→ shellcheck: OK ($(words $(SHELL_SCRIPTS)) scripts)"

# `docker compose config` on BOTH files. The production file `:?`-guards every deployable tag
# and points env_file at the host's secrets dir, so it is validated against the documented
# template values and an EMPTY scratch secrets dir — the shape, never a real value.
compose-config: _require-docker
	docker compose -f docker-compose.yml config -q
	@tmp="$$(mktemp -d)"; \
	  for f in app media mercure postgres storage; do : > "$$tmp/$$f.env"; done; mkdir -p "$$tmp/files"; \
	  TRADES_SECRETS_DIR="$$tmp" docker compose --project-directory deploy --env-file deploy/rehearsal/templates/deploy.env.template -f deploy/docker-compose.prod.yml config -q; \
	  rc=$$?; rm -rf "$$tmp"; exit $$rc
	@echo "→ compose config: OK (docker-compose.yml + deploy/docker-compose.prod.yml)"

# `caddy adapt` in the pinned image, then the adapted JSON is READ (not just its exit code).
caddy-adapt: _require-docker
	@scripts/checks/check-caddyfile.sh deploy/Caddyfile

actionlint: _require-docker
	docker run --rm -v "$(CURDIR):/repo:ro" -w /repo $(ACTIONLINT_IMAGE) -color
	@echo "→ actionlint: OK"

# Every `image:` line in both compose files carries an immutable digest (BR-2, AS-018); the
# three SHA-tagged deployables are reported as such and pass.
image-pins:
	@test -x scripts/checks/check-compose-image-pins.sh || { echo "✗ scripts/checks/check-compose-image-pins.sh missing or not executable"; exit 1; }
	@scripts/checks/check-compose-image-pins.sh docker-compose.yml deploy/docker-compose.prod.yml

# Working-tree secret scan (attack-surface-hardening.md § "Secrets scanning") — the tree, not
# only the commits, so a gitignored file that should never exist here is caught too. The one
# tree that SHOULD hold secrets — the rehearsal's gitignored scratch store — is allowlisted by
# path in .gitleaks.toml (every default rule stays on); the config is passed explicitly.
gitleaks: _require-docker
	@test -f .gitleaks.toml || { echo "✗ .gitleaks.toml missing (the rehearsal scratch allowlist)"; exit 1; }
	docker run --rm -v "$(CURDIR):/repo:ro" $(GITLEAKS_IMAGE) dir /repo --config /repo/.gitleaks.toml --redact --no-banner --exit-code 1
	@echo "→ gitleaks: OK"

quality: shellcheck compose-config caddy-adapt actionlint image-pins gitleaks dast-high-selftest terraform-fmt terraform-validate tf-plan-check-selftest
	@echo "→ infra quality: PASS"

# --- Terraform: the IaC gates (production-infrastructure-first-deploy BR-36; infrastructure.md
# § Philosophy — "infrastructure is code, reviewed like code", with deterministic gates) ------
#
# Both run in the digest-pinned Terraform container. `init -backend=false` touches NO state and
# needs NO credential: it only installs the provider the committed lock file names (read-only —
# a drifted lock fails loud) into the plugin-cache volume and wires the modules. There is NO
# `terraform plan` here ON PURPOSE: a plan needs the operator session and reads secret-bearing
# state (SC-013); plans stay human-run (IA-004) and are checked afterwards by tf-plan-check.
terraform-fmt: _require-docker
	docker run --rm -v "$(CURDIR)/terraform:/tf:ro" -w /tf $(TERRAFORM_IMAGE) fmt -check -recursive -diff
	@echo "→ terraform fmt: OK"

# TF_DATA_DIR keeps the gate off the operator's real `.terraform/` (S3 backend initialised at
# Phase 7): a validate there reaches for backend credentials the gate never has.
terraform-validate: _require-docker
	@for env in $(TF_ENVIRONMENTS); do \
	  echo "→ terraform validate: environments/$$env"; \
	  docker run --rm -v "$(CURDIR)/terraform:/tf" -v "$(TF_PLUGIN_CACHE):/plugin-cache" \
	    -e TF_PLUGIN_CACHE_DIR=/plugin-cache -e TF_DATA_DIR=/plugin-cache/.validate-data/$$env -e TF_IN_AUTOMATION=1 \
	    -w "/tf/environments/$$env" $(TERRAFORM_IMAGE) init -backend=false -input=false -lockfile=readonly >/dev/null || exit 1; \
	  docker run --rm -v "$(CURDIR)/terraform:/tf" -v "$(TF_PLUGIN_CACHE):/plugin-cache" \
	    -e TF_PLUGIN_CACHE_DIR=/plugin-cache -e TF_DATA_DIR=/plugin-cache/.validate-data/$$env -e TF_IN_AUTOMATION=1 \
	    -w "/tf/environments/$$env" $(TERRAFORM_IMAGE) validate || exit 1; \
	done
	@echo "→ terraform validate: OK ($(TF_ENVIRONMENTS))"

# AC-1 over the plan the HUMAN saved (Phase 7 step 3): every name trades-prefixed, a budget
# present, no anomaly monitor / EstimatedCharges alarm / OIDC provider / CI role / Route 53,
# `kha-energy` only inside Deny statements. Runs in the pinned ZAP image's python3 (the same
# interpreter the DAST backstop uses — no host Python dependency).
#   terraform -chdir=terraform/environments/production show -json production.tfplan > production.tfplan.json
#   make tf-plan-check PLAN_JSON=terraform/environments/production/production.tfplan.json
TF_PLAN_CHECK := scripts/checks/check-tf-plan.py
tf-plan-check: _require-docker
	@test -n "$(PLAN_JSON)" || { echo "ERROR: pass PLAN_JSON=… (the \`terraform show -json\` output of the saved plan, under this repo)"; exit 2; }
	@test -f "$(PLAN_JSON)" || { echo "ERROR: $(PLAN_JSON) not found"; exit 2; }
	@docker run --rm -v "$(CURDIR):/zap/wrk:ro" --entrypoint python3 $(ZAP_IMAGE) /zap/wrk/$(TF_PLAN_CHECK) "/zap/wrk/$(PLAN_JSON)"

# The plan checker's own fixtures (18 in-memory cases: a clean plan and a plan shaped like real
# `terraform show -json` output — top-level `variables` with sibling_project = kha-energy,
# resource_changes, output_changes, prior_state, configuration — pass; each forbidden resource,
# an unprefixed name, a sibling string outside a Deny in any section and an empty plan fail).
# Part of `quality`: a gate that has never been observed failing has only been installed.
tf-plan-check-selftest: _require-docker
	@test -f "$(TF_PLAN_CHECK)" || { echo "✗ $(TF_PLAN_CHECK) missing"; exit 2; }
	@docker run --rm -v "$(CURDIR):/zap/wrk:ro" --entrypoint python3 $(ZAP_IMAGE) /zap/wrk/$(TF_PLAN_CHECK) --self-test

# --- the agent's mask manifest (IA-010, BR-27) — generated from the PII inventory ----------
# Not part of `quality`: the inventory lives in the docs repo, which CI does not check out.
# Regenerate in the same PR as any inventory or schema change, then sync the host and re-run
# deploy/agent-db/provision-agent-role.sh (RUNBOOK.md § "The agent-role lane").
MASK_MANIFEST_BUILDER := scripts/agent-db/build-mask-manifest.py
MASK_MANIFEST         := deploy/agent-db/mask-manifest.txt
mask-manifest: _require-docker
	@test -f "$(PII_INVENTORY)" || { echo "ERROR: $(PII_INVENTORY) not found — set PII_INVENTORY=… (the docs repo's pii-inventory.md)"; exit 2; }
	@docker run --rm -v "$(CURDIR):/zap/wrk" -v "$(abspath $(PII_INVENTORY)):/pii-inventory.md:ro" --entrypoint python3 $(ZAP_IMAGE) \
		/zap/wrk/$(MASK_MANIFEST_BUILDER) /pii-inventory.md /zap/wrk/$(MASK_MANIFEST)

mask-manifest-check: _require-docker
	@test -f "$(PII_INVENTORY)" || { echo "ERROR: $(PII_INVENTORY) not found — set PII_INVENTORY=… (the docs repo's pii-inventory.md)"; exit 2; }
	@docker run --rm -v "$(CURDIR):/zap/wrk:ro" -v "$(abspath $(PII_INVENTORY)):/pii-inventory.md:ro" --entrypoint python3 $(ZAP_IMAGE) \
		/zap/wrk/$(MASK_MANIFEST_BUILDER) /pii-inventory.md --check /zap/wrk/$(MASK_MANIFEST)

# --- DAST: passive OWASP ZAP baseline (AS-021 rung 1), the same profile the workflow would use ---
#
# `--autooff` pins zap-baseline.py's classic path instead of the Automation Framework (AF) it
# picks by default. The two differ in exactly what the committed profile relies on:
#   - an `OUTOFSCOPE` line is honoured by the classic path as a prefix `re.match` on the alert
#     URL before the rule is counted; the AF path rewrites it into an `alertFilter` (full-match
#     regex, marks instances "False Positive") whose outputSummary STILL counts the rule as
#     FAIL — the profile's 10038 scope-off of the JSON hosts was red on api. by construction
#     (rehearsal, D7). The scan itself is the same spider + client spider + passive rules over
#     the target's host in both modes.
#   - the classic summary omits Informational-RISK alerts (10015, 10049, 90005 on this
#     perimeter); they are still written to the report files below — read those for triage.
# ZAP_PROFILE exists for the observe-it-fail probe (a scratch copy under $(REPORTS_DIR)); bumping
# ZAP_IMAGE re-runs that probe — the classic path is one the script says it may drop one day.
#
# Two gates, one target. zap-baseline.py's exit code enforces the PROFILE: a FAIL-pinned rule
# exits 1; `-I` keeps the deliberately-noisy WARN lines report-only (triage, never a block), and
# every rule the profile does not list defaults to WARN — so on its own the script enforces
# "these seven rules never regress", not AS-021's "no HIGH ships unaccepted". The second gate,
# scripts/checks/check-zap-high-alerts.py, reads the FULL JSON report (`-J` is
# zap.core.jsonreport(): every alert, whatever the profile says) and fails on ANY High-risk
# alert on the target host unless the profile carries an IGNORE line for that rule citing an
# ADR / decisions.md — the acceptance AS-021 names. It runs in the same pinned ZAP image
# (python3), fails closed on a missing report or an absent target site, and its `--self-test`
# is chained into `quality` so the backstop is observed failing on every run, not once.
ZAP_PROFILE ?= security/zap-baseline.yaml
ZAP_HIGH_CHECK := scripts/checks/check-zap-high-alerts.py

_security-reports-dir:
	@mkdir -p $(REPORTS_DIR)

# The full gate: scan (profile levels) → High backstop (report). A stale report is removed
# first so the backstop can only ever read THIS run's file.
dast-baseline: _require-docker _security-reports-dir
	@test -n "$(URL)" || { echo "ERROR: pass URL=… (the base URL you are AUTHORISED to scan, e.g. the rehearsal perimeter)"; exit 2; }
	@test -f "$(ZAP_PROFILE)" || { echo "ERROR: $(ZAP_PROFILE) missing"; exit 2; }
	@test -f "$(ZAP_HIGH_CHECK)" || { echo "✗ $(ZAP_HIGH_CHECK) missing — the AS-021 High backstop; the scan does not run without it"; exit 2; }
	@rm -f $(REPORTS_DIR)/zap-baseline.json
	@docker run --rm $(ZAP_DOCKER_ARGS) -v "$(CURDIR):/zap/wrk:rw" $(ZAP_IMAGE) \
		zap-baseline.py --autooff -t "$(URL)" -c "$(ZAP_PROFILE)" -I -a -j \
		-J $(REPORTS_DIR)/zap-baseline.json -w $(REPORTS_DIR)/zap-baseline.md ; \
	ec=$$? ; \
	if [ $$ec -ge 2 ]; then echo "→ DAST baseline: ZAP error (exit $$ec — target unreachable, scan aborted, or reports dir not writable)" ; exit $$ec ; fi ; \
	$(MAKE) --no-print-directory dast-high-check REPORT=$(REPORTS_DIR)/zap-baseline.json URL="$(URL)" ZAP_PROFILE="$(ZAP_PROFILE)" ; \
	hc=$$? ; \
	if [ $$ec -eq 1 ] && [ $$hc -ne 0 ]; then echo "→ DAST baseline: FAIL-level alert(s) AND unaccepted High — see $(REPORTS_DIR)/zap-baseline.md" ; exit 1 ; \
	elif [ $$ec -eq 1 ]; then echo "→ DAST baseline: FAIL-level alert(s) — see $(REPORTS_DIR)/zap-baseline.md" ; exit 1 ; \
	elif [ $$hc -ne 0 ]; then echo "→ DAST baseline: unaccepted High-risk alert(s) (AS-021) — see $(REPORTS_DIR)/zap-baseline.md" ; exit 1 ; \
	else echo "→ DAST baseline: OK ($(REPORTS_DIR)/zap-baseline.json)" ; fi

# The High backstop alone, over any report — the observe-it-fail probe for the Tester and the
# reviewer: feed it a report carrying a High on the target and watch it exit 1.
#   make dast-high-check REPORT=security/reports/zap-baseline.json URL=https://api.trades.test/api/health
dast-high-check: _require-docker
	@test -n "$(REPORT)" || { echo "ERROR: pass REPORT=… (a ZAP JSON report under this repo)"; exit 2; }
	@test -n "$(URL)" || { echo "ERROR: pass URL=… (the URL that report was scanned from)"; exit 2; }
	@test -f "$(ZAP_HIGH_CHECK)" || { echo "✗ $(ZAP_HIGH_CHECK) missing"; exit 2; }
	@docker run --rm -v "$(CURDIR):/zap/wrk:ro" --entrypoint python3 $(ZAP_IMAGE) \
		/zap/wrk/$(ZAP_HIGH_CHECK) --report "/zap/wrk/$(REPORT)" --target "$(URL)" --profile "/zap/wrk/$(ZAP_PROFILE)"

# The backstop's own fixtures (in-memory: a High unaccepted, WARN-pinned, IGNORE without a
# citation, OUTOFSCOPE-only → FAIL; ADR-cited IGNORE, other-host High, Medium-only → OK; a
# missing report / absent target site → error). Part of `quality`: a gate that has never been
# observed failing has only been installed.
dast-high-selftest: _require-docker
	@test -f "$(ZAP_HIGH_CHECK)" || { echo "✗ $(ZAP_HIGH_CHECK) missing"; exit 2; }
	@docker run --rm -v "$(CURDIR):/zap/wrk:ro" --entrypoint python3 $(ZAP_IMAGE) /zap/wrk/$(ZAP_HIGH_CHECK) --self-test

# --- the rehearsal --------------------------------------------------------------------------
rehearse:
	@deploy/rehearsal/rehearse.sh up

rehearse-down:
	@deploy/rehearsal/rehearse.sh down

# --- the shared DEV stack -------------------------------------------------------------------
infra-up:
	docker compose up -d

infra-down:
	docker compose down

# The stage-1 web login (basic auth on app.): kept in SSM, never in a password manager or a
# repository; readable by the owner/operator only (host and agent are denied the path).
# Needs a live session: `aws sso login --profile trades-admin` first if it has expired.
web-login:
	@aws ssm get-parameter --profile trades-prod --region eu-south-2 --name /trades/production/operator/web-login --with-decryption --query Parameter.Value --output text
