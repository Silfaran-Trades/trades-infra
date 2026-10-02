# Committed — values here are configuration, NEVER secrets (IA-003 / SC-013).
# Every value is a project decision recorded in trades-docs/decisions.md (ADR-124
# the stage-1 production shape, ADR-125 manual promotion, ADR-126 object storage)
# and mirrored in trades-docs/workspace.md's environments: registry.
#
# NOT here, on purpose: `alert_email` (personal data — `TF_VAR_alert_email` at plan
# time) and the account id (the state bucket name is given at `terraform init`).

project       = "trades"
region        = "eu-south-2"
instance_type = "t4g.medium" # 4 GiB: 10.4 measured ~1.57 GiB steady across eleven containers, ClamAV ~1 GiB of it (BR-11)

# The IA-006 allowlist the boundary enforces: the host's type plus the graduation
# size, pre-allowed so an ADR-backed resize needs no boundary edit (spec § Access).
allowed_instance_types = ["t4g.medium", "t4g.large"]

# 50 USD, taxes included: the verified eu-south-2 estimate is ~35 USD/month before
# tax (~42.5 with Spanish VAT) — spec § Open Questions "Monthly budget".
monthly_budget_usd = "50"

# The owner's Identity Center permission set (AWSReservedSSO_AdministratorAccess_*)
# is what may assume trades-production-operator and trades-production-agent (BR-4).
identity_center_permission_set = "AdministratorAccess"

# The project sharing this account — every principal carries a HandsOffSibling Deny
# on its names and its `project` tag (BR-2, TM-1).
sibling_project = "kha-energy"

root_volume_gb = 40
