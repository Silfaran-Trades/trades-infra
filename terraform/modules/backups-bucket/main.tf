# Backups bucket — the off-host copy of the nightly dumps + the promotion records
# (BR-28, BR-24, AC-15, TM-4).
#
# NEW module (no ai-standards template; shaped after KHA's s3 module's backups
# bucket, adapted to this spec). Authoritative rules:
# ai-standards/standards/deployment.md § "Backups and the restore drill";
# gdpr-pii.md (a dump is personal data — spec § PII Inventory).
#
# `{project}-{environment}-backups-{account_id}` (S3 names are global):
#   - public access blocked (every flag), SSE-S3 at rest (the dumps are ALSO
#     age-encrypted client-side before upload — deploy/backup-postgres.sh);
#   - VERSIONING ON: a host that can write can also overwrite, so an overwritten
#     dump stays recoverable as a noncurrent version (TM-4);
#   - lifecycle on `postgres/` ONLY: current versions expire after 7 days,
#     noncurrent versions 7 days after they stop being current, expired delete
#     markers removed, incomplete multipart uploads aborted after 7 days — so no
#     dump outlives 14 days and nothing is deleted by the host (the host role
#     holds no s3:DeleteObject* at all — modules/single-host). The
#     `promotions/` prefix has NO expiration (the record must survive).
#
# Two lifecycle rules, not one: S3 refuses `Days` and `ExpiredObjectDeleteMarker`
# in the SAME Expiration element, so the delete-marker clean-up is its own rule
# on the same prefix.
#
# Who can do what (BR-28): the host lists the bucket and puts under postgres/*
# (modules/single-host); the operator reads both prefixes and writes
# promotions/* (PowerUserAccess); the agent role is DENIED s3:GetObject here
# (modules/access).

variable "project" { type = string }
variable "environment" { type = string }
variable "dump_prefix" {
  type    = string
  default = "postgres/"
}
variable "current_expiry_days" {
  type    = number
  default = 7
}
variable "noncurrent_expiry_days" {
  type    = number
  default = 7
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
  name = "${var.project}-${var.environment}-backups-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "this" {
  bucket = local.name
  tags   = merge(local.tags, { Name = "${var.project}-${var.environment}-backups" })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  # The lifecycle's versioning-dependent rules need versioning in place first.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "expire-dumps"
    status = "Enabled"
    filter {
      prefix = var.dump_prefix
    }
    expiration {
      days = var.current_expiry_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_expiry_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-dump-delete-markers"
    status = "Enabled"
    filter {
      prefix = var.dump_prefix
    }
    expiration {
      expired_object_delete_marker = true
    }
  }
}

output "bucket_name" { value = aws_s3_bucket.this.bucket }
output "bucket_arn" { value = aws_s3_bucket.this.arn }
