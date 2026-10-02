# Environment root — production (the ONLY environment; stage 1 = rehearsal
# production with synthetic data, ADR-124; stage 2 = the 10.9 go-live).
#
# Derived from: ai-standards/templates/terraform/aws/environments/production/main.tf.template
# Spec: Deployment/production-infrastructure-first-deploy § Infrastructure Architecture.
# Adaptations from the template, each cited:
#   - `access` (NEW): the permissions boundary + the operator and agent roles
#     (BR-4, BR-5, BR-7). The boundary is attached to EVERY role this state
#     creates — operator, agent, host, DLM (BR-5).
#   - `backups-bucket` (NEW): the off-host dump copy + promotion records (BR-28, BR-24).
#   - `registry`: five repositories, two of them the mirrored object-store images
#     (BR-23, BR-33); the host's ECR read is scoped to exactly these ARNs.
#   - `cost-guardrails` CUT DOWN to the tag-filtered budget (BR-8): the billing
#     alarm and the anomaly monitor are KHA Energy's account-wide ones (BR-9) —
#     IA-007 deviation recorded in ADR-124.
#   - `host-alarms` gains the CPUCreditBalance alarm; disk is the host sentinel's
#     (BR-30a; no CloudWatch agent).
#   - NOT instantiated: `ci-oidc-roles` (no CI role, no OIDC provider reference —
#     Actions is off, ADR-125), `dns` (10.9), the billing alarm and the anomaly
#     monitor (BR-9).
#
# Coexistence with KHA Energy in this account (BR-1, BR-2): every name below is
# `trades-` / `trades/` / `/trades/production/`; nothing references a KHA
# resource, and the boundary's HandsOffSibling statement denies touching them.
# The account's single Cost Explorer anomaly monitor is KHA's — never created or
# imported here.
#
# Human gate (IA-004): an agent authors this and runs `terraform plan`; the
# developer reads the WHOLE plan and applies. The FIRST apply runs under the
# owner's administrator Identity Center session (it creates the boundary and
# both roles); every later plan/apply uses the `trades-prod` profile, which
# assumes trades-production-operator. Nothing here is wired to auto-apply.
#
# No plan-time-unknown `count` anywhere (KHA lesson, BR-39): every policy whose
# resource ARN comes from another module is unconditional with a required
# variable. The one cross-module cycle that would otherwise exist (the host's
# user-data needs the alerts topic ARN; the alarms need the instance id) is cut
# by CONSTRUCTING the SNS topic ARN from its deterministic name (local below) —
# modules/host-alarms creates the topic with exactly that name.
#
# Cost guardrails ride the same state and the same apply as the host (IA-007).

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project     = var.project
      environment = var.environment
      managed-by  = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # The ECR registry host — the host's credential helper and deploy/.env's REGISTRY.
  registry_host = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # The pre-DNS public hostname: the Elastic IP with dashes, on sslip.io (BR-15).
  # app./api./media./storage./mail. of it are the five hosts of the perimeter.
  public_hostname = "${replace(module.host.public_ip, ".", "-")}.sslip.io"

  # Deterministic SNS topic ARN (see header) — the sentinel's NOTIFY_CMD target
  # and the host role's sns:Publish resource. modules/host-alarms creates it.
  host_alerts_topic_name = "${var.project}-${var.environment}-host-alerts"
  host_alerts_topic_arn  = "arn:${local.partition}:sns:${var.region}:${local.account_id}:${local.host_alerts_topic_name}"

  # The bootstrapped state bucket (backend.tf) — denied to the agent role (SC-013).
  state_bucket_arn = "arn:${local.partition}:s3:::${var.project}-terraform-state-${local.account_id}"
}

module "network" {
  source      = "../../modules/network"
  project     = var.project
  environment = var.environment
  # 10.81.0.0/24 — distinct from KHA's 10.80.0.0/24 (BR-1, verified at refinement).
  vpc_cidr = "10.81.0.0/24"
}

module "registry" {
  source      = "../../modules/registry"
  project     = var.project
  environment = var.environment
  # One repository per deployable (BR-23) + the two mirrored object-store images (BR-33).
  repositories           = ["trades-backend", "media-service", "trades-front", "minio", "mc"]
  lifecycle_repositories = ["trades-backend", "media-service", "trades-front"]
}

module "backups_bucket" {
  source      = "../../modules/backups-bucket"
  project     = var.project
  environment = var.environment
}

module "access" {
  source                         = "../../modules/access"
  project                        = var.project
  environment                    = var.environment
  region                         = var.region
  allowed_instance_types         = var.allowed_instance_types
  identity_center_permission_set = var.identity_center_permission_set
  sibling_project                = var.sibling_project
  backups_bucket_arn             = module.backups_bucket.bucket_arn
  state_bucket_arn               = local.state_bucket_arn
  env_parameter_prefix           = "/${var.project}/${var.environment}/env"
  agent_parameter_prefix         = "/${var.project}/${var.environment}/agent"
}

module "host" {
  source                   = "../../modules/single-host"
  project                  = var.project
  environment              = var.environment
  region                   = var.region
  instance_type            = var.instance_type
  root_volume_gb           = var.root_volume_gb
  subnet_id                = module.network.subnet_id
  security_group_id        = module.network.security_group_id
  registry_host            = local.registry_host
  permissions_boundary_arn = module.access.boundary_arn
  ecr_repository_arns      = values(module.registry.repository_arns)
  backups_bucket_arn       = module.backups_bucket.bucket_arn
  host_alerts_topic_arn    = local.host_alerts_topic_arn
}

# Monitoring rung 2 (DE-006, BR-30a): the host alarms (StatusCheckFailed,
# CPUCreditBalance) → this project's own topic → e-mail (HUMAN confirmation).
module "host_alarms" {
  source      = "../../modules/host-alarms"
  project     = var.project
  environment = var.environment
  instance_id = module.host.instance_id
  alert_email = var.alert_email
  topic_name  = local.host_alerts_topic_name
}

# The tag-filtered budget — the only guardrail this state carries (BR-8, BR-9).
module "cost_guardrails" {
  source             = "../../modules/cost-guardrails"
  project            = var.project
  environment        = var.environment
  alert_email        = var.alert_email
  monthly_budget_usd = var.monthly_budget_usd
}

# Daily crash-consistent snapshots of the root volume, 7 kept (BR-14) — NOT the
# database backup (BR-28); an inventoried personal-data store (spec § PII Inventory).
module "backup" {
  source                   = "../../modules/backup"
  project                  = var.project
  environment              = var.environment
  permissions_boundary_arn = module.access.boundary_arn
}
