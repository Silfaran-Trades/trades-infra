# Backup module — EBS snapshot lifecycle for the host volume (BR-14).
#
# Derived from: ai-standards/templates/terraform/aws/modules/backup/main.tf.template
# Adaptation: the DLM service role carries the project's permissions boundary
# like every other principal this state creates (BR-5; `permissions_boundary_arn`).
# Authoritative rules: ai-standards/standards/infrastructure.md § "Graduation boundaries"
#
# SCOPE — read this before trusting it: volume snapshots are CRASH-CONSISTENT
# block copies. They restore the machine; they are NOT a database backup and
# do NOT replace the nightly database-native dumps + off-host copy + restore
# drill that deployment.md § "Backups and the restore drill" mandates
# (deploy/backup-postgres.sh, modules/backups-bucket). Both layers run.
#
# They hold whatever the disk holds — the database files, the captured mail,
# the fetched secret files — so they are an inventoried personal-data store
# with this 7-day retention (spec § PII Inventory, `channel:volume-snapshots`).

variable "project" { type = string }
variable "environment" { type = string }
variable "permissions_boundary_arn" {
  type        = string
  description = "The project boundary (modules/access) — attached to the DLM service role (BR-5)"
}
variable "retention_days" {
  type    = number
  default = 7
}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
}

resource "aws_iam_role" "dlm" {
  name                 = "${var.project}-${var.environment}-dlm"
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "daily" {
  description        = "${var.project}-${var.environment} daily host-volume snapshots (crash-consistent; not the database backup)"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"
  tags               = local.tags

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "${var.project}-${var.environment}" } # set on the root volume by modules/single-host (env-scoped)

    schedule {
      name = "daily"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:30"]
      }
      retain_rule {
        count = var.retention_days
      }
      tags_to_add = local.tags
      copy_tags   = true
    }
  }
}
