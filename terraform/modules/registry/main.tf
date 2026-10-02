# Container registry — the ECR repositories of this project (BR-23, BR-33).
#
# Derived from: ai-standards/templates/terraform/aws/modules/registry/main.tf.template
# Adaptations (spec § Registry):
#   - FIVE repositories: the three deployables (trades-backend, media-service,
#     trades-front) and the two mirrored object-store images (minio, mc) — the
#     last MinIO community images pushed ONCE from the developer's cache by
#     scripts/mirror-object-store-images.sh (ADR-126).
#   - The keep-last-10 lifecycle applies to the three deployables ONLY
#     (`lifecycle_repositories`); minio / mc have NO lifecycle — never expired,
#     because the upstream images no longer exist to be pulled again.
# Authoritative rules: ai-standards/standards/deployment.md § "Images — build
#   once, promote by digest"; infrastructure.md § Philosophy (a console-created
#   repository is the first auto-reject anti-pattern).
#
# Tag IMMUTABILITY (deliberate, AC-10): a pushed SHA tag can never be re-pointed —
# the promoted artifact is byte-for-byte what the local full gate tested, enforced
# registry-side. scripts/promote.sh pushes `{sha}` only; nothing moves a `latest`.
#
# The host pulls through its instance profile, whose inline ECR read is scoped to
# exactly these repository ARNs (modules/single-host) — never the account-wide
# managed read policy, so the host cannot pull KHA's images (TM-1).

variable "project" { type = string }
variable "environment" { type = string }
variable "repositories" {
  type        = list(string)
  description = "Repository name suffixes — repos are created as {project}/{name}"
}
variable "lifecycle_repositories" {
  type        = list(string)
  description = "The subset of `repositories` that gets the keep-last-N lifecycle (the deployables); the rest are never expired"
}
variable "keep_last_n_images" {
  type    = number
  default = 10 # deployment.md § Images: rollback depends on the last 10 SHA tags
}

locals {
  tags = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "IMMUTABLE" # a SHA tag can never be re-pointed (AC-10)

  image_scanning_configuration {
    scan_on_push = true # complements the local Trivy gate in promote.sh (AS-018), does not replace it
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "keep_last_n" {
  for_each   = toset(var.lifecycle_repositories)
  repository = aws_ecr_repository.this[each.value].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged layers/images after 7 days (failed/partial pushes)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.keep_last_n_images} tagged images — the mechanical form of deployment.md's keep-last-N rollback rule"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.keep_last_n_images
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "repository_arns" {
  description = "name → ARN; values(...) scope the host role's ECR read (modules/single-host)"
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}

output "repository_urls" {
  description = "name → URL"
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
